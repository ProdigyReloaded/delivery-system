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

defmodule Prodigy.Portal.ApiKeys do
  @moduledoc """
  CRUD + verification for portal user API keys. Keys are long-lived
  bearer tokens used by `podbutil` and other CLI / CI clients to
  authenticate against the `/api/v1` HTTP surface.

  Plaintext keys are generated in-memory, returned to the caller
  once, and never persisted - the DB stores only a SHA-256 hash plus
  an 8-char display prefix. Lookup uses the prefix as a narrowing
  index, then does a byte-for-byte hash compare.
  """
  import Ecto.Query

  alias Prodigy.Core.Data.Portal.ApiKey
  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Authz

  @doc """
  Creates a new API key owned by `user_id` with the given display
  name. Returns `{:ok, key}` where `key.plaintext` is the
  show-once value the caller must surface to the user; all subsequent
  reads of the record will have `plaintext: nil`.

  `:scopes` in attrs is validated against three policies:
  - every entry must be in `Authz.all_scopes/0`
  - none may be in `Authz.forbidden_for_api_keys/0`
  - every entry must currently be held by `user_id` (no escalation)
  """
  @spec create(integer(), map()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def create(user_id, attrs) when is_integer(user_id) do
    # Normalize to string keys so callers can pass either atom-keyed
    # maps (context-level) or string-keyed ones (LiveView form params)
    # without triggering Ecto's mixed-keys cast error.
    normalized =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("user_id", user_id)

    # Callers that don't mention scopes at all get the "inherit every
    # non-forbidden scope the owner currently holds" default. That
    # matches the migration backfill for existing keys and preserves
    # the pre-5c behavior for API-call sites that haven't been updated
    # yet. Explicitly passing an empty list is honored - the mint UI
    # uses that to create a key with no capability beyond ping.
    attrs_with_scopes =
      case Map.fetch(normalized, "scopes") do
        {:ok, _} -> normalized
        :error -> Map.put(normalized, "scopes", default_scopes_for(user_id))
      end

    attrs_with_scopes
    |> ApiKey.create_changeset()
    |> validate_scopes_policy(user_id)
    |> Repo.insert()
  end

  defp default_scopes_for(user_id) do
    forbidden = MapSet.new(Authz.forbidden_for_api_keys())

    user_id
    |> Authz.effective_scopes()
    |> MapSet.difference(forbidden)
    |> MapSet.to_list()
  end

  defp validate_scopes_policy(changeset, user_id) do
    requested = Ecto.Changeset.get_field(changeset, :scopes) || []
    catalog = MapSet.new(Authz.all_scopes())
    forbidden = MapSet.new(Authz.forbidden_for_api_keys())
    owner_scopes = Authz.effective_scopes(user_id)

    Enum.reduce(requested, changeset, fn scope, cs ->
      cond do
        not MapSet.member?(catalog, scope) ->
          Ecto.Changeset.add_error(cs, :scopes, "unknown scope #{inspect(scope)}")

        MapSet.member?(forbidden, scope) ->
          Ecto.Changeset.add_error(
            cs,
            :scopes,
            "scope #{inspect(scope)} cannot attach to an API key"
          )

        not MapSet.member?(owner_scopes, scope) ->
          Ecto.Changeset.add_error(
            cs,
            :scopes,
            "scope #{inspect(scope)} is not held by the owner"
          )

        true ->
          cs
      end
    end)
  end

  @doc """
  Lists all keys (active + revoked) for a user, newest first.
  `plaintext` is always nil on reads.
  """
  @spec list_for_user(integer()) :: [ApiKey.t()]
  def list_for_user(user_id) when is_integer(user_id) do
    from(k in ApiKey,
      where: k.user_id == ^user_id,
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Revokes a single key owned by `user_id`. Returns `{:ok, key}`,
  `:not_found` if no such key exists (or it belongs to a different
  user), or `{:error, changeset}` on DB failure.
  """
  @spec revoke(integer(), integer()) ::
          {:ok, ApiKey.t()} | :not_found | {:error, Ecto.Changeset.t()}
  def revoke(user_id, id) when is_integer(user_id) and is_integer(id) do
    case Repo.get_by(ApiKey, id: id, user_id: user_id) do
      nil ->
        :not_found

      %ApiKey{} = key ->
        key
        |> ApiKey.revoke_changeset()
        |> Repo.update()
    end
  end

  @doc """
  Verifies a submitted plaintext key. Returns `{:ok, user, key_id,
  effective_scopes}` on a live, unrevoked match - `effective_scopes`
  is a `MapSet` of strings (intersection of the key's scopes and the
  owner's current scopes). `:invalid` covers every failure case
  (unknown key, revoked, bad format) - intentionally opaque so the
  caller doesn't leak which part failed.

  The prefix is extracted from the plaintext and used to narrow the
  candidate set; then SHA-256 of the plaintext is compared
  byte-for-byte against each candidate's `key_hash` using
  `Plug.Crypto.secure_compare/2`. Collisions on the 8-char prefix
  are rare but handled - the compare loop sees every matching row.
  """
  @spec verify(String.t()) ::
          {:ok, User.t(), integer(), MapSet.t(String.t())} | :invalid
  def verify(plaintext) when is_binary(plaintext) do
    with {:ok, prefix} <- extract_prefix(plaintext),
         hash = ApiKey.hash_plaintext(plaintext),
         candidates when candidates != [] <- candidates_by_prefix(prefix),
         %ApiKey{user: user, id: id, scopes: key_scopes} = _match <-
           find_match(candidates, hash) do
      effective = effective_scopes_for(user, key_scopes)
      {:ok, user, id, effective}
    else
      _ -> :invalid
    end
  end

  def verify(_), do: :invalid

  @doc """
  Returns the intersection of `key_scopes` and the owner's current
  effective scopes. Exposed so callers (e.g. the settings UI) can
  surface a key's live capability without re-verifying.
  """
  @spec effective_scopes_for(User.t(), [String.t()]) :: MapSet.t(String.t())
  def effective_scopes_for(%User{} = user, key_scopes) when is_list(key_scopes) do
    MapSet.intersection(MapSet.new(key_scopes), Authz.effective_scopes(user))
  end

  @doc """
  Synchronous last-used-at update. Returns the number of rows
  touched (0 or 1). Callers on the hot auth path should prefer
  `touch_async/1`.
  """
  @spec touch(integer()) :: non_neg_integer()
  def touch(id) when is_integer(id) do
    {count, _} =
      from(k in ApiKey, where: k.id == ^id)
      |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])

    count
  end

  @doc """
  Fire-and-forget wrapper around `touch/1` - runs in an unlinked
  Task so the request path doesn't wait. A dropped write is
  harmless; `last_used_at` drives the settings UI, not auth.
  """
  @spec touch_async(integer()) :: :ok
  def touch_async(id) when is_integer(id) do
    Task.Supervisor.start_child(Prodigy.Portal.TaskSupervisor, fn ->
      touch(id)
    end)

    :ok
  end

  # --- helpers -------------------------------------------------------

  defp extract_prefix(plaintext) when byte_size(plaintext) >= 8 do
    {:ok, String.slice(plaintext, 0, 8)}
  end

  defp extract_prefix(_), do: :error

  defp candidates_by_prefix(prefix) do
    from(k in ApiKey,
      where: k.key_prefix == ^prefix and is_nil(k.revoked_at),
      preload: [:user]
    )
    |> Repo.all()
  end

  defp find_match(candidates, submitted_hash) do
    Enum.find(candidates, fn %ApiKey{key_hash: stored} ->
      Plug.Crypto.secure_compare(stored, submitted_hash)
    end)
  end
end
