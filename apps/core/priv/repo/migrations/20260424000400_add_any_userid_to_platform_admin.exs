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

defmodule Prodigy.Core.Data.Repo.Migrations.AddAnyUseridToPlatformAdmin do
  use Ecto.Migration

  # Grants `service_users.any_userid` to the platform-admin role for
  # deployments that were seeded before the scope existed. The seed
  # migration (20260424000100) is a snapshot of the scope set at that
  # point in time and is deliberately not edited after landing; this
  # migration is the forward-compat companion.

  def up do
    execute(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{rows: [[role_id]]} =
        repo().query!(
          "SELECT id FROM portal_roles WHERE name = 'platform-admin' LIMIT 1",
          []
        )

      repo().query!(
        """
        INSERT INTO portal_role_scopes (role_id, scope, inserted_at)
        VALUES ($1, 'service_users.any_userid', $2)
        ON CONFLICT (role_id, scope) DO NOTHING
        """,
        [role_id, now]
      )
    end)
  end

  def down do
    execute(fn ->
      repo().query!(
        """
        DELETE FROM portal_role_scopes rs
        USING portal_roles r
        WHERE rs.role_id = r.id
          AND r.name = 'platform-admin'
          AND rs.scope = 'service_users.any_userid'
        """,
        []
      )
    end)
  end
end
