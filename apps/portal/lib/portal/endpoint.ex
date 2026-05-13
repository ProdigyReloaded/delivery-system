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

defmodule Prodigy.Portal.Endpoint do
  use Phoenix.Endpoint, otp_app: :portal

  @session_options [
    store: :cookie,
    key: "_portal_key",
    signing_salt: "yK0Qdb7X",
    same_site: "Lax"
  ]

  # `log: false` silences the per-connect "CONNECTED TO Phoenix.LiveView.Socket"
  # info line; the preceding `GET /admin/...` request log already records the
  # mount and the socket connect adds no operationally useful signal.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]],
    log: false

  # Honor X-Forwarded-* from the trusted proxy chain (Cloudflare Tunnel ->
  # Caddy -> here). Without this, conn.scheme is :http (the in-cluster hop
  # is plain) and URL helpers / Ueberauth callback URLs come out as http://,
  # which GitHub rejects against an https-registered OAuth app.
  # `x_forwarded_for` rewrites conn.remote_ip from the header - Caddy is
  # configured to set X-Forwarded-For to Cloudflare's CF-Connecting-IP, so
  # remote_ip ends up holding the real originating client address rather
  # than the docker-bridge IP.
  # Safe because port 4000 is not published to the host: only Caddy reaches
  # this endpoint, and Caddy controls the X-Forwarded-* headers.
  plug Plug.RewriteOn, [
    :x_forwarded_host,
    :x_forwarded_port,
    :x_forwarded_proto,
    :x_forwarded_for
  ]

  # Security headers first so they apply to BOTH static-asset responses
  # (especially the WASM/data files that need COOP/COEP for SharedArrayBuffer)
  # and dynamic Phoenix responses.
  plug Prodigy.Portal.Plugs.SecurityHeaders

  # Serve static assets from priv/static/ at the site root.
  # The `only` list bounds what Plug.Static will inspect - requests to paths
  # outside these top-level names fall through to the Router.
  plug Plug.Static,
    at: "/",
    from: :portal,
    gzip: false,
    only: ~w(css images start favicon.ico robots.txt)

  # LiveView / Phoenix client JS served straight from the hex deps' priv/static
  # dirs. Avoids standing up an esbuild pipeline; good enough until we want
  # custom hooks or bundled CSS.
  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}, gzip: false
  plug Plug.Static, at: "/assets/phoenix_html", from: {:phoenix_html, "priv/static"}, gzip: false
  plug Plug.Static, at: "/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}, gzip: false

  if code_reloading? do
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug Prodigy.Portal.Router
end
