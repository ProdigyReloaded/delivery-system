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

defmodule Prodigy.Portal.UserLive.LoginTest do
  use Prodigy.Portal.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Core.Data.Portal.UserToken
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Accounts.{Blacklist, RateLimit}

  setup do
    RateLimit.reset()
    :ok
  end

  describe "login page" do
    test "renders the unified login page with email field and oauth area", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/login")

      assert html =~ "Login or Sign Up"
      assert html =~ "Continue"
      assert html =~ "Already have a password?"
      refute html =~ "/users/register"
    end

    test "password toggle reveals the password field and 'Stay logged in'", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      html = lv |> element("a", "Already have a password?") |> render_click()
      assert html =~ ~s(type="password")
      assert html =~ "Stay logged in"
      assert html =~ "Email me a link instead"
    end

    test "password toggle uses the same form element so the email input is preserved",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      html = lv |> element("a", "Already have a password?") |> render_click()

      # Same form id + same email input id across the toggle. LV morphdom
      # leaves the user's typed value alone when the node is stable, so
      # the browser keeps whatever the user had entered.
      assert html =~ ~s(id="login_form")
      assert html =~ ~s(id="login_form_email")
    end
  end

  describe "submit_magic - enumeration parity" do
    test "shows the same 'check your inbox' state for a known email", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      html =
        form(lv, "#login_form", user: %{email: user.email})
        |> render_submit()

      assert html =~ "We sent a link to"
      assert html =~ user.email
      assert html =~ "15 minutes"
    end

    test "shows the same 'check your inbox' state for an unknown email", %{conn: conn} do
      email = "nobody-#{System.unique_integer([:positive])}@example.com"
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      html =
        form(lv, "#login_form", user: %{email: email})
        |> render_submit()

      assert html =~ "We sent a link to"
      assert html =~ email
    end

    test "mints a :login magic-link token for an existing user", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      form(lv, "#login_form", user: %{email: user.email}) |> render_submit()

      assert %UserToken{context: "login"} =
               Repo.get_by(UserToken, user_id: user.id, context: "login")
    end

    test "mints a :signup_invitation token (no user) for a new email", %{conn: conn} do
      email = "newuser-#{System.unique_integer([:positive])}@example.com"
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      form(lv, "#login_form", user: %{email: email}) |> render_submit()

      assert %UserToken{user_id: nil, sent_to: ^email} =
               Repo.get_by(UserToken, context: "signup_invitation", sent_to: email)
    end

    test "blacklisted email silently drops - no token, uniform UI", %{conn: conn} do
      email = "blacklisted-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Blacklist.add(email, "wasnt_me")

      {:ok, lv, _html} = live(conn, ~p"/users/login")

      html =
        form(lv, "#login_form", user: %{email: email})
        |> render_submit()

      assert html =~ "We sent a link to"
      refute Repo.get_by(UserToken, sent_to: email, context: "signup_invitation")
    end

    test "invitation rate limit silently drops after the 4th request", %{conn: conn} do
      email = "rate-#{System.unique_integer([:positive])}@example.com"

      for _ <- 1..3 do
        {:ok, lv, _} = live(conn, ~p"/users/login")
        form(lv, "#login_form", user: %{email: email}) |> render_submit()
      end

      # 4th request is over the hourly invitation limit.
      {:ok, lv, _} = live(conn, ~p"/users/login")

      html =
        form(lv, "#login_form", user: %{email: email})
        |> render_submit()

      # UI still shows the uniform response.
      assert html =~ "We sent a link to"

      count =
        Repo.aggregate(
          from(t in UserToken, where: t.sent_to == ^email and t.context == "signup_invitation"),
          :count
        )

      assert count == 3
    end

    test "'Use a different email' link resets the sent state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/login")

      form(lv, "#login_form", user: %{email: "foo@example.com"}) |> render_submit()

      html = lv |> element("a", "Use a different email") |> render_click()
      assert html =~ ~s(id="login_form")
      refute html =~ "We sent a link to"
    end
  end

  describe "password form" do
    test "valid credentials log in and redirect", %{conn: conn} do
      user = user_fixture() |> set_password()
      {:ok, lv, _html} = live(conn, ~p"/users/login")
      lv |> element("a", "Already have a password?") |> render_click()

      form =
        form(lv, "#login_form",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)
      assert redirected_to(conn) == ~p"/"
    end

    test "invalid credentials return to login with a flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/login")
      lv |> element("a", "Already have a password?") |> render_click()

      form =
        form(lv, "#login_form", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/login"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows the re-auth header with the email prefilled", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/login")

      assert html =~ "Re-authenticate"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_email" value="#{user.email}")
    end
  end

end
