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

defmodule Prodigy.Core.Data.Repo.Migrations.SeedRbacDefaults do
  use Ecto.Migration

  # Four builtin roles. `viewer` is the read-only floor; the rest add
  # write capabilities on top. `platform-admin` is the meta role - its
  # scope set covers everything including roles / grants / portal_users,
  # and invariant 1 ("at least one portal user must hold the full meta
  # set") gates changes to it.
  @viewer_scopes ~w(
    objects.view
    keywords.view
    service_users.view
    portal_users.view
    roles.view
    system.view_audit_log
  )

  @content_operator_scopes @viewer_scopes ++ ~w(
    objects.upload
    objects.delete
    keywords.manage
    keywords.rebuild_index
    api_keys.self
  )

  @support_operator_scopes @viewer_scopes ++ ~w(
    service_users.disconnect
    service_users.edit_profile
  )

  @platform_admin_scopes @viewer_scopes ++ ~w(
    objects.upload
    objects.delete
    keywords.manage
    keywords.rebuild_index
    api_keys.self
    api_keys.manage_any
    service_users.disconnect
    service_users.edit_profile
    service_users.create
    service_users.delete
    portal_users.invite
    portal_users.disable
    portal_users.delete
    roles.manage
    grants.assign
    grants.revoke
    system.settings
  )

  @roles [
    {"viewer", "Viewer",
     "Read-only access to every admin surface. No destructive actions, no grants.",
     @viewer_scopes},
    {"content-operator", "Content Operator",
     "Upload and delete objects, manage the keyword table, hold an API key. Build-pipeline operator role.",
     @content_operator_scopes},
    {"support-operator", "Support Operator",
     "Help-desk operator. Can see everything and disconnect stuck service-user sessions; no object or keyword edits.",
     @support_operator_scopes},
    {"platform-admin", "Platform Admin",
     "Full access, including granting and revoking roles and scopes. Meta role - at least one portal user must hold this at all times.",
     @platform_admin_scopes}
  ]

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {name, label, description, scopes} <- @roles do
      execute(fn ->
        safe_label = escape(label)
        safe_desc = escape(description)

        repo().query!(
          """
          INSERT INTO portal_roles (name, label, description, builtin, inserted_at, updated_at)
          VALUES ($1, $2, $3, true, $4, $4)
          ON CONFLICT (name) DO NOTHING
          """,
          [name, safe_label, safe_desc, now]
        )

        %{rows: [[role_id]]} =
          repo().query!(
            "SELECT id FROM portal_roles WHERE name = $1",
            [name]
          )

        for scope <- Enum.uniq(scopes) do
          repo().query!(
            """
            INSERT INTO portal_role_scopes (role_id, scope, inserted_at)
            VALUES ($1, $2, $3)
            ON CONFLICT (role_id, scope) DO NOTHING
            """,
            [role_id, scope, now]
          )
        end
      end)
    end

    # Bootstrap: every existing portal_users row with role = 'admin'
    # gets the platform-admin role membership. Guarantees invariant 1
    # is satisfied the moment this migration lands without manual
    # intervention. Non-admin portal users get nothing - they can be
    # granted scopes via the admin UI.
    execute(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      repo().query!(
        """
        INSERT INTO portal_user_roles (user_id, role_id, granted_by_id, inserted_at)
        SELECT u.id, r.id, NULL, $1
        FROM portal_users u, portal_roles r
        WHERE u.role = 'admin' AND r.name = 'platform-admin'
        ON CONFLICT (user_id, role_id) DO NOTHING
        """,
        [now]
      )

      repo().query!(
        """
        INSERT INTO portal_audit_events (actor_id, action, target_type, target_id, details, inserted_at)
        SELECT NULL, 'grant.role', 'portal_user', u.id::text,
               jsonb_build_object('role', 'platform-admin', 'reason', 'rbac migration bootstrap'),
               $1
        FROM portal_users u
        WHERE u.role = 'admin'
        """,
        [now]
      )
    end)
  end

  def down do
    # Blow away audit rows keyed to bootstrap, memberships of builtin
    # roles, scopes of builtin roles, then the builtin role rows.
    execute(fn ->
      repo().query!(
        "DELETE FROM portal_audit_events WHERE action = 'grant.role' AND details->>'reason' = 'rbac migration bootstrap'",
        []
      )

      repo().query!(
        """
        DELETE FROM portal_user_roles
        WHERE role_id IN (SELECT id FROM portal_roles WHERE builtin = true)
        """,
        []
      )

      repo().query!("DELETE FROM portal_roles WHERE builtin = true", [])
    end)
  end

  defp escape(nil), do: nil
  defp escape(s) when is_binary(s), do: s
end
