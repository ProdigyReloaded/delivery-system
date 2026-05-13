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

defmodule Prodigy.Core.Data.Repo.Migrations.CreateMemberUserRows do
  use Ecto.Migration
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, ProfileBackfill, ProfileSchema, User}

  @moduledoc """
  Backfill: materialize the household user-slot B..F name/title data
  (which lives in `household.profile` under keys 0x0123..0x014D) into
  per-slot `User` rows keyed off `household.id <> slot` (AAAA11B..F).

  New member rows are created un-enrolled - so the member's first logon
  routes to the user enrollment flow - with `password` copied from the
  household's slot-A user (the welcome-kit convention) when one exists.
  An existing member row gets the slot data merged into its `profile`.
  The household slot keys are left in place as a denormalized mirror.

  Idempotent: re-running merges the same data into the same rows.
  """

  def up do
    flush()

    Repo.transaction(fn ->
      Enum.each(Repo.all(Household), &backfill_household/1)
    end)
  end

  def down do
    # Member rows created here are not removed: they may have been
    # enrolled or edited since. Manual cleanup if ever needed.
    :ok
  end

  defp backfill_household(%Household{} = household) do
    profile = household.profile || %{}
    patches = slot_patches(profile)

    if map_size(patches) > 0 do
      subscriber = Repo.get(User, household.id <> "A")
      password = subscriber && subscriber.password

      for {slot, patch} <- patches, map_size(patch) > 0 do
        member_id = household.id <> slot
        upsert_member(member_id, household.id, patch, password)
      end
    end
  end

  # Group the household profile's slot B..F name/title keys by slot,
  # mapped to each member's own TAC keys.
  defp slot_patches(profile) do
    Enum.reduce(profile, %{}, fn {key, value}, acc ->
      with {tac, ""} <- Integer.parse(key, 16),
           {slot, user_tac} when slot in ~w(B C D E F) <- ProfileSchema.slot_member_tac(tac) do
        user_key = ProfileBackfill.tac_key(user_tac)
        Map.update(acc, slot, %{user_key => value}, &Map.put(&1, user_key, value))
      else
        _ -> acc
      end
    end)
  end

  defp upsert_member(member_id, household_id, patch, password) do
    case Repo.get(User, member_id) do
      nil ->
        attrs = %{profile: patch}
        attrs = if password, do: Map.put(attrs, :password, password), else: attrs

        %User{id: member_id, household_id: household_id}
        |> User.changeset(attrs)
        |> Repo.insert!()

      %User{} = member ->
        member
        |> User.changeset(%{profile: Map.merge(member.profile || %{}, patch)})
        |> Repo.update!()
    end
  end
end
