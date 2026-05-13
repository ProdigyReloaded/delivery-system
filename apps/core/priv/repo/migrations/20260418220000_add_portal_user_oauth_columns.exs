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

defmodule Prodigy.Core.Data.Repo.Migrations.AddPortalUserOauthColumns do
  use Ecto.Migration

  def change do
    alter table(:portal_users) do
      add :provider, :string, null: false, default: "identity"
      add :provider_uid, :string
    end

    # A provider+uid pair uniquely identifies a user on that provider.
    # Allow NULL for :identity users (no external uid).
    create unique_index(:portal_users, [:provider, :provider_uid],
             where: "provider_uid IS NOT NULL"
           )
  end
end
