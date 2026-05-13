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

defmodule Prodigy.Portal.AdminLive.Portal.AuditTest do
  use Prodigy.Portal.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Portal.Authz

  setup %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "route gate" do
    test "redirects a user without system.view_audit_log", %{conn: conn} do
      conn = Phoenix.ConnTest.recycle(conn)
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/portal/audit")
    end
  end

  describe "list view" do
    test "renders recent grant/revoke events with actor emails", %{conn: conn, admin: admin} do
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")
      {:ok, _} = Authz.grant_scope(admin.id, target.id, "objects.upload")

      {:ok, _view, html} = live(conn, ~p"/admin/portal/audit")

      assert html =~ "grant.role"
      assert html =~ "grant.scope"
      assert html =~ admin.email
      assert html =~ Integer.to_string(target.id)
    end

    test "system-initiated events render as 'system'", %{conn: conn} do
      target = user_fixture()
      {:ok, _} = Authz.grant_scope(nil, target.id, "objects.view")

      {:ok, _view, html} = live(conn, ~p"/admin/portal/audit")
      assert html =~ "system"
    end
  end

  describe "filters" do
    test "filters by action", %{conn: conn, admin: admin} do
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")
      {:ok, _} = Authz.grant_scope(admin.id, target.id, "objects.upload")

      {:ok, view, _html} = live(conn, ~p"/admin/portal/audit")

      html =
        render_change(view, "filter", %{"filters" => %{"action" => "grant.role"}})

      assert html =~ "grant.role"
      refute html =~ "grant.scope"
    end

    test "filters by actor email", %{conn: conn, admin: admin} do
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")
      # A system-initiated event with no actor_id - should be filtered
      # out when we filter by actor_email.
      {:ok, _} = Authz.grant_scope(nil, target.id, "objects.view")

      {:ok, view, _html} = live(conn, ~p"/admin/portal/audit")
      html = render_change(view, "filter", %{"filters" => %{"actor_email" => admin.email}})

      assert html =~ "grant.role"
      refute html =~ "grant.scope"
    end

    test "filter on unknown actor email yields no rows", %{conn: conn, admin: admin} do
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")

      {:ok, view, _html} = live(conn, ~p"/admin/portal/audit")

      html =
        render_change(view, "filter", %{
          "filters" => %{"actor_email" => "ghost@example.com"}
        })

      assert html =~ "No events match"
    end
  end
end
