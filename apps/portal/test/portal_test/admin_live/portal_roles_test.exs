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

defmodule Prodigy.Portal.AdminLive.Portal.RolesTest do
  use Prodigy.Portal.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Core.Data.Portal.AuditEvent
  alias Prodigy.Core.Data.Portal.Role
  alias Prodigy.Core.Data.Portal.RoleScope
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Admin.Roles
  alias Prodigy.Portal.Authz

  setup %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "route gate" do
    test "redirects a user without roles.view", %{conn: conn} do
      conn = Phoenix.ConnTest.recycle(conn)
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/portal/roles")
    end
  end

  describe "list view" do
    test "renders every builtin role with its scope set", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/portal/roles")

      assert html =~ "Viewer"
      assert html =~ "Content Operator"
      assert html =~ "Support Operator"
      assert html =~ "Platform Admin"
      assert html =~ "objects.upload"
    end
  end

  describe "create custom role" do
    test "creates a role with selected scopes and audits", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, ~p"/admin/portal/roles")

      render_click(view, "open_new")
      render_click(view, "toggle_scope", %{"scope" => "objects.view"})
      render_click(view, "toggle_scope", %{"scope" => "keywords.view"})

      render_submit(
        form(view, "#role-form", %{
          "role" => %{
            "name" => "kw-curator",
            "label" => "Keyword Curator",
            "description" => "Reads objects and keywords"
          }
        })
      )

      role = Repo.get_by!(Role, name: "kw-curator")
      assert role.label == "Keyword Curator"
      refute role.builtin

      scopes =
        Repo.all(from rs in RoleScope, where: rs.role_id == ^role.id, select: rs.scope)
        |> Enum.sort()

      assert scopes == ["keywords.view", "objects.view"]

      assert Repo.exists?(
               from e in AuditEvent,
                 where:
                   e.action == "create.role" and e.target_id == ^Integer.to_string(role.id) and
                     e.actor_id == ^admin.id
             )
    end
  end

  describe "edit custom role" do
    test "updates scopes on a non-builtin role", %{conn: conn, admin: admin} do
      {:ok, role} =
        Roles.create_role(
          admin.id,
          %{"name" => "temp", "label" => "Temp"},
          ["objects.view"]
        )

      {:ok, view, _html} = live(conn, ~p"/admin/portal/roles")
      render_click(view, "open_edit", %{"id" => Integer.to_string(role.id)})
      render_click(view, "toggle_scope", %{"scope" => "objects.view"})
      render_click(view, "toggle_scope", %{"scope" => "keywords.view"})

      render_submit(
        form(view, "#role-form", %{
          "role" => %{"label" => "Temp Renamed", "description" => ""}
        })
      )

      reloaded = Repo.get!(Role, role.id)
      assert reloaded.label == "Temp Renamed"

      scopes =
        Repo.all(from rs in RoleScope, where: rs.role_id == ^role.id, select: rs.scope)

      assert scopes == ["keywords.view"]
    end

    test "builtin role has no Edit button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/portal/roles")
      platform_admin = Authz.get_role_by_name("platform-admin")
      refute html =~ ~s(phx-value-id="#{platform_admin.id}" ) <> "phx-click=\"open_edit\""
    end
  end

  describe "delete custom role" do
    test "refuses to delete a role with holders", %{conn: conn, admin: admin} do
      {:ok, role} =
        Roles.create_role(admin.id, %{"name" => "held", "label" => "Held"}, [])

      target = user_fixture()
      {:ok, _} = Authz.grant_role(nil, target.id, "held")

      {:ok, view, _html} = live(conn, ~p"/admin/portal/roles")
      html = render_click(view, "delete", %{"id" => Integer.to_string(role.id)})

      assert html =~ "held by"
      assert Repo.get!(Role, role.id)
    end

    test "deletes an unused role and audits", %{conn: conn, admin: admin} do
      {:ok, role} =
        Roles.create_role(admin.id, %{"name" => "unused", "label" => "Unused"}, [])

      {:ok, view, _html} = live(conn, ~p"/admin/portal/roles")
      render_click(view, "delete", %{"id" => Integer.to_string(role.id)})

      refute Repo.get(Role, role.id)

      assert Repo.exists?(
               from e in AuditEvent,
                 where:
                   e.action == "delete.role" and e.target_id == ^Integer.to_string(role.id)
             )
    end

    test "refuses to delete a builtin role via the context", %{admin: admin} do
      builtin = Authz.get_role_by_name("platform-admin")
      assert {:error, :builtin} = Roles.delete_role(admin.id, builtin)
    end
  end
end
