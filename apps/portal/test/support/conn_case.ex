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

defmodule Prodigy.Portal.ConnCase do
  @moduledoc """
  Foundation for tests that need a `%Plug.Conn{}` to exercise controllers
  and LiveViews. Sets up the same sandbox as `Prodigy.Portal.DataCase`, plus
  `log_in_user/2` and `register_and_log_in_user/1` helpers phx.gen.auth
  tests expect.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      # Endpoint for Phoenix.ConnTest
      @endpoint Prodigy.Portal.Endpoint

      use Prodigy.Portal, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Prodigy.Portal.ConnCase
      import Prodigy.Portal.AccountsFixtures
    end
  end

  setup tags do
    Prodigy.Portal.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates a fresh user, confirms them, and returns a conn with their
  session token set - matching the setup the phx.gen.auth-generated tests
  rely on via `setup :register_and_log_in_user`.
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = Prodigy.Portal.AccountsFixtures.user_fixture()
    scope = Prodigy.Portal.Accounts.Scope.for_user(user)
    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  @doc """
  Puts a valid session token for `user` into the given conn. Optional
  `token_authenticated_at:` opt rewrites the token row's authenticated_at
  timestamp so tests can exercise sudo-mode expiry.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Prodigy.Portal.Accounts.generate_user_session_token(user)

    if ts = Keyword.get(opts, :token_authenticated_at) do
      Prodigy.Portal.AccountsFixtures.override_token_authenticated_at(token, ts)
    end

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
