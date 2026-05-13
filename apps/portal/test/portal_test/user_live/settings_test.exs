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

defmodule Prodigy.Portal.UserLive.SettingsTest do
  use Prodigy.Portal.ConnCase, async: true

  alias Prodigy.Portal.Accounts
  import Phoenix.LiveViewTest
  import Prodigy.Portal.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/login"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/login")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/login"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  describe "API keys" do
    alias Prodigy.Portal.ApiKeys

    setup %{conn: conn} do
      user = user_fixture()
      # The API keys section is gated on the api_keys.self scope; grant
      # it so every test in this block sees the mint form + listing.
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "api_keys.self")
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders the section and 'no keys yet' empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings/api-keys")

      assert html =~ "API keys"
      assert html =~ "No API keys yet."
    end

    test "creates a key and shows the plaintext once", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/api-keys")

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => "laptop"}})
        |> render_submit()

      # Plaintext is shown in the banner.
      assert html =~ "Key created."
      assert html =~ ~r/pk_[a-z2-7]{26}/
      # Table now lists the key.
      assert html =~ "laptop"

      # DB has exactly one hashed key for the user, with the matching
      # prefix.
      assert [stored] = ApiKeys.list_for_user(user.id)
      assert stored.name == "laptop"
      assert is_binary(stored.key_hash)
      assert byte_size(stored.key_hash) == 32
    end

    test "refuses to create a key with a blank name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/api-keys")

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "dismisses the one-time banner", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/api-keys")

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => "k"}})
        |> render_submit()

      # Banner contains the plaintext in its dedicated code element.
      assert html =~ "new-api-key-plaintext"

      html = render_click(lv, "dismiss_new")
      refute html =~ "new-api-key-plaintext"
    end

    test "revokes a live key", %{conn: conn, user: user} do
      {:ok, _} = ApiKeys.create(user.id, %{name: "to-revoke"})
      [%{id: id}] = ApiKeys.list_for_user(user.id)

      {:ok, lv, html} = live(conn, ~p"/users/settings/api-keys")
      assert html =~ "to-revoke"
      assert html =~ "Active"

      html = render_click(lv, "revoke", %{"id" => Integer.to_string(id)})

      assert html =~ "Revoked"
      refute html =~ "Active"
    end

    test "only shows the current user's keys", %{conn: conn, user: user} do
      other = user_fixture()
      {:ok, _} = ApiKeys.create(user.id, %{name: "mine"})
      {:ok, _} = ApiKeys.create(other.id, %{name: "theirs"})

      {:ok, _lv, html} = live(conn, ~p"/users/settings/api-keys")

      assert html =~ "mine"
      refute html =~ "theirs"
    end

    test "the scope picker only lists the owner's non-forbidden scopes",
         %{conn: conn, user: user} do
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "objects.upload")
      # Granting a forbidden-for-keys scope still doesn't surface it in
      # the picker; this is the critical no-escalation property of
      # key minting.
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "grants.assign")

      {:ok, _lv, html} = live(conn, ~p"/users/settings/api-keys")

      assert html =~ ~s(value="objects.upload")
      refute html =~ ~s(value="api_keys.self")
      refute html =~ ~s(value="grants.assign")
    end

    test "minting a key with specific scopes attaches them",
         %{conn: conn, user: user} do
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "objects.upload")
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "objects.view")

      {:ok, lv, _html} = live(conn, ~p"/users/settings/api-keys")

      lv
      |> form("#api_key_form", %{
        "api_key" => %{"name" => "scoped", "scopes" => ["objects.upload"]}
      })
      |> render_submit()

      [stored] = ApiKeys.list_for_user(user.id)
      assert stored.scopes == ["objects.upload"]
    end

    test "minting with no checkboxes creates a capability-less key",
         %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/api-keys")

      lv
      |> form("#api_key_form", %{"api_key" => %{"name" => "empty"}})
      |> render_submit()

      [stored] = ApiKeys.list_for_user(user.id)
      assert stored.scopes == []
    end

    test "degraded-scope badge appears when the owner loses a scope on a key",
         %{conn: conn, user: user} do
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "objects.upload")
      {:ok, _} = ApiKeys.create(user.id, %{name: "k", scopes: ["objects.upload"]})
      {:ok, _} = Prodigy.Portal.Authz.revoke_scope(nil, user.id, "objects.upload")

      {:ok, _lv, html} = live(conn, ~p"/users/settings/api-keys")

      assert html =~ "degraded"
    end
  end

  describe "API keys section - not enabled" do
    test "users without api_keys.self see no API keys link in the sidebar",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/users/settings")

      refute html =~ "API keys"
      refute html =~ ~s(id="api_key_form")
    end

    test "users without api_keys.self can't open /users/settings/api-keys",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/users/settings/api-keys")

      assert path == ~p"/"
    end
  end
end
