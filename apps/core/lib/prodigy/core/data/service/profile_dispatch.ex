# Copyright 2026, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Core.Data.Service.ProfileDispatch do
  @moduledoc """
  Profile TAC routing. One place that encodes every decision about
  which record + JSONB key backs a given TAC.

  * `resolve_target/3` - given a TAC + the current User + Household,
    returns `{record, jsonb_key}` for read/write. Household user-slot
    TACs (0x011A..0x014D) target `household.profile` under the raw slot
    keys; that data is a denormalized mirror. The corresponding per-slot
    `User` rows (`household.id <> slot`, e.g. AAAA11B) are materialized
    separately - `Prodigy.Server.Service.Profile.persist_members/3` does
    that at the enrollment / profile-update call sites, where a Repo is
    available - mapping the slot-relative name/title TACs onto each
    member's own TACs (0x015E/0x015F/0x0160/0x0161).
  * `get_value/3` - reads JSONB, decodes per `ProfileSchema` type.
    Password (`0x014F`) is served straight from `User.password`;
    missing keys return `" "`.
  * `apply_entries/3` - given a list of `{tac, value}` updates plus
    the user + household structs, returns `%{user: u, household: h}`
    records with the JSONB map updated. JSONB is the sole store for
    profile data. Caller is responsible for `Repo.update` in a
    transaction.

  Consumers: `Prodigy.Server.Service.Profile` and `.Enrollment` route
  TAC reads/writes through this module instead of hand-rolled case
  blocks.
  """

  alias Prodigy.Core.Data.Service.{Household, ProfileBackfill, ProfileSchema, User}

  # -- resolve_target ---------------------------------------------

  @doc """
  Resolve a TAC to the record that stores its value and the JSONB key
  used for it. Returns `{record, key_string}` or `{:error, reason}`.

  Record is either the passed `user` or `household` struct. Household
  user-slot TACs target the household's JSONB (the denormalized mirror);
  the per-slot User rows are materialized by `Profile.persist_members/3`
  - see the module doc.
  """
  @spec resolve_target(non_neg_integer(), User.t(), Household.t() | nil) ::
          {struct(), String.t()} | {:error, atom()}
  def resolve_target(tac, %User{} = user, household) when is_integer(tac) do
    case ProfileSchema.get(tac) do
      nil ->
        {:error, :unknown_tac}

      %{entity: :household} ->
        {household, ProfileBackfill.tac_key(tac)}

      %{entity: :user, slot: nil} ->
        {user, ProfileBackfill.tac_key(tac)}

      %{entity: :user, slot: slot} when is_binary(slot) ->
        # Household user-slot TACs land on household.profile (a
        # denormalized mirror). The per-slot User rows are created by
        # Profile.persist_members/3 at the call sites - see the module
        # doc.
        {household, ProfileBackfill.tac_key(tac)}
    end
  end

  # -- get_value --------------------------------------------------

  @doc """
  Fetch the current value for `tac` from the appropriate record.

  Reads:
  1. Password TAC (`0x014F`) -> `User.password` (always a dedicated
     column, never in JSONB).
  2. Primary-key TACs (`0x014E` user id, `0x0111` household id) -> the
     entity's id column.
  3. Everything else -> JSONB.
  4. Unknown TACs / missing keys -> `" "` (preserves the legacy
     Profile.ex behavior for unmatched TACs while we log a warning at
     the TCS layer).
  """
  @spec get_value(non_neg_integer(), User.t(), Household.t() | nil) :: any()
  def get_value(0x014F, %User{password: pw}, _household), do: pw
  def get_value(0x014E, %User{id: id}, _household), do: id
  def get_value(0x0111, _user, %Household{id: id}), do: id

  def get_value(tac, user, household) when is_integer(tac) do
    case resolve_target(tac, user, household) do
      {:error, _} ->
        " "

      {record, key} ->
        profile = Map.get(record, :profile) || %{}

        case Map.get(profile, key) do
          nil -> " "
          stored -> decode(stored, ProfileSchema.get(tac))
        end
    end
  end

  # -- apply_entries ----------------------------------------------

  @doc """
  Apply a list of TAC updates to the user + household records.

  Returns `%{user: user_or_nil, household: household_or_nil}` with each
  struct carrying the updated `:profile` map. JSONB is the sole
  store for wire-driven writes - there are no other columns to
  keep in sync. The caller wraps the pair in a Repo.transaction
  and runs `Repo.update` on each non-nil record.

  Entries with unknown TACs are silently skipped here; the warning
  for them is logged at the TCS layer where the protocol context is
  available.
  """
  @spec apply_entries([{non_neg_integer(), any()}], User.t(), Household.t() | nil) :: %{
          user: User.t(),
          household: Household.t() | nil
        }
  def apply_entries(entries, %User{} = user, household) when is_list(entries) do
    Enum.reduce(entries, %{user: user, household: household}, fn {tac, value}, acc ->
      apply_entry(tac, value, acc)
    end)
  end

  defp apply_entry(0x014F, value, %{user: user} = acc) do
    # Password: go through the existing hash-on-write path by running
    # it through User.changeset via the caller's changeset pipeline.
    # Here we just stage it on the user struct; caller builds the
    # changeset.
    %{acc | user: %{user | password: value}}
  end

  defp apply_entry(0x014E, _value, acc), do: acc
  defp apply_entry(0x0111, _value, acc), do: acc

  defp apply_entry(tac, value, acc) when is_integer(tac) do
    case ProfileSchema.slot_member_tac(tac) do
      {slot, _user_tac} when slot in ~w(B C D E F) ->
        # Household member slots B..F live on the per-slot User row, not
        # household.profile - the caller materializes them via
        # Profile.persist_members/3 from the member_patches it derives.
        # Nothing to write here.
        acc

      _ ->
        apply_entry_to_record(tac, value, acc)
    end
  end

  defp apply_entry_to_record(tac, value, acc) do
    case ProfileSchema.get(tac) do
      nil ->
        acc

      meta ->
        case resolve_target(tac, acc.user, acc.household) do
          {:error, _} ->
            acc

          # Target record isn't in scope for this dispatch call
          # (e.g., the Profile.get_user_changeset/1 compat facade
          # passes nil for household when slot TACs in the entry list
          # would otherwise land there). Silently skip.
          {nil, _key} ->
            acc

          {record, key} ->
            encoded = ProfileBackfill.encode(value, meta.type)
            record = update_profile(record, key, encoded)
            assign_record(acc, record)
        end
    end
  end

  # -- helpers ----------------------------------------------------

  defp update_profile(record, key, nil) do
    profile = Map.get(record, :profile) || %{}
    %{record | profile: Map.delete(profile, key)}
  end

  defp update_profile(record, key, value) do
    profile = Map.get(record, :profile) || %{}
    %{record | profile: Map.put(profile, key, value)}
  end

  defp assign_record(acc, %User{} = record), do: %{acc | user: record}
  defp assign_record(acc, %Household{} = record), do: %{acc | household: record}

  # Decode a JSONB value back to the on-the-wire representation per
  # schema type. ASCII passes through; base64 is decoded; dates stay
  # as MMDDYY strings (already in that shape post-backfill).
  defp decode(stored, %{type: :ascii}) when is_binary(stored), do: stored

  defp decode(stored, %{type: :binary}) when is_binary(stored) do
    case Base.decode64(stored) do
      {:ok, bytes} -> bytes
      :error -> stored
    end
  end

  defp decode(stored, %{type: :date_mmddyy}) when is_binary(stored), do: stored
  defp decode(stored, _), do: stored
end
