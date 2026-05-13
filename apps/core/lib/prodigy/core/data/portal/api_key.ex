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

defmodule Prodigy.Core.Data.Portal.ApiKey do
  @moduledoc """
  Long-lived bearer token that authenticates a portal user on the
  `/api/v1` HTTP endpoint. Plaintext is shown to the user exactly once
  at creation; the DB stores only a SHA-256 hash plus a short
  display prefix.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "portal_api_keys" do
    field :name, :string
    field :key_prefix, :string
    field :key_hash, :binary
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    # Subset of the owner's scopes that this key is allowed to use.
    # Effective capability on each API request is the intersection of
    # this list and the owner's current effective scopes, so revoking
    # a scope from the owner instantly degrades every key they own.
    # Never includes any string from # Prodigy.Portal.Authz.forbidden_for_api_keys/0
    # - the changeset refuses those at mint time.
    field :scopes, {:array, :string}, default: []

    belongs_to :user, Prodigy.Core.Data.Portal.User

    # Virtual - populated only by the `create` changeset so the LiveView /
    # controller can show the plaintext key to the user exactly once.
    # Never persisted; never returned by subsequent reads.
    field :plaintext, :string, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for a fresh API key. The caller passes `:name` (and
  optionally `:scopes`) in attrs; this function generates the
  plaintext, computes the hash + prefix, and stashes the plaintext
  in the virtual field.

  Scope *policy* (catalog membership, forbidden-for-keys, owner
  holds it) is enforced one level up in `Prodigy.Portal.ApiKeys.create/2`
  because it needs `Prodigy.Portal.Authz`, which lives in the portal
  app - the core schema deliberately stays portal-agnostic.
  """
  def create_changeset(attrs) do
    {plaintext, prefix, hash} = generate()

    %__MODULE__{}
    |> cast(attrs, [:user_id, :name, :scopes])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, min: 1, max: 80)
    |> put_change(:plaintext, plaintext)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> assoc_constraint(:user)
  end

  @doc """
  Marks a key as revoked. Idempotent - calling on an already-revoked
  row is a no-op (the caller gets back a changeset with no changes).
  """
  def revoke_changeset(%__MODULE__{} = key) do
    if key.revoked_at do
      change(key)
    else
      change(key, revoked_at: DateTime.utc_now())
    end
  end

  @doc """
  Generates a fresh key tuple: `{plaintext, prefix, hash}`.

  * `plaintext`: the string the user sees - `"pk_" <> 26-char base32`.
    26 chars of RFC 4648 base32 (no padding) encode 130 bits; we feed
    16 random bytes (128 bits) so the last character carries 2 bits
    of true entropy and 3 bits that are always a fixed tail. That's
    fine - still 128 bits of keyspace to brute-force.
  * `prefix`: first 8 characters of the plaintext (covers `"pk_"` plus
    5 random chars), used for display and lookup narrowing.
  * `hash`: SHA-256 of the plaintext bytes. The whole string is
    hashed, including the `pk_` prefix, so a different future prefix
    doesn't collide with today's hashes.
  """
  def generate do
    random = :crypto.strong_rand_bytes(16)
    plaintext = "pk_" <> Base.encode32(random, case: :lower, padding: false)
    prefix = String.slice(plaintext, 0, 8)
    hash = :crypto.hash(:sha256, plaintext)
    {plaintext, prefix, hash}
  end

  @doc "SHA-256 of the supplied plaintext - used by the verify path."
  def hash_plaintext(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext)
  end
end
