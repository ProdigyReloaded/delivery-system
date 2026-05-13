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

defmodule Prodigy.Portal.Accounts do
  @moduledoc """
  Account operations: user profile (`Prodigy.Core.Data.Portal.User`) plus its
  auth methods (`Prodigy.Core.Data.Portal.Identity`). One user may have many
  identities - an `:identity` row for email+password, plus OAuth rows for
  each linked provider.
  """

  import Ecto.Query, warn: false
  alias Prodigy.Core.Data.Repo

  alias Prodigy.Core.Data.Portal.{User, UserToken, Identity}
  alias Prodigy.Portal.Accounts.Blacklist
  alias Prodigy.Portal.Accounts.RateLimit
  alias Prodigy.Portal.Accounts.UserNotifier

  ## Database getters

  @doc "Gets a user by email."
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password by looking up the user's :identity row
  and verifying pbkdf2. Returns `nil` if the user doesn't exist, the user
  has no :identity identity (e.g. OAuth-only), or the password is wrong.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    identity =
      Repo.one(
        from i in Identity,
          join: u in assoc(i, :user),
          where: u.email == ^email and i.provider == :identity,
          preload: [user: u]
      )

    if Identity.valid_password?(identity, password) do
      identity.user
    end
  end

  @doc "Gets a single user; raises if missing."
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user by email only. Phoenix 1.7's gen.auth flow is magic-link
  first: email the user, they click the link, they land logged in, and they
  set a password via the Settings page. The :identity row gets created
  lazily by `update_user_password/2` the first time they save a password.
  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Attaches a new identity (OAuth or password) to an existing user.

  Used by:
    * OAuth callback on first login for an already-registered email, after
      the user has confirmed ownership of the existing account via the link
      flow.
    * Future "add another provider" button on the Settings page.
  """
  def attach_identity(%User{} = user, attrs) do
    changeset =
      cond do
        attrs[:provider] == :identity or attrs["provider"] == "identity" ->
          Identity.password_changeset(%Identity{user_id: user.id}, attrs)

        true ->
          Identity.oauth_changeset(%Identity{user_id: user.id}, attrs)
      end

    Repo.insert(changeset)
  end

  @doc """
  Lists the identities attached to a user, newest first. Used by the
  Settings page to show which auth methods are connected.
  """
  def list_identities(%User{id: id}) do
    Repo.all(from i in Identity, where: i.user_id == ^id, order_by: [desc: i.inserted_at])
  end

  @doc """
  Attaches `{provider, provider_uid}` to an already-logged-in user. Used by
  the OAuth callbacks and the mock controller when the caller has a current
  scope set - clicking "Link Google" from the Settings page goes through
  the same OAuth round-trip as a first-time login, so the callback needs a
  clean path for "this identity is being added to the current user".

  Returns:
    * `{:ok, %Identity{}}` - newly attached.
    * `{:ok, :already_linked}` - the identity already belongs to this user.
    * `{:error, :taken_by_another_user}` - refuse; the identity belongs to
      someone else's portal account.
    * `{:error, %Ecto.Changeset{}}` - insert failed for another reason.
  """
  def link_identity_to_user(%User{} = user, provider, provider_uid)
      when is_atom(provider) and is_binary(provider_uid) do
    case Repo.get_by(Identity, provider: provider, provider_uid: provider_uid) do
      nil ->
        attach_identity(user, %{provider: provider, provider_uid: provider_uid})

      %Identity{user_id: uid} when uid == user.id ->
        {:ok, :already_linked}

      %Identity{} ->
        {:error, :taken_by_another_user}
    end
  end

  @doc """
  Removes an identity from a user. Refuses if it's the user's only
  identity (would lock them out). The identity must belong to the user
  (checked by user_id) - otherwise this is a no-op.
  """
  def unlink_identity(%User{id: user_id} = user, identity_id) do
    case Repo.get_by(Identity, id: identity_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Identity{} = identity ->
        count = Repo.one(from i in Identity, where: i.user_id == ^user_id, select: count())

        if count <= 1 do
          {:error, :last_identity}
        else
          case Repo.delete(identity) do
            {:ok, _} -> {:ok, user}
            error -> error
          end
        end
    end
  end

  @doc """
  Resolves an OAuth callback to a portal user. Three outcomes:

    * `{:ok, %User{}}` - an Identity already exists for `{provider, uid}`;
      returns its user.
    * `{:ok, %User{}}` - no Identity and no email collision; we created
      both a new User and an :oauth Identity in one transaction.
    * `{:pending_link, %User{}, attrs}` - an Identity exists for this email
      but under a different provider. The caller should redirect to the
      link flow, which verifies ownership (password or magic link) before
      calling `attach_identity/2`.

  `attrs` is a map shaped for `Identity.oauth_changeset/2` that the caller
  should persist in the session until the link flow completes.
  """
  def get_or_create_user_by_provider(provider, provider_uid, _email)
      when is_atom(provider) and is_binary(provider_uid) do
    existing =
      Repo.one(
        from i in Identity,
          where: i.provider == ^provider and i.provider_uid == ^provider_uid,
          preload: [:user]
      )

    case existing do
      %Identity{user: %User{} = user} -> {:ok, user}
      nil -> :no_match
    end
  end

  @doc """
  Unified resolver for an OAuth provider callback. Three outcomes:

    * `{:logged_in, %User{}}` - either the provider identity was already
      linked, or this is a first OAuth touch and we created/linked a
      portal user inline. OAuth identity is treated as proof of email
      ownership; no email confirmation step.
    * `:invite_required` - invitation-only mode is on AND the email
      isn't already a portal user AND the caller didn't supply a
      valid pending invite. Caller redirects to the invite-required
      page; no portal user is created.
    * `:blocked` - blacklist or invalid email. Caller surfaces a
      generic failure response.

  Options:
    * `:invite_code` - the pending invite-code string from session
      (or nil). Required when invitation-only mode is on for new
      portal-user creation; ignored when an existing identity is
      already linked or invitation-only mode is off.
  """
  def process_oauth_callback(provider, provider_uid, email, opts \\ [])
      when is_atom(provider) and is_binary(provider_uid) and is_binary(email) do
    case get_or_create_user_by_provider(provider, provider_uid, email) do
      {:ok, %User{} = user} ->
        # Existing identity: re-auth path. Invitation gate doesn't
        # apply because the user already exists.
        {:logged_in, user}

      :no_match ->
        normalized = email |> String.trim() |> String.downcase()
        invite_code = Keyword.get(opts, :invite_code)

        cond do
          not valid_email_format?(normalized) ->
            :blocked

          Blacklist.blacklisted?(normalized) ->
            :blocked

          # Existing portal user with this email but no identity for
          # this provider: this is "linking a new provider to an
          # existing account" - the portal user already exists, so
          # invitation gate doesn't apply.
          not is_nil(get_user_by_email(normalized)) ->
            create_or_link_from_oauth(provider, provider_uid, normalized, nil)

          # Brand-new portal user: invitation gate applies.
          Prodigy.Portal.Settings.invitation_only?() ->
            case load_pending_invite(invite_code) do
              {:ok, invite} ->
                create_or_link_from_oauth(provider, provider_uid, normalized, invite)

              :missing ->
                :invite_required
            end

          # Open mode: brand-new portal user, no gate.
          true ->
            create_or_link_from_oauth(provider, provider_uid, normalized, nil)
        end
    end
  end

  defp load_pending_invite(nil), do: :missing

  defp load_pending_invite(code) when is_binary(code) do
    case Prodigy.Portal.Invites.get_by_code(code) do
      nil ->
        :missing

      invite ->
        if Prodigy.Portal.Invites.redeemable?(invite), do: {:ok, invite}, else: :missing
    end
  end

  # `invite` is either a `%Invite{}` (when invitation-only mode redeemed
  # one in the same transaction) or `nil` (open mode / link-to-existing
  # path). When non-nil, the invite is marked redeemed inside the same
  # Repo.transact so a registration failure rolls the redemption back.
  defp create_or_link_from_oauth(provider, provider_uid, email, invite) do
    data = %{"provider" => Atom.to_string(provider), "uid" => provider_uid}

    result =
      case get_user_by_email(email) do
        %User{} = user ->
          case maybe_attach_provider_identity(user, data) do
            :ok -> {:ok, user}
            {:error, _} = err -> err
          end

        nil ->
          Repo.transact(fn ->
            with {:ok, user} <- register_user(%{email: email}),
                 {:ok, confirmed} <- user |> User.confirm_changeset() |> Repo.update(),
                 :ok <- maybe_attach_provider_identity(confirmed, data),
                 :ok <- maybe_redeem_invite(invite, confirmed) do
              {:ok, confirmed}
            end
          end)
      end

    case result do
      {:ok, user} -> {:logged_in, user}
      _ -> :blocked
    end
  end

  defp maybe_redeem_invite(nil, _user), do: :ok

  defp maybe_redeem_invite(invite, %User{} = redeemer) do
    case invite |> Prodigy.Portal.Invites.redeem_changeset(redeemer) |> Repo.update() do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  ## Settings

  @doc "Checks whether the user authenticated less than `minutes` ago (default -20)."
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, NaiveDateTime) do
    NaiveDateTime.after?(ts, NaiveDateTime.utc_now() |> NaiveDateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc "Returns a changeset for displaying / validating an email change."
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc "Applies an email-change token, updating the email and expiring the token."
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns a changeset for validating a password change against the user's
  :identity identity. For users with no :identity identity (OAuth-only),
  operates on a brand-new Identity so they can set a first password.
  """
  def change_user_password(%User{} = user, attrs \\ %{}, opts \\ []) do
    Identity.password_changeset(identity_for_password(user), attrs, opts)
  end

  defp identity_for_password(%User{id: nil}), do: %Identity{}

  defp identity_for_password(%User{} = user) do
    case Repo.get_by(Identity, user_id: user.id, provider: :identity) do
      %Identity{} = identity -> identity
      nil -> %Identity{user_id: user.id}
    end
  end

  @doc """
  Updates the user's password. Upserts the :identity identity and expires
  every outstanding token (sessions, magic links, etc.) in one transaction.
  """
  def update_user_password(%User{} = user, attrs) do
    changeset = Identity.password_changeset(identity_for_password(user), attrs)

    Repo.transact(fn ->
      with {:ok, _identity} <- Repo.insert_or_update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## Session

  @doc "Generates a session token and persists it."
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "Looks up a user by signed session token. Returns `{user, inserted_at}` or nil."
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc "Looks up a user by magic-link token. Returns `%User{}` or nil."
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link. Three cases:

    1. User already confirmed - log in, expire the link.
    2. User not confirmed, no :identity identity (OAuth-only or brand new) -
       mark confirmed, log in, expire all their tokens.
    3. User not confirmed but has an :identity identity - refuse with a
       clear error. This shouldn't happen under the normal register ->
       confirm -> log in flow and is a potential session-fixation vector
       (see phx.gen.auth's "Mixing magic link and password registration"
       guide).
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      {%User{confirmed_at: nil} = user, _token} ->
        if user_has_password_identity?(user) do
          raise """
          magic link log in is not allowed for unconfirmed users with a password set!
          """
        else
          user
          |> User.confirm_changeset()
          |> update_user_and_delete_all_tokens()
        end

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  defp user_has_password_identity?(%User{id: id}) do
    Repo.exists?(from i in Identity, where: i.user_id == ^id and i.provider == :identity)
  end

  @doc "Emails the user a link to confirm a pending email change."
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc "Emails the user a magic-link login URL."
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Entry point for the unified `/users/login` form. Accepts an email
  (+ url-builder functions) and either:

    * mints a magic-link login token and emails it (for an existing
      user), or
    * mints a `:signup_invitation` token and emails a confirm/dismiss
      pair of links (for an unknown email).

  Returns `:ok` in every case the UI should treat as success -
  including silent drops for blacklisted addresses, rate-limited
  addresses, and bad-format emails. Uniform return keeps the UI
  free of enumeration oracles.

  `url_fns` is a keyword list with:
    * `:login` - arity-1, magic-link URL for an existing user
    * `:confirm` - arity-1, confirm-signup URL for a new email
    * `:dismiss` - arity-1, dismiss URL for the same token
  """
  def request_access(email, url_fns)
      when is_binary(email) and is_list(url_fns) do
    email = email |> String.trim() |> String.downcase()

    cond do
      not valid_email_format?(email) -> :ok
      Blacklist.blacklisted?(email) -> :ok
      RateLimit.check_invitation(email) == :blocked -> :ok
      true -> dispatch_access_request(email, url_fns)
    end
  end

  def request_access(_email, _url_fns), do: :ok

  defp dispatch_access_request(email, url_fns) do
    case get_user_by_email(email) do
      %User{} = user ->
        case RateLimit.check_login(email) do
          :blocked -> :ok
          :ok -> deliver_login_instructions(user, Keyword.fetch!(url_fns, :login))
        end

      nil ->
        deliver_signup_invitation(email, url_fns)
    end

    :ok
  end

  defp deliver_signup_invitation(email, url_fns) do
    {encoded, token} = UserToken.build_signup_invitation_token(email)
    Repo.insert!(token)

    UserNotifier.deliver_signup_invitation(
      email,
      Keyword.fetch!(url_fns, :confirm).(encoded),
      Keyword.fetch!(url_fns, :dismiss).(encoded)
    )
  end

  @doc """
  Consume a signup-invitation token: verifies it, creates the
  portal user row, attaches any provider identity that was pending
  on the token, deletes the token, and returns `{:ok, user}`. Any
  failure - expired token, bad token, blacklisted email between
  mint and click - returns `{:error, :invalid}`.
  """
  def consume_signup_invitation(encoded_token) when is_binary(encoded_token) do
    with {:ok, query} <- UserToken.verify_invitation_token(encoded_token, "signup_invitation"),
         %UserToken{sent_to: email, data: data} = token <- Repo.one(query) do
      cond do
        Blacklist.blacklisted?(email) ->
          Repo.delete!(token)
          {:error, :invalid}

        true ->
          Repo.transact(fn ->
            with {:ok, user} <- register_user(%{email: email}),
                 {:ok, confirmed} <- user |> User.confirm_changeset() |> Repo.update(),
                 :ok <- maybe_attach_provider_identity(confirmed, data) do
              Repo.delete!(token)
              {:ok, confirmed}
            end
          end)
      end
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Consume a provider-link invitation: attach the pending provider
  to the existing user. Returns `{:ok, user}` or `{:error, :invalid}`.
  """
  def consume_provider_link_invitation(encoded_token) when is_binary(encoded_token) do
    with {:ok, query} <-
           UserToken.verify_invitation_token(encoded_token, "provider_link_invitation"),
         %UserToken{user_id: user_id, data: data} = token <- Repo.one(query),
         %User{} = user <- Repo.get(User, user_id) do
      Repo.transact(fn ->
        with :ok <- maybe_attach_provider_identity(user, data) do
          Repo.delete!(token)
          {:ok, user}
        end
      end)
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Dismiss any invitation token: deletes it and blacklists the email
  for 30 days. Returns `:ok` regardless (never leaks whether the
  token was valid).
  """
  def dismiss_invitation(encoded_token) when is_binary(encoded_token) do
    token_row =
      Enum.find_value(["signup_invitation", "provider_link_invitation"], fn ctx ->
        case UserToken.verify_invitation_token(encoded_token, ctx) do
          {:ok, query} -> Repo.one(query)
          :error -> nil
        end
      end)

    case token_row do
      nil ->
        :ok

      %UserToken{sent_to: email} = token ->
        Repo.delete!(token)
        {:ok, _} = Blacklist.add(email, "wasnt_me")
        :ok
    end
  end

  defp maybe_attach_provider_identity(_user, nil), do: :ok
  defp maybe_attach_provider_identity(_user, data) when map_size(data) == 0, do: :ok

  defp maybe_attach_provider_identity(%User{} = user, %{} = data) do
    attrs = %{
      provider: data["provider"] || data[:provider],
      provider_uid: data["uid"] || data[:uid]
    }

    case attach_identity(user, attrs) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp valid_email_format?(email) when is_binary(email) do
    String.match?(email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)
  end

  @doc "Revokes a single session token."
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Helpers

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
