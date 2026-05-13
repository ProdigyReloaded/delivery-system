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

defmodule Prodigy.Portal.Plugs.DevOnly do
  @moduledoc """
  Halts a request with 404 unless `:portal, :dev_routes` is `true` at
  runtime. Used on the `/dev/*` router scopes so the mock-OAuth
  controller and Swoosh mailbox preview are inert in production even
  though the routes are still compiled in (the same prod release
  image powers both dev docker compose and real prod, distinguished
  only by the `PHX_DEV_ROUTES` env var).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:portal, :dev_routes) == true do
      conn
    else
      conn
      |> send_resp(404, "")
      |> halt()
    end
  end
end
