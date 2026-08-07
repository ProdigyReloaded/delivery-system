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

defmodule Prodigy.Portal.Provisioning do
  @moduledoc """
  Idempotent bootstrap for non-interactive portal identities (automation /
  service accounts) and their API keys - e.g. the `content-batch` uploader that
  POSTs generated objects to `/api/v1/objects/upload`.

  Same effect from two runtimes:

    * dev / CI / an ops box with the source:
        `mix prodigy.portal.api_key EMAIL --name NAME --scope SCOPE`
    * prod (a release has no Mix) - against the running node:
        `bin/server rpc 'Prodigy.Portal.Provisioning.ensure_api_key(%{
           email: "content-batch@...", name: "content-batch",
           scopes: ["objects.upload"]}) |> IO.inspect()'`

  The scope grant is a direct `UserScope` insert rather than
  `Authz.grant_scope/3`: this is an operator-run bootstrap primitive (DB-level
  trust), so there is no acting user to authorize against - the classic
  first-admin bootstrap. `ApiKeys.create/2` still enforces that the key's scopes
  are a subset of what the owner now holds, so the grant must precede the mint.
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Portal.{ApiKey, UserScope}
  alias Prodigy.Portal.{Accounts, ApiKeys, Authz}

  @doc """
  Ensures a portal account for `email`, grants it `scopes`, and mints an API key
  named `name` scoped to `scopes`.

  Idempotent where it can be: the account and scope grants are get-or-create /
  upsert. The key itself is only minted when no live (non-revoked) key of that
  `name` exists - because the plaintext is show-once and cannot be reproduced.
  Pass `force: true` to mint an additional key regardless.

  Returns:
    * `{:minted, plaintext}` - a new key was created; store the plaintext now
    * `{:exists, %ApiKey{}}` - a live key of that name already exists; untouched
    * `{:error, term}`       - unknown scope, or a create/changeset error
  """
  @spec ensure_api_key(map()) ::
          {:minted, String.t()} | {:exists, ApiKey.t()} | {:error, term()}
  def ensure_api_key(%{email: email, name: name, scopes: scopes} = attrs)
      when is_binary(email) and is_binary(name) and is_list(scopes) do
    force = Map.get(attrs, :force, false)

    with :ok <- validate_scopes(scopes),
         {:ok, user} <- get_or_create_user(email) do
      Enum.each(scopes, &grant_scope(user.id, &1))

      case {existing_live_key(user.id, name), force} do
        {%ApiKey{} = key, false} ->
          {:exists, key}

        _ ->
          case ApiKeys.create(user.id, %{name: name, scopes: scopes}) do
            {:ok, key} -> {:minted, key.plaintext}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp validate_scopes(scopes) do
    case scopes -- Authz.all_scopes() do
      [] -> :ok
      unknown -> {:error, {:unknown_scopes, unknown}}
    end
  end

  defp get_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      nil -> Accounts.register_user(%{email: email})
      user -> {:ok, user}
    end
  end

  defp grant_scope(user_id, scope) do
    %{user_id: user_id, scope: scope}
    |> UserScope.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :scope])
  end

  defp existing_live_key(user_id, name) do
    Repo.one(
      from(k in ApiKey,
        where: k.user_id == ^user_id and k.name == ^name and is_nil(k.revoked_at),
        limit: 1
      )
    )
  end
end
