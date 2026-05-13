# Copyright 2022, Phillip Heller
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

import Config

# Repo defaults match method a (everything-local: a 'prodigydev' role and
# database on the dev's homebrew/local postgres on :5432). Method b
# (host-side mix against the dockered postgres on :5433) overrides via
# env vars - typically:
#   DB_NAME=prodigy DB_USER=prodigy DB_PASS=prodigy DB_PORT=5433 mix phx.server
config :core, Prodigy.Core.Data.Repo,
  database: System.get_env("DB_NAME") || "prodigydev",
  username: System.get_env("DB_USER") || "prodigydev",
  password: System.get_env("DB_PASS") || "prodigydev",
  hostname: System.get_env("DB_HOST") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432")

config :portal, Prodigy.Portal.Endpoint,
  # Host-side mix serves directly on :4000 (no Caddy in front). URL
  # generation - signup emails, OAuth callbacks - has to render that
  # port and the http scheme so the links are reachable from a browser.
  url: [host: "localhost", port: 4000, scheme: "http"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "LH0YXxKfjfZ/dUnQUQSvzp96Y9Vr7SDCvOYYk6j/fxiSAS0x8Lb+Qlks0eACiv1V",
  watchers: []


# Always enable /dev/mailbox + /dev/mock-auth when running mix from host.
# Method c sets the same flag via PHX_DEV_ROUTES env in runtime.exs.
config :portal, dev_routes: true

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
