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

defmodule Prodigy.Core.Data.Repo.Migrations.DropPortalUserRole do
  use Ecto.Migration

  # The :role column on portal_users is replaced by the RBAC scope
  # model landed in 20260424000000 / 20260424000100. Bootstrap seed
  # already translated every `role = 'admin'` row into a platform-admin
  # role membership, so dropping the column loses no capability.

  def up do
    alter table(:portal_users) do
      remove :role
    end
  end

  def down do
    alter table(:portal_users) do
      add :role, :string, null: false, default: "user"
    end
  end
end
