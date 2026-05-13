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

defmodule Prodigy.Portal.Accounts.Scope do
  @moduledoc """
  Caller identity + capability snapshot, threaded through the portal
  as `current_scope`. Carries the `%User{}` and a `MapSet` of the
  user's effective scope strings so that `Prodigy.Portal.Authz.can?/3`
  checks are a constant-time lookup in memory rather than a DB query
  per render.

  `for_user/1` loads the scope set up-front; callers that need a
  refresh (after a grant/revoke broadcast, say) can call
  `refresh_scopes/1`.
  """

  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Portal.Authz

  defstruct user: nil, scopes: MapSet.new()

  @doc """
  Creates a scope for the given user, preloading their effective
  scopes. Returns nil for a nil user.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user, scopes: Authz.effective_scopes(user)}
  end

  def for_user(nil), do: nil

  @doc """
  Re-queries and replaces the scope set on an existing scope. Used by
  LiveView handlers that want to see a grant/revoke take effect
  without a full re-login.
  """
  def refresh_scopes(%__MODULE__{user: nil} = scope), do: scope

  def refresh_scopes(%__MODULE__{user: %User{} = user} = scope) do
    %{scope | scopes: Authz.effective_scopes(user)}
  end
end
