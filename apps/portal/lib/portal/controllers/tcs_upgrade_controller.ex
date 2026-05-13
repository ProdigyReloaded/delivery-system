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

defmodule Prodigy.Portal.TcsUpgradeController do
  @moduledoc """
  Upgrades an incoming HTTP request to a raw WebSocket terminated by
  `Prodigy.Server.TcsWebSocket`. Lives in the portal app so the Phoenix
  router surfaces the route, but the handler (and all TCS protocol code)
  sits in the server app.

  The path is deliberately non-specific for now (`/tcs`) - when service
  eras and environments get dropdown selection on /start, this controller
  will read those from the conn (path params or query) and pass them to
  the handler's init to select which TCS service instance to bind.
  """
  use Prodigy.Portal, :controller

  def upgrade(conn, _params) do
    peer = Plug.Conn.get_peer_data(conn)

    peer_info = %{
      address: format_remote_ip(conn.remote_ip) || format_remote_ip(peer[:address]),
      port: peer[:port]
    }

    # 120s idle timeout - if no frame arrives in that window Cowboy closes
    # the socket, which cascades through TCS -> DIA -> Router and fires
    # Logoff.handle_abnormal so the admin table updates. Server-side pings
    # (see TcsWebSocket) run every 30s to keep legitimately-idle clients
    # alive and surface dead ones within the window.
    conn
    |> WebSockAdapter.upgrade(
      Prodigy.Server.TcsWebSocket,
      [peer_info: peer_info],
      timeout: 120_000
    )
    |> halt()
  end

  defp format_remote_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_remote_ip(_), do: nil
end
