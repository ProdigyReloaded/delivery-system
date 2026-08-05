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

defmodule Prodigy.Core.Data.Repo.Migrations.BackfillMemberStatus do
  use Ecto.Migration
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, MemberStatus, User}

  @moduledoc """
  Backfill the household member account-status bytes the TOOLS
  Add/Suspend screen and the logon active check read.

  For every household, from its existing member `User` rows
  (`household.id <> suffix`, A..F):

    * set PRF_SUFFIX_IN_USE_INDICATORS (#277 / 0x0115) bit for each
      allocated suffix, and
    * set PRF_INDICATORS_<suffix> ACTIVE = (date_deleted is nil) and
      ENROLLED = (date_enrolled is not nil).

  Pre-existing accounts predate the suspend feature, so nobody is
  suspended - ACTIVE follows the delete flag, ENROLLED follows the
  enrollment date.  Idempotent: recomputes from the same source rows.
  Fresh installs get these bits at creation (Enroller), so this is a
  no-op there.
  """

  def up do
    flush()

    Repo.transaction(fn ->
      Enum.each(Repo.all(Household), &backfill_household/1)
    end)
  end

  def down do
    # Additive status keys; leaving them in place is harmless and the
    # app tolerates their absence anyway. No reversal.
    :ok
  end

  defp backfill_household(%Household{} = household) do
    profile = household.profile || %{}

    # LIKE "<id>_" matches exactly the 7-char member ids for this household.
    members = Repo.all(from(u in User, where: like(u.id, ^(household.id <> "_"))))

    new_profile =
      Enum.reduce(members, profile, fn %User{} = u, acc ->
        suffix = MemberStatus.suffix_of(u.id)

        if suffix in ~w(A B C D E F) do
          acc
          |> MemberStatus.put_suffix_in_use(suffix)
          |> MemberStatus.put_indicators(suffix, is_nil(u.date_deleted), not is_nil(u.date_enrolled))
        else
          acc
        end
      end)

    if new_profile != profile do
      household
      |> Ecto.Changeset.change(profile: new_profile)
      |> Repo.update!()
    end
  end
end
