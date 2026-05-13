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

defmodule Prodigy.Portal.InvitationControllerTest do
  use Prodigy.Portal.ConnCase, async: false

  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Core.Data.Portal.UserToken
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Accounts
  alias Prodigy.Portal.Accounts.{Blacklist, RateLimit}

  setup do
    RateLimit.reset()
    :ok
  end

  describe "GET /users/confirm/:token" do
    test "signup_invitation token creates + logs in + deletes token", %{conn: conn} do
      email = "c-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      conn = get(conn, ~p"/users/confirm/#{encoded}")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email(email)
      refute Repo.get_by(UserToken, sent_to: email, context: "signup_invitation")
    end

    test "provider_link_invitation token attaches + logs in", %{conn: conn} do
      user = user_fixture()

      {encoded, token} =
        UserToken.build_provider_link_invitation_token(user, :google, "g-link")

      Repo.insert!(token)

      conn = get(conn, ~p"/users/confirm/#{encoded}")

      assert redirected_to(conn) == ~p"/"
      assert [%{provider: :google, provider_uid: "g-link"}] = Accounts.list_identities(user)
    end

    test "bad / expired token renders the generic invalid-link page", %{conn: conn} do
      conn = get(conn, ~p"/users/confirm/not-a-real-token")
      assert response(conn, 200) =~ "Link expired or invalid"
    end
  end

  describe "GET /users/dismiss/:token" do
    test "blacklists the email and deletes the token", %{conn: conn} do
      email = "d-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      conn = get(conn, ~p"/users/dismiss/#{encoded}")

      assert response(conn, 200) =~ "Request cancelled"
      refute Repo.get_by(UserToken, sent_to: email)
      assert Blacklist.blacklisted?(email)
    end

    test "unknown token still renders the uniform dismissed page", %{conn: conn} do
      conn = get(conn, ~p"/users/dismiss/not-a-real-token")
      assert response(conn, 200) =~ "Request cancelled"
    end
  end
end
