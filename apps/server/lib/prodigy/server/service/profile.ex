# Copyright 2022-2026, Phillip Heller and Ralph Richard Cook
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

defmodule Prodigy.Server.Service.Profile do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Profile Requests. Routes TAC reads/writes through
  `Prodigy.Core.Data.Service.ProfileDispatch`, which resolves each
  TAC to the right record + JSONB key per `ProfileSchema`.
  """

  require Logger
  require Ecto.Query
  use EnumType

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, ProfileBackfill, ProfileDispatch, ProfileSchema, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  @doc """
  Decode wire bytes back into the list of `{tac, value}` tuples the
  client sent.
  """
  def parse_request_values(payload, entries \\ [])
  def parse_request_values(<<>>, entries), do: entries

  def parse_request_values(payload, entries) do
    <<tac::16-big, length, value::binary-size(length), rest::binary>> = payload
    parse_request_values(rest, entries ++ [{tac, value}])
  end

  @doc """
  Serialize one TAC's value for a retrieve response. Returns the
  tag-length-value on-wire encoding.
  """
  def get_tac(tac, user, household) do
    res = get_value(tac, user, household)

    <<tac::16-big>> <>
      case res do
        nil ->
          <<0x0>>

        "" ->
          <<0x0>>

        " " ->
          <<0x0>>

        binary when is_binary(binary) ->
          <<byte_size(binary), binary::binary>>

        other ->
          s = to_string(other)
          <<byte_size(s), s::binary>>
      end
  end

  # "hardcoded" TACs for Eaasy Sabre - these are not in the registry
  def get_value(0x183, _user, _household), do: "0ABC123" # this is the AA freq flier number

  def get_value(0x18A, _user, _household), do: "     " # this, I think, is the travel agent id; blank for none

  @doc """
  Read the current value for a TAC. Household member slots B..F are
  read through to the per-slot User row (`household.id <> slot`); the
  rest go through `ProfileDispatch.get_value/3`. Logs a warning for
  unknown TACs so gap-hunting against the registry doesn't crash the
  client.
  """
  def get_value(tac, user, household) do
    if not ProfileSchema.known?(tac) do
      Logger.warning(
        "[profile] unknown TAC #{inspect(tac, base: :hex)} requested; returning empty"
      )
    end

    case ProfileSchema.slot_member_tac(tac) do
      {slot, user_tac} when slot in ~w(B C D E F) ->
        member_value(household, slot, user_tac)

      _ ->
        ProfileDispatch.get_value(tac, user, household)
    end
  end

  # Read a slot-B..F member's name/title TAC from its own User row.
  # These TACs are all :ascii so no decode is needed. Missing member
  # row or empty value -> " " (the same sentinel ProfileDispatch uses).
  defp member_value(nil, _slot, _user_tac), do: " "

  defp member_value(%Household{} = household, slot, user_tac) do
    case Repo.get(User, household.id <> slot) do
      nil ->
        " "

      %User{} = member ->
        case Map.get(member.profile || %{}, ProfileBackfill.tac_key(user_tac)) do
          v when is_binary(v) and v != "" -> v
          _ -> " "
        end
    end
  end

  @doc """
  Build the user/household changesets plus the per-slot member patches
  for the incoming wire entries. Returns
  `{user_changeset_or_nil, household_changeset_or_nil, member_patches}`
  where `member_patches` is `%{slot_letter => %{user_own_tac_key => value}}`
  for slots B..F (slot A is the subscriber, handled by the caller).
  Callers run the changesets in a transaction and pass `member_patches`
  to `persist_members/3`.

  Writes target the JSONB `profile` map. The household user-slot fields
  (0x011A..0x014D) still land on `household.profile` as a denormalized
  mirror; the same name/title data is also accumulated into
  `member_patches` so the caller can materialize the per-slot User rows
  (AAAA11B..F) keyed off `household.id <> slot`.
  """
  def build_changesets(entries, %User{} = user, household) do
    %{user: updated_user, household: updated_hh} =
      ProfileDispatch.apply_entries(entries, user, household)

    user_changeset = User.changeset(user, changes_map(user, updated_user))

    household_changeset =
      if is_nil(household) do
        nil
      else
        Household.changeset(household, changes_map(household, updated_hh))
      end

    {user_changeset, household_changeset, member_patches(entries)}
  end

  # Scan the wire entries for household user-slot name/title TACs whose
  # slot is B..F (slot A == the subscriber, handled separately), and
  # group them by slot into `%{slot => %{user_own_tac_key => value}}`.
  defp member_patches(entries) do
    Enum.reduce(entries, %{}, fn {tac, value}, acc ->
      case ProfileSchema.slot_member_tac(tac) do
        {slot, user_tac} when slot in ~w(B C D E F) ->
          key = ProfileBackfill.tac_key(user_tac)
          Map.update(acc, slot, %{key => value}, &Map.put(&1, key, value))

        _ ->
          acc
      end
    end)
  end

  @doc """
  Materialize the per-slot member User rows from `member_patches`
  (output of `build_changesets/3`). For each populated slot it
  find-or-creates `User{id: household.id <> slot}`: a new row is created
  un-enrolled (so the member's first logon routes to
  `Logon.Status.ENROLL_OTHER`) with `password` copied from the
  subscriber; an existing row gets the patch merged into its `profile`.
  Must run inside the caller's `Repo.transaction`. Returns the list of
  created/updated member ids.
  """
  def persist_members(member_patches, %Household{} = household, subscriber_password) do
    for {slot, patch} <- member_patches, map_size(patch) > 0 do
      member_id = household.id <> slot

      case Repo.get(User, member_id) do
        nil ->
          %User{id: member_id, household_id: household.id}
          |> User.changeset(%{profile: patch, password: subscriber_password})
          |> Repo.insert!()

          Logger.info("Created household member #{member_id}")
          member_id

        %User{} = member ->
          member
          |> User.changeset(%{profile: Map.merge(member.profile || %{}, patch)})
          |> Repo.update!()

          member_id
      end
    end
  end

  # Diff two %User{} / %Household{} structs into the params map the
  # respective changeset expects. We only include fields that the
  # changeset allows; the :profile field is always included when it
  # differs - both User and Household changesets cast :profile.
  defp changes_map(original, updated) do
    fields = cast_fields(original.__struct__)

    fields
    |> Enum.reduce(%{}, fn field, acc ->
      orig_val = Map.get(original, field)
      new_val = Map.get(updated, field)

      if orig_val == new_val do
        acc
      else
        Map.put(acc, field, new_val)
      end
    end)
  end

  # Fields each schema's changeset allows via cast/3 - kept in sync
  # with User.changeset / Household.changeset.
  defp cast_fields(User), do: ~w(password date_enrolled concurrency_limit profile)a
  defp cast_fields(Household), do: ~w(enabled_date disabled_date disabled_reason profile)a

  def handle(%Fm0{payload: payload} = request, %Context{user: user} = context) do
    Logger.debug("[profile] request packet: #{inspect(request, base: :hex, limit: :infinity)}")

    <<
      0x13,
      action,
      which_user,
      other_user_id::binary-size(7),
      filler::binary-size(5),
      _count::16-big,
      rest::binary
    >> = payload

    entries = parse_request_values(rest)
    Logger.debug("#{inspect(entries, base: :hex, limit: :infinity)}")

    values =
      case action do
        0x03 ->
          # Retrieve: encode each requested TAC.
          Enum.reduce(entries, <<>>, fn {tac, _val}, buf ->
            buf <> get_tac(tac, user, user.household)
          end)

        0x04 ->
          Logger.info("Profile update received for user #{user.id}")

          {user_changeset, household_changeset, member_patches} =
            build_changesets(entries, user, user.household)

          # New member rows get this user's password as loaded - before
          # any password change in this update is applied - mirroring the
          # enrollment "members share the subscriber's initial password"
          # rule.
          member_initial_password = user.password

          Repo.transaction(fn ->
            if household_changeset, do: Repo.update!(household_changeset)

            if user.household && map_size(member_patches) > 0 do
              persist_members(member_patches, user.household, member_initial_password)
            end

            Repo.update!(user_changeset |> Ecto.Changeset.change(date_enrolled: Timex.today()))
          end)

          Prodigy.Server.SessionManager.broadcast_profile_updated(user.id)

          payload
      end

    response_payload = <<
      0x13,
      action,
      which_user,
      other_user_id::binary-size(7),
      filler::binary-size(5),
      0x0::16-big,
      values::binary
    >>

    {:ok, context, DiaPacket.encode(Fm0.make_response(response_payload, request))}
  end

  # -- compat shims --------------------------------------------------

  @doc """
  Backwards-compatible facade kept so `Prodigy.Server.Service.Enrollment`
  can reuse the same parser while we migrate it onto ProfileDispatch too.
  Builds the User change-params map expected by User.changeset.
  """
  def get_user_changeset(entries) do
    # Apply via ProfileDispatch against a blank user then extract the
    # diff in the params-map form User.changeset wants.
    empty_user = %User{}
    %{user: staged} = ProfileDispatch.apply_entries(entries, empty_user, nil)
    changes_map(empty_user, staged)
  end

  @doc """
  Backwards-compatible facade - same idea as `get_user_changeset/1` but
  for households. Used by `Enrollment.ex`.
  """
  def get_household_changeset(entries) do
    empty_hh = %Household{}
    empty_user = %User{}
    %{household: staged} = ProfileDispatch.apply_entries(entries, empty_user, empty_hh)
    if is_nil(staged), do: %{}, else: changes_map(empty_hh, staged)
  end
end
