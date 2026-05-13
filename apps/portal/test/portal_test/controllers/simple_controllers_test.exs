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

defmodule Prodigy.Portal.SimpleControllersTest do
  @moduledoc """
  Smoke coverage for the lightweight portal controllers - health check,
  static page renders, signup-done session stash, get-started redirect
  for anon vs signed-in, account-link form gating.
  """
  use Prodigy.Portal.ConnCase, async: true

  describe "HealthController" do
    test "GET /_health returns 200 ok", %{conn: conn} do
      conn = get(conn, ~p"/_health")
      assert response(conn, 200) == "ok"
    end
  end

  describe "PageController static routes" do
    test "GET / renders the home page", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Prodigy"
    end

    test "GET /faq, /history, /start all render 200", %{conn: conn} do
      for path <- [~p"/faq", ~p"/history", ~p"/start"] do
        conn = get(conn, path)
        assert html_response(conn, 200)
      end
    end
  end

  describe "PageController.get_started/2" do
    test "anon visitors get flashed and sent to login with return_to stashed", %{
      conn: conn
    } do
      conn = get(conn, ~p"/get-started")

      assert redirected_to(conn) =~ "/users/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Prodigy account"
      assert get_session(conn, :user_return_to) == ~p"/signup"
    end

    test "signed-in visitors go straight to /signup", %{conn: conn} do
      user = Prodigy.Portal.AccountsFixtures.user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/get-started")
      assert redirected_to(conn) == ~p"/signup"
    end
  end

  describe "PageController.signup_done/2" do
    test "stashes the password keyed by service-user id in the session and redirects to /start",
         %{conn: conn} do
      user = Prodigy.Portal.AccountsFixtures.user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> init_test_session(%{})
        |> post(~p"/signup/done", %{"password" => "ABCD1234", "user_id" => "AAAA12A"})

      assert redirected_to(conn) == ~p"/start"
      assert get_session(conn, :fresh_passwords) == %{"AAAA12A" => "ABCD1234"}
    end

    test "missing password param still redirects (no crash)", %{conn: conn} do
      user = Prodigy.Portal.AccountsFixtures.user_fixture()
      conn = conn |> log_in_user(user) |> init_test_session(%{}) |> post(~p"/signup/done", %{})
      assert redirected_to(conn) == ~p"/start"
    end
  end

  describe "TcsUpgradeController.upgrade/2" do
    test "rejects a non-WebSocket GET /tcs with an UpgradeError", %{conn: conn} do
      # A real browser request carries the Upgrade + Sec-WebSocket-*
      # headers that websock_adapter validates. Phoenix.ConnTest synthesizes
      # a plain HTTP GET, so the adapter raises UpgradeError - exactly
      # what we want: plain HTTP clients can't reach the TCS handler
      # without advertising WS upgrade intent.
      assert_raise WebSockAdapter.UpgradeError, fn ->
        get(conn, ~p"/tcs")
      end
    end
  end
end
