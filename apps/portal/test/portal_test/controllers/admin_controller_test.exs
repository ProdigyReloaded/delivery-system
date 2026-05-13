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

defmodule Prodigy.Portal.AdminControllerTest do
  @moduledoc """
  `/admin` is a redirect landing page - it routes the caller to the
  first admin surface their scope set lets them see, or bounces to
  `/` with a flash if they have no admin scopes.
  """
  use Prodigy.Portal.ConnCase, async: true

  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Portal.Authz

  describe "GET /admin" do
    test "redirects anonymous callers to /users/login", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      assert redirected_to(conn) =~ "/users/login"
    end

    test "redirects a user with no admin scopes to / with a flash", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      conn = get(conn, ~p"/admin")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "don't have access"
    end

    test "redirects a platform admin to the first page in the nav", %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)
      conn = get(conn, ~p"/admin")
      # First item in the sidebar nav is Portal Users - platform admins
      # have that scope, so that's where they land.
      assert redirected_to(conn) == "/admin/portal/users"
    end

    test "redirects a keyword-only operator straight to keywords", %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Authz.grant_scope(nil, user.id, "keywords.view")
      conn = log_in_user(conn, user)
      conn = get(conn, ~p"/admin")
      assert redirected_to(conn) == "/admin/service/keywords"
    end
  end
end
