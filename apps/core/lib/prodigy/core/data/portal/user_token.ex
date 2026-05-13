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

defmodule Prodigy.Core.Data.Portal.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Prodigy.Core.Data.Portal.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14
  # Invitation tokens (signup / provider-link) share the magic-link
  # expiry - the address owner should act quickly or the token rots.
  @invitation_validity_in_minutes 15

  schema "portal_users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :naive_datetime
    # Invitation-specific payload (e.g. provider + uid for a
    # provider-link invitation). nil for plain magic-link / session /
    # change-email tokens.
    field :data, :map
    # user_id is nullable - signup-invitation tokens don't have a
    # user row yet; the user is created only when the recipient
    # clicks the confirm link.
    belongs_to :user, Prodigy.Core.Data.Portal.User

    timestamps(updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || NaiveDateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  # --- invitation tokens (unified auth flow) -----------------------

  @doc """
  Build a `:signup_invitation` token. Carries an email address but
  no user row - the portal_user is created on confirm-click. The
  optional `data` map can hold a provider identity (from an OAuth
  callback with an email the system hasn't seen) so the link-click
  can attach that identity atomically with user creation.

  Returns `{encoded_token, %UserToken{}}`. The caller inserts the
  struct and mails the encoded token in a confirm URL.
  """
  def build_signup_invitation_token(email, data \\ nil) when is_binary(email) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: "signup_invitation",
       sent_to: email,
       user_id: nil,
       data: data
     }}
  end

  @doc """
  Build a `:provider_link_invitation` token tying a provider
  identity to an existing user. The confirm click links the
  provider; the dismiss click deletes the token and blacklists
  the email.
  """
  def build_provider_link_invitation_token(user, provider, provider_uid)
      when is_binary(provider_uid) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: "provider_link_invitation",
       sent_to: user.email,
       user_id: user.id,
       data: %{"provider" => to_string(provider), "uid" => provider_uid}
     }}
  end

  @doc """
  Look up a signup-invitation token by its URL-encoded value.
  Returns `{:ok, %UserToken{}}` or `:error`.
  """
  def verify_invitation_token(token, context)
      when context in ["signup_invitation", "provider_link_invitation"] do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(@hash_algorithm, decoded)

        query =
          from t in by_token_and_context_query(hashed, context),
            where: t.inserted_at > ago(^@invitation_validity_in_minutes, "minute"),
            select: t

        {:ok, query}

      :error ->
        :error
    end
  end
end
