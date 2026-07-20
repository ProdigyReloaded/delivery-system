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

config :portal, :scopes,
  user: [
    default: true,
    module: Portal.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :portal_users,
    test_data_fixture: Portal.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :server,
  ecto_repos: [Prodigy.Core.Data.Repo],
  auth_timeout: 60 * 1000

config :server, Prodigy.Server.Scheduler,
  jobs: [
    expunge_job: [
      schedule: "@daily",
      task: {Prodigy.Server.Service.Messaging, :expunge, []}
    ],
    member_list_job: [
      schedule: "@daily",
      task: {Prodigy.Server.MemberList.Generator, :run, []}
    ]
  ]

config :core, ecto_repos: [Prodigy.Core.Data.Repo], ecto_adapter: Ecto.Adapters.Postgres

config :portal,
  ecto_repos: [Prodigy.Core.Data.Repo],
  generators: [context_app: :portal]

config :portal, Prodigy.Portal.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: Prodigy.Portal.ErrorHTML, json: Prodigy.Portal.ErrorJSON],
    layout: false
  ],
  pubsub_server: Prodigy.Portal.PubSub,
  live_view: [signing_salt: "HzVnKFx7"]

config :phoenix, :json_library, Jason

# Ueberauth: list providers here; credentials are set in runtime.exs from env.
# Providers whose env credentials are missing are silently unavailable - the
# login page hides their buttons, and direct hits to /auth/google etc. just
# show an error flash.
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]},
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

# Swoosh default: prod overrides in runtime.exs; dev uses Local adapter (see dev.exs).
config :portal, Prodigy.Portal.Mailer, adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, false

config :logger, :console, format: "$time $metadata[$level] $message\n"
config :logger, level: :info

import_config "#{Mix.env()}.exs"
