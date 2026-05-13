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

defmodule Prodigy.Core.Data.Repo.Migrations.StripHouseholdSlotMemberKeys do
  use Ecto.Migration
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, ProfileSchema, User}

  @moduledoc """
  De-denormalization follow-up to 20260512000000: the household
  user-slot B..F name/title data is now authoritative on the per-slot
  member `User` rows (`household.id <> slot`). Drop the redundant copies
  from `household.profile` - the "0123"/"0124"/... keys for slots B..F,
  name/title fields only.

  A slot's keys are removed only if the member row for that slot exists
  (so a member row deleted between the 20260512000000 backfill and this
  migration can't cause data loss - the household copy is the last
  resort then). Where the member row exists it's authoritative, even if
  it has since diverged from the old household copy. Slot A, the
  access_level / indicators slot keys, and everything else are left in
  place. `down/0` is a no-op (the data lives on the member rows).
  """

  def up do
    flush()

    Repo.transaction(fn ->
      Enum.each(Repo.all(Household), &strip_household/1)
    end)
  end

  def down, do: :ok

  defp strip_household(%Household{} = household) do
    profile = household.profile || %{}
    strippable = strippable_keys(household.id, profile)

    if strippable != [] do
      household
      |> Ecto.Changeset.change(%{profile: Map.drop(profile, strippable)})
      |> Repo.update!()
    end
  end

  # Keys in `profile` that map to a slot-B..F name/title member TAC for
  # a slot whose member row exists (that row is now authoritative).
  defp strippable_keys(household_id, profile) do
    Enum.reduce(profile, [], fn {key, _value}, acc ->
      with {tac, ""} <- Integer.parse(key, 16),
           {slot, _user_tac} when slot in ~w(B C D E F) <- ProfileSchema.slot_member_tac(tac),
           %User{} <- Repo.get(User, household_id <> slot) do
        [key | acc]
      else
        _ -> acc
      end
    end)
  end
end
