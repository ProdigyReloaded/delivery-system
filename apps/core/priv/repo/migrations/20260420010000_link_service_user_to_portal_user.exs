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

defmodule Prodigy.Core.Data.Repo.Migrations.LinkServiceUserToPortalUser do
  use Ecto.Migration

  def change do
    alter table(:user) do
      # Nullable: legacy service users provisioned by pomsutil before the
      # portal existed may have no portal account, and some service users
      # may never have one (head-of-household exists only on the service side).
      # set null on delete so dropping a portal user unlinks their service
      # users without cascading.
      add :portal_user_id,
          references(:portal_users, on_delete: :nilify_all),
          null: true
    end

    create index(:user, [:portal_user_id])
  end
end
