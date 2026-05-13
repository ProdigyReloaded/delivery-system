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

defmodule Prodigy.Core.Data.Repo.Migrations.AddScopesToApiKeys do
  use Ecto.Migration

  # Adds a scopes[] column to portal_api_keys so each key can carry a
  # subset of its owner's scopes. Existing rows get a backfill: every
  # non-revoked key's scopes = owner's current effective scopes minus
  # the forbidden-for-keys subset. That keeps existing keys working as
  # they did before this change without requiring the operator to
  # re-mint them.

  @forbidden ~w(
    api_keys.self
    api_keys.manage_any
    grants.assign
    grants.revoke
    roles.manage
    portal_users.invite
    portal_users.disable
    portal_users.delete
  )

  def up do
    alter table(:portal_api_keys) do
      add :scopes, {:array, :string}, null: false, default: []
    end

    flush()

    execute(fn ->
      repo().query!(
        """
        WITH effective AS (
          SELECT u.id AS user_id,
                 COALESCE(
                   ARRAY_AGG(DISTINCT s.scope) FILTER (WHERE s.scope IS NOT NULL AND NOT (s.scope = ANY($1::text[]))),
                   '{}'::text[]
                 ) AS scopes
          FROM portal_users u
          LEFT JOIN (
            SELECT ur.user_id, rs.scope
            FROM portal_user_roles ur
            JOIN portal_role_scopes rs ON rs.role_id = ur.role_id
            UNION
            SELECT user_id, scope FROM portal_user_scopes
          ) s ON s.user_id = u.id
          GROUP BY u.id
        )
        UPDATE portal_api_keys k
        SET scopes = e.scopes
        FROM effective e
        WHERE k.user_id = e.user_id
          AND k.revoked_at IS NULL
        """,
        [@forbidden]
      )
    end)
  end

  def down do
    alter table(:portal_api_keys) do
      remove :scopes
    end
  end
end
