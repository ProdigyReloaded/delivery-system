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

defmodule Prodigy.Core.Data.Repo.Migrations.AddInvitations do
  use Ecto.Migration

  def change do
    # Generic system-level key/value store. First user is "invitation_only"
    # but the table is shaped so future settings (mail backend toggle,
    # rate caps, etc.) can append rows without a schema change.
    create table(:portal_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false
      add :updated_by_id, references(:portal_users, on_delete: :nilify_all)
      timestamps()
    end

    create table(:portal_invites) do
      add :code, :string, null: false
      add :inviter_id, references(:portal_users, on_delete: :restrict), null: false
      add :redeemer_id, references(:portal_users, on_delete: :nilify_all)
      add :redeemed_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :revoked_by_id, references(:portal_users, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:portal_invites, [:code])
    create index(:portal_invites, [:inviter_id])
    create index(:portal_invites, [:redeemer_id])

    alter table(:portal_users) do
      add :invite_quota, :integer, null: false, default: 0
    end
  end
end
