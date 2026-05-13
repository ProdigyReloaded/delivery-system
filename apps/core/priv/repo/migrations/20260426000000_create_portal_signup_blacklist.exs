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

defmodule Prodigy.Core.Data.Repo.Migrations.CreatePortalSignupBlacklist do
  use Ecto.Migration

  # Email-level cooldown list consulted before minting a signup or
  # provider-link invitation. Populated when the recipient clicks
  # "wasn't me" on a confirmation email (30-day cooldown) or when
  # rate limits trip (1-hour cooldown). Row is keyed by email so
  # the check is a single PK lookup.
  def change do
    create table(:portal_signup_blacklist, primary_key: false) do
      add :email, :string, primary_key: true
      add :reason, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:portal_signup_blacklist, [:expires_at])
  end
end
