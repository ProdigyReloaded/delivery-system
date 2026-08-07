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

defmodule Prodigy.Core.Data.Repo.Migrations.BackfillHouseholdPassword do
  use Ecto.Migration

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Household

  @moduledoc """
  Seed the household temporary password (PRF_HOUSEHOLD_PASSWORD, #275 / 0x0113)
  for households created before it was stored.

  The TOOLS Member Information screen shows this plaintext password, and the
  Add/Suspend flow uses it as every newly-added member's initial (enrollment)
  password. Fresh accounts get it at creation (Enroller). Households created
  earlier only ever had the "A" user's own password hashed onto the User row -
  the plaintext was discarded and cannot be recovered - so this mints a FRESH
  password and stores it in `profile["0113"]`.

  Scope, deliberately minimal:

    * Only households MISSING `"0113"` are touched (idempotent - re-running
      skips any that already have it).
    * The "A" user's login password (0x014F on the User row) is left UNTOUCHED.
      `"0113"` is the forward-looking shared enrollment password for
      newly-added members, independent of the A user's own credential.

  The password matches what new-account creation generates - a random 6-char
  string over the A-Z / 2-9 alphabet with the visually-ambiguous I, O, 0, 1
  removed (see `Prodigy.Portal.SignupIds.generate_password/0`; the alphabet is
  replicated here to keep this core migration free of a portal dependency).
  """

  # A-Z and 2-9 minus I, O, 0, 1.
  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @length 6
  @key "0113"

  def up do
    flush()

    Repo.transaction(fn ->
      Enum.each(Repo.all(Household), &backfill_household/1)
    end)
  end

  def down do
    # The seeded values are live credentials shown to subscribers and accepted
    # at enrollment; removing them would break the TOOLS flow. No reversal.
    :ok
  end

  defp backfill_household(%Household{} = household) do
    profile = household.profile || %{}

    if blank?(Map.get(profile, @key)) do
      new_profile = Map.put(profile, @key, generate_password())

      household
      |> Ecto.Changeset.change(profile: new_profile)
      |> Repo.update!()
    end
  end

  # Only a genuinely absent/empty value is seeded; any existing password stands.
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp generate_password do
    len = length(@alphabet)
    for _ <- 1..@length, into: "", do: <<Enum.at(@alphabet, :rand.uniform(len) - 1)>>
  end
end
