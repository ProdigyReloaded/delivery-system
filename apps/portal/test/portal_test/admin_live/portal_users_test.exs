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

defmodule Prodigy.Portal.AdminLive.Portal.UsersTest do
  use Prodigy.Portal.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Core.Data.Portal.AuditEvent
  alias Prodigy.Core.Data.Portal.UserRole
  alias Prodigy.Core.Data.Portal.UserScope
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Authz

  setup %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "route gate" do
    test "rejects a user without portal_users.view", %{conn: conn} do
      conn = Phoenix.ConnTest.recycle(conn)
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/portal/users")
    end
  end

  describe "list view" do
    test "renders rows for every portal user with role + identity badges", %{
      conn: conn,
      admin: admin
    } do
      other = user_fixture()
      {:ok, _} = Authz.grant_scope(nil, other.id, "objects.upload")

      {:ok, _view, html} = live(conn, ~p"/admin/portal/users")

      assert html =~ admin.email
      assert html =~ other.email
      # Admin holds platform-admin -> its badge label shows.
      assert html =~ "Platform Admin"
      # Direct scope badge on the other user.
      assert html =~ "objects.upload"
    end
  end

  describe "edit modal - roles" do
    test "grants a role via the checkbox", %{conn: conn} do
      target = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/portal/users")

      # Open the edit modal for the target.
      render_click(view, "open_edit", %{"id" => Integer.to_string(target.id)})

      # Toggle content-operator on.
      render_click(view, "toggle_role", %{
        "user_id" => Integer.to_string(target.id),
        "role" => "content-operator"
      })

      assert Repo.exists?(
               from ur in UserRole,
                 join: r in Prodigy.Core.Data.Portal.Role,
                 on: r.id == ur.role_id,
                 where: ur.user_id == ^target.id and r.name == "content-operator"
             )

      # Audit row got written.
      assert Repo.exists?(
               from e in AuditEvent,
                 where: e.action == "grant.role" and e.target_id == ^Integer.to_string(target.id)
             )
    end

    test "toggling an already-granted role revokes it", %{conn: conn} do
      target = user_fixture()
      {:ok, _} = Authz.grant_role(nil, target.id, "viewer")

      {:ok, view, _html} = live(conn, ~p"/admin/portal/users")
      render_click(view, "open_edit", %{"id" => Integer.to_string(target.id)})

      render_click(view, "toggle_role", %{
        "user_id" => Integer.to_string(target.id),
        "role" => "viewer"
      })

      refute Repo.exists?(
               from ur in UserRole,
                 join: r in Prodigy.Core.Data.Portal.Role,
                 on: r.id == ur.role_id,
                 where: ur.user_id == ^target.id and r.name == "viewer"
             )
    end

    test "invariant 1 blocks revoking the last admin", %{conn: conn, admin: admin} do
      # Make a second admin so the initial state has two platform admins;
      # then remove one, then try to remove the other. First revoke
      # should succeed (admin count 2 -> 1); second would drop to zero
      # and must be refused. Important - the second revoke must be by
      # a different actor than the target (invariant 2).
      other = admin_user_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/portal/users")
      render_click(view, "open_edit", %{"id" => Integer.to_string(other.id)})

      render_click(view, "toggle_role", %{
        "user_id" => Integer.to_string(other.id),
        "role" => "platform-admin"
      })

      # `other` no longer has platform-admin.
      refute Repo.exists?(
               from ur in UserRole,
                 join: r in Prodigy.Core.Data.Portal.Role,
                 on: r.id == ur.role_id,
                 where: ur.user_id == ^other.id and r.name == "platform-admin"
             )

      # Now a third actor (neither admin nor other) tries to revoke
      # the remaining admin's role. Simulate that by having `other`
      # attempt it - but `other` is no longer an admin and can't
      # reach the tab. Instead do the check directly through Authz
      # with an arbitrary third actor.
      third = user_fixture()
      assert {:error, :last_admin} = Authz.revoke_role(third.id, admin.id, "platform-admin")
    end
  end

  describe "edit modal - direct scopes" do
    test "grants and revokes a direct scope via checkbox", %{conn: conn} do
      target = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin/portal/users")
      render_click(view, "open_edit", %{"id" => Integer.to_string(target.id)})
      render_click(view, "switch_edit_mode", %{"mode" => "scopes"})

      render_click(view, "toggle_scope", %{
        "user_id" => Integer.to_string(target.id),
        "scope" => "objects.view"
      })

      assert Repo.exists?(
               from us in UserScope,
                 where: us.user_id == ^target.id and us.scope == "objects.view"
             )

      render_click(view, "toggle_scope", %{
        "user_id" => Integer.to_string(target.id),
        "scope" => "objects.view"
      })

      refute Repo.exists?(
               from us in UserScope,
                 where: us.user_id == ^target.id and us.scope == "objects.view"
             )
    end
  end

  describe "force logout" do
    test "deletes the target's session tokens and writes an audit event",
         %{conn: conn} do
      target = user_fixture()

      # Create a session token for the target so we can confirm it gets deleted.
      {_token_binary, user_token} =
        Prodigy.Core.Data.Portal.UserToken.build_session_token(target)

      {:ok, _} = Repo.insert(user_token)

      {:ok, view, _html} = live(conn, ~p"/admin/portal/users")
      render_click(view, "force_logout", %{"id" => Integer.to_string(target.id)})

      refute Repo.exists?(
               from t in Prodigy.Core.Data.Portal.UserToken,
                 where: t.user_id == ^target.id and t.context == "session"
             )

      assert Repo.exists?(
               from e in AuditEvent,
                 where: e.action == "force_logout" and e.target_id == ^Integer.to_string(target.id)
             )
    end
  end
end
