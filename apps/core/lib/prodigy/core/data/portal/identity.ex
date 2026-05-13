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

defmodule Prodigy.Core.Data.Portal.Identity do
  @moduledoc """
  One auth method attached to a portal user. A user may have multiple:
  one `:identity` (email + password) plus any number of OAuth identities
  (Google, GitHub, dev-mock). The `User` row is the profile; these rows
  are the keys.

  `hashed_password` is set only when `provider` is `:identity`. OAuth rows
  set `provider_uid` to the provider-side identifier instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @providers [:identity, :google, :github, :mock]

  schema "portal_identities" do
    belongs_to :user, Prodigy.Core.Data.Portal.User

    field :provider, Ecto.Enum, values: @providers
    field :provider_uid, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true

    timestamps()
  end

  def providers, do: @providers

  @doc """
  Builds an :identity (email + password) identity for a user. Accepts a
  plain `password` attr; hashes it unless `hash_password: false` is given.
  """
  def password_changeset(identity, attrs, opts \\ []) do
    identity
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> put_change(:provider, :identity)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Builds a social-login identity (Google, GitHub, Mock). No password.
  """
  def oauth_changeset(identity, attrs) do
    identity
    |> cast(attrs, [:provider, :provider_uid])
    |> validate_required([:provider, :provider_uid])
    |> unique_constraint([:provider, :provider_uid],
      name: :portal_identities_provider_provider_uid_index
    )
  end

  @doc """
  Verifies a plain-text password against an :identity identity's hashed value.
  If the identity has no hashed_password or doesn't exist, still performs a
  dummy hash via `Pbkdf2.no_user_verify/0` to keep timing uniform.
  """
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end
end
