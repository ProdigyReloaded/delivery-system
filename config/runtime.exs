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

if System.get_env("RELEASE_MODE") do
  config :core, Prodigy.Core.Data.Repo,
    database: System.fetch_env!("DB_NAME"),
    username: System.fetch_env!("DB_USER"),
    password: System.fetch_env!("DB_PASS"),
    hostname: System.fetch_env!("DB_HOST"),
    show_sensitive_data_on_connection_error: true

  # URL_SCHEME / URL_PORT default to the prod values (https/443 behind a
  # CF Tunnel that terminates TLS). Method-c dev sets them to http/80 in
  # docker-compose.override.yaml so signup/OAuth-callback emails generated
  # off-conn (mailers, scheduled tasks) match the dev Caddy listener.
  config :portal, Prodigy.Portal.Endpoint,
    url: [
      host: System.fetch_env!("PHX_HOST"),
      port: String.to_integer(System.get_env("URL_PORT") || "443"),
      scheme: System.get_env("URL_SCHEME") || "https"
    ],
    http: [
      ip: {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PHX_PORT") || "4000"),
      # Default idle_timeout is 60 s - too tight for /api/v1/objects/upload
      # when a 100k+ row insert holds the socket quiet while the DB
      # transaction runs. 15 min matches the transaction cap in the
      # upload controller with headroom to spare.
      protocol_options: [idle_timeout: 15 * 60_000]
    ],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true

  # Dev-only routes in a prod release - enable Swoosh mailbox preview, etc.
  # Set PHX_DEV_ROUTES=true in local compose; leave unset for real prod.
  config :portal, dev_routes: System.get_env("PHX_DEV_ROUTES") == "true"

  # Ueberauth provider credentials - loaded from env so each provider can be
  # toggled on/off independently. A nil client_id/secret means that provider's
  # button is hidden on the login page (see portal.available_oauth_providers/0).
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")

  # Mail backend. Default (unset MAIL_BACKEND) leaves the
  # compile-time default adapter alone - `Swoosh.Adapters.Local` in
  # config/config.exs, which dumps messages into the /dev/mailbox
  # preview page.
  #
  # MAIL_BACKEND=smtp is the deployed mechanism: provider-neutral, so
  # pointing at one SMTP endpoint today and another provider's tomorrow
  # is an env change, not code. MAIL_BACKEND=aws (SES HTTP API) remains
  # as an alternative.
  case System.get_env("MAIL_BACKEND") do
    "smtp" ->
      smtp_host = System.fetch_env!("MAIL_SMTP_HOST")

      config :portal, Prodigy.Portal.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(System.get_env("MAIL_SMTP_PORT", "587")),
        username: System.fetch_env!("MAIL_USERNAME"),
        password: System.fetch_env!("MAIL_PASSWORD"),
        tls: :always,
        auth: :always,
        # gen_smtp hands these straight to :ssl. Modern OTP aborts the
        # STARTTLS handshake without explicit CA verification options
        # (symptom: {:temporary_failure, _, :tls_failed} on every send).
        tls_options: [
          versions: [:"tlsv1.2", :"tlsv1.3"],
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(smtp_host),
          depth: 3
        ]

      # Name shown to recipients + sender address (must be under the
      # provider's verified identity).
      config :portal, :mail_from, {"Prodigy Reloaded", System.fetch_env!("MAIL_FROM")}

    "aws" ->
      # The API adapter needs an HTTP client; config.exs disables it
      # globally for the Local/Test adapters, so re-enable here.
      config :swoosh, api_client: Swoosh.ApiClient.Req

      config :portal, Prodigy.Portal.Mailer,
        adapter: Swoosh.Adapters.AmazonSES,
        region: System.fetch_env!("MAIL_REGION"),
        access_key: System.fetch_env!("MAIL_KEY"),
        secret: System.fetch_env!("MAIL_PRIVATE_KEY")

      config :portal, :mail_from, {"Prodigy Reloaded", System.fetch_env!("MAIL_FROM")}

    _ ->
      :ok
  end
end
