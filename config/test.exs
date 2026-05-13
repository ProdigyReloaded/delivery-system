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

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

config :core, Prodigy.Core.Data.Repo,
  database: System.get_env("DB_NAME", "prodigytest"),
  username: System.get_env("DB_USER", "prodigytest"),
  password: System.get_env("DB_PASS", "prodigytest"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox

config :server,
  auth_timeout: 3000,
  # OS-assigned ephemeral port so the test listener doesn't collide with
  # a locally-running compose server (which holds 25234).
  tcs_port: 0

config :portal, Prodigy.Portal.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_not_used_in_production_LH0YXxKfjfZxxxxxxxxxxxxxx",
  server: false

# Use the no-IO Test adapter for tests - different from the compile-time
# default (`Swoosh.Adapters.Local`). Tests assert against the email-link
# / password-form UI which is gated on `mail_disabled?` returning false;
# the gate triggers when adapter == Swoosh.Adapters.Local, so the Test
# adapter unblocks those assertions while keeping mail a no-op in tests.
config :portal, Prodigy.Portal.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

config :logger, level: :none
