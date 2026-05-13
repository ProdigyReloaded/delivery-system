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

defmodule Prodigy.Portal.AccountsTest do
  use Prodigy.Portal.DataCase

  alias Prodigy.Portal.Accounts

  import Prodigy.Portal.AccountsFixtures
  alias Prodigy.Core.Data.Portal.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.confirmed_at)
      # No :identity row is created until the user sets a password.
      refute Prodigy.Core.Data.Repo.exists?(
               Ecto.Query.from(i in Prodigy.Core.Data.Portal.Identity,
                 where: i.user_id == ^user.id
               )
             )
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = NaiveDateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: NaiveDateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: NaiveDateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: NaiveDateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: NaiveDateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      # Password fields live on Identity, not User.
      refute Map.has_key?(user, :password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert NaiveDateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      # Insert a password identity directly to simulate "user somehow has a
      # password but isn't confirmed" - which login_user_by_magic_link now
      # detects by querying portal_identities rather than a column on User.
      Repo.insert!(%Prodigy.Core.Data.Portal.Identity{
        user_id: user.id,
        provider: :identity,
        hashed_password: "hashed"
      })

      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the Identity module" do
    alias Prodigy.Core.Data.Portal.Identity

    test "does not include password" do
      refute inspect(%Identity{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "request_access/2 - unified auth entry" do
    setup do
      Prodigy.Portal.Accounts.RateLimit.reset()
      :ok
    end

    defp url_fns do
      [
        login: &"https://test/users/login/#{&1}",
        confirm: &"https://test/users/confirm/#{&1}",
        dismiss: &"https://test/users/dismiss/#{&1}"
      ]
    end

    test "existing user -> mints a :login token" do
      user = user_fixture()
      assert :ok = Accounts.request_access(user.email, url_fns())

      assert Repo.get_by(UserToken, user_id: user.id, context: "login")
    end

    test "unknown email -> mints a :signup_invitation with no user row" do
      email = "new-#{System.unique_integer([:positive])}@example.com"
      assert :ok = Accounts.request_access(email, url_fns())

      assert %UserToken{user_id: nil} =
               Repo.get_by(UserToken, sent_to: email, context: "signup_invitation")

      refute Accounts.get_user_by_email(email)
    end

    test "email is trimmed and downcased before lookup" do
      user = user_fixture()
      mixed = "  " <> String.upcase(user.email) <> "  "
      assert :ok = Accounts.request_access(mixed, url_fns())
      assert Repo.get_by(UserToken, user_id: user.id, context: "login")
    end

    test "blacklisted email -> silent drop, no token minted" do
      email = "bl-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Prodigy.Portal.Accounts.Blacklist.add(email, "wasnt_me")

      assert :ok = Accounts.request_access(email, url_fns())
      refute Repo.get_by(UserToken, sent_to: email)
    end

    test "invalid email format -> silent drop" do
      assert :ok = Accounts.request_access("not-an-email", url_fns())
      assert Repo.aggregate(UserToken, :count) == 0
    end

    test "4th request within the hour -> silent drop" do
      email = "rl-#{System.unique_integer([:positive])}@example.com"

      for _ <- 1..3, do: :ok = Accounts.request_access(email, url_fns())
      assert :ok = Accounts.request_access(email, url_fns())

      count =
        Repo.aggregate(
          from(t in UserToken, where: t.sent_to == ^email and t.context == "signup_invitation"),
          :count
        )

      assert count == 3
    end
  end

  describe "consume_signup_invitation/1" do
    test "creates a confirmed user and deletes the token" do
      email = "confirm-#{System.unique_integer([:positive])}@example.com"

      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      assert {:ok, %User{email: ^email, confirmed_at: %NaiveDateTime{}}} =
               Accounts.consume_signup_invitation(encoded)

      refute Repo.get_by(UserToken, context: "signup_invitation", sent_to: email)
    end

    test "attaches pending provider identity when the token carried one" do
      email = "oauth-#{System.unique_integer([:positive])}@example.com"

      {encoded, token} =
        UserToken.build_signup_invitation_token(email, %{
          "provider" => "google",
          "uid" => "goog-123"
        })

      Repo.insert!(token)

      assert {:ok, %User{} = user} = Accounts.consume_signup_invitation(encoded)

      assert [identity] = Accounts.list_identities(user)
      assert identity.provider == :google
      assert identity.provider_uid == "goog-123"
    end

    test "bad token -> {:error, :invalid}" do
      assert {:error, :invalid} = Accounts.consume_signup_invitation("not-a-token")
    end

    test "blacklisted email between mint and click -> {:error, :invalid}, token deleted" do
      email = "bl-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      {:ok, _} = Prodigy.Portal.Accounts.Blacklist.add(email, "wasnt_me")

      assert {:error, :invalid} = Accounts.consume_signup_invitation(encoded)
      refute Repo.get_by(UserToken, sent_to: email, context: "signup_invitation")
    end
  end

  describe "consume_provider_link_invitation/1" do
    test "attaches the provider to the existing user and deletes the token" do
      user = user_fixture()

      {encoded, token} =
        UserToken.build_provider_link_invitation_token(user, :github, "gh-99")

      Repo.insert!(token)

      assert {:ok, %User{id: uid}} = Accounts.consume_provider_link_invitation(encoded)
      assert uid == user.id

      assert [%{provider: :github, provider_uid: "gh-99"}] =
               Accounts.list_identities(user)

      refute Repo.get_by(UserToken, sent_to: user.email, context: "provider_link_invitation")
    end

    test "bad token -> {:error, :invalid}" do
      assert {:error, :invalid} = Accounts.consume_provider_link_invitation("not-a-token")
    end
  end

  describe "dismiss_invitation/1" do
    test "deletes a signup_invitation token and blacklists the email" do
      email = "dismiss-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      assert :ok = Accounts.dismiss_invitation(encoded)
      refute Repo.get_by(UserToken, sent_to: email)
      assert Prodigy.Portal.Accounts.Blacklist.blacklisted?(email)
    end

    test "deletes a provider_link_invitation token and blacklists the email" do
      user = user_fixture()

      {encoded, token} =
        UserToken.build_provider_link_invitation_token(user, :google, "g-1")

      Repo.insert!(token)

      assert :ok = Accounts.dismiss_invitation(encoded)
      refute Repo.get_by(UserToken, sent_to: user.email, context: "provider_link_invitation")
      assert Prodigy.Portal.Accounts.Blacklist.blacklisted?(user.email)
    end

    test "unknown / expired token -> still :ok, nothing to do" do
      assert :ok = Accounts.dismiss_invitation("never-was-a-token")
    end
  end

  describe "process_oauth_callback/4" do
    setup do
      Prodigy.Portal.Accounts.RateLimit.reset()
      :ok
    end

    test "linked identity -> {:logged_in, user}" do
      user = user_fixture()

      {:ok, _} =
        Accounts.attach_identity(user, %{provider: :google, provider_uid: "g-existing"})

      assert {:logged_in, %User{id: uid}} =
               Accounts.process_oauth_callback(:google, "g-existing", user.email, url_fns())

      assert uid == user.id
    end

    test "same email, different provider -> attaches the new identity, logs in" do
      user = user_fixture()

      assert {:logged_in, %User{id: uid}} =
               Accounts.process_oauth_callback(:google, "g-new", user.email, url_fns())

      assert uid == user.id

      # The new provider identity is now attached to the existing user.
      assert Repo.get_by(Prodigy.Core.Data.Portal.Identity,
               user_id: user.id,
               provider: :google,
               provider_uid: "g-new"
             )
    end

    test "brand-new email -> creates user and logs in inline" do
      email = "oauth-new-#{System.unique_integer([:positive])}@example.com"

      assert {:logged_in, %User{id: uid, email: ^email}} =
               Accounts.process_oauth_callback(:github, "gh-new", email, url_fns())

      # The github identity is linked to the freshly-created user.
      assert Repo.get_by(Prodigy.Core.Data.Portal.Identity,
               user_id: uid,
               provider: :github,
               provider_uid: "gh-new"
             )
    end

    test "blacklisted email -> :blocked, no token" do
      email = "blocked-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Prodigy.Portal.Accounts.Blacklist.add(email, "wasnt_me")

      assert :blocked =
               Accounts.process_oauth_callback(:google, "g-blocked", email, url_fns())

      refute Repo.get_by(UserToken, sent_to: email)
    end
  end
end
