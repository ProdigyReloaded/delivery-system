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

defmodule Prodigy.Core.Data.Repo.Migrations.CreateRbacTables do
  use Ecto.Migration

  def change do
    # Named bundles of scopes. `builtin = true` marks the four seeded
    # defaults (viewer, content-operator, support-operator, platform-admin)
    # and blocks rename/delete from the Roles admin UI.
    create table(:portal_roles) do
      add :name, :string, null: false
      add :label, :string, null: false
      add :description, :string
      add :builtin, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:portal_roles, [:name])

    # Scopes attached to a role. `(role_id, scope)` is the composite
    # primary key - a scope is either in the role or it isn't.
    create table(:portal_role_scopes, primary_key: false) do
      add :role_id, references(:portal_roles, on_delete: :delete_all),
          null: false,
          primary_key: true

      add :scope, :string, null: false, primary_key: true

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:portal_role_scopes, [:role_id])
    create index(:portal_role_scopes, [:scope])

    # Role memberships for portal users. granted_by_id preserves who
    # handed out the role for audit purposes, but survives deletion of
    # the granter (SET NULL) - the audit log is the authoritative record.
    create table(:portal_user_roles, primary_key: false) do
      add :user_id, references(:portal_users, on_delete: :delete_all),
          null: false,
          primary_key: true

      add :role_id, references(:portal_roles, on_delete: :delete_all),
          null: false,
          primary_key: true

      add :granted_by_id, references(:portal_users, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:portal_user_roles, [:user_id])
    create index(:portal_user_roles, [:role_id])

    # Direct scope grants that don't fit a role. Effective scopes for a
    # user = union of (user's role memberships expanded via role_scopes)
    # and these direct rows.
    create table(:portal_user_scopes, primary_key: false) do
      add :user_id, references(:portal_users, on_delete: :delete_all),
          null: false,
          primary_key: true

      add :scope, :string, null: false, primary_key: true
      add :granted_by_id, references(:portal_users, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:portal_user_scopes, [:user_id])
    create index(:portal_user_scopes, [:scope])

    # Append-only audit trail. Every grant/revoke and every destructive
    # admin action writes here inside the same transaction as the
    # operation. actor_id nullable because system-initiated events
    # (bootstrap seeds, background jobs) have no portal-user actor.
    create table(:portal_audit_events) do
      add :actor_id, references(:portal_users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :details, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:portal_audit_events, [:actor_id])
    create index(:portal_audit_events, [:action])
    create index(:portal_audit_events, [:target_type, :target_id])
    create index(:portal_audit_events, [:inserted_at])
  end
end
