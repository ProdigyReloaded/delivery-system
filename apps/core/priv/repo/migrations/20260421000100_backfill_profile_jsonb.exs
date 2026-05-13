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

defmodule Prodigy.Core.Data.Repo.Migrations.BackfillProfileJsonb do
  use Ecto.Migration
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, ProfileBackfill, User}

  @moduledoc """
  Backfill the JSONB `profile` column on every existing `user` and
  `household` row from the named columns, via
  `Prodigy.Core.Data.Service.ProfileBackfill`.

  Idempotent: re-running regenerates the same map from the same source
  columns. Tests exercise that property in
  `apps/core/test/prodigy/core/data/service/profile_backfill_test.exs`.
  """

  def up do
    flush()

    Repo.transaction(fn ->
      Enum.each(Repo.all(User), fn user ->
        profile = ProfileBackfill.user(user)
        Repo.update_all(from(u in User, where: u.id == ^user.id), set: [profile: profile])
      end)

      Enum.each(Repo.all(Household), fn household ->
        profile = ProfileBackfill.household(household)

        Repo.update_all(
          from(h in Household, where: h.id == ^household.id),
          set: [profile: profile]
        )
      end)
    end)
  end

  def down do
    # Data-only migration; reverting clears the JSONB content but
    # leaves the column (it belongs to the schema migration). Safe
    # to re-run forward.
    Repo.update_all(User, set: [profile: %{}])
    Repo.update_all(Household, set: [profile: %{}])
  end
end
