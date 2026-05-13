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

defmodule Prodigy.Portal.AdminLive.ScopeGatesTest do
  @moduledoc """
  Cross-cutting tests for the scope-based authz gates that landed in
  slice 5b: route-level `:require_scope` hooks and per-action gates
  inside the LiveComponents. The per-tab test files exercise the
  happy path with a platform admin; this file exercises the denial
  paths with scope-limited users.
  """
  use Prodigy.Portal.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Portal.Authz

  defp viewer_with(scope) do
    user = user_fixture()
    {:ok, _} = Authz.grant_scope(nil, user.id, scope)
    user
  end

  describe "route-level :require_scope redirects" do
    test "a user without service_users.view can't reach /admin/service/users",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/service/users")
    end

    test "a user without objects.view can't reach /admin/service/objects",
         %{conn: conn} do
      user = viewer_with("service_users.view")
      conn = log_in_user(conn, user)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/service/objects")
    end

    test "a user without keywords.view can't reach /admin/service/keywords",
         %{conn: conn} do
      user = viewer_with("objects.view")
      conn = log_in_user(conn, user)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/service/keywords")
    end

    test "service_users.view on its own reaches /admin/service/users",
         %{conn: conn} do
      user = viewer_with("service_users.view")
      conn = log_in_user(conn, user)
      assert {:ok, _view, html} = live(conn, ~p"/admin/service/users")
      assert html =~ "Service Users"
    end
  end

  describe "per-action gates inside the LiveComponents" do
    test "a viewer-only user on the objects page sees no upload button",
         %{conn: conn} do
      user = viewer_with("objects.view")
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/admin/service/objects")
      refute html =~ "Upload objects"
    end

    test "a viewer-only user on the keywords page sees no rebuild button",
         %{conn: conn} do
      user = viewer_with("keywords.view")
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/admin/service/keywords")
      refute html =~ ~s(phx-click="rebuild_index")
    end

  end

  describe "sidebar visibility" do
    test "a viewer of only one section sees only that section",
         %{conn: conn} do
      user = viewer_with("keywords.view")
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/admin/service/keywords")
      # Service > Keywords visible; no Online/Users/Objects items
      # because the user lacks their view scopes.
      assert html =~ "Keywords"
      refute html =~ ~s(href="/admin/service/online")
      refute html =~ ~s(href="/admin/service/users")
      refute html =~ ~s(href="/admin/service/objects")
    end
  end
end
