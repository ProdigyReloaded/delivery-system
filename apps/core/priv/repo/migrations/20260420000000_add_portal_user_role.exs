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

defmodule Prodigy.Core.Data.Repo.Migrations.AddPortalUserRole do
  use Ecto.Migration

  def change do
    alter table(:portal_users) do
      # :user is the baseline; :admin has access to the /admin portal.
      # When per-era/per-environment roles land, we'll migrate rows into
      # a portal_user_roles table and drop this column.
      add :role, :string, null: false, default: "user"
    end
  end
end
