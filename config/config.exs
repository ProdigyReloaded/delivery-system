# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

config :server, ecto_repos: [Prodigy.Core.Data.Repo]

config :server, Prodigy.Server.Scheduler,
  jobs: [
    expunge_job: [
      schedule: "@daily",
      task: {Prodigy.Server.Service.Messaging, :expunge, []}
    ]
  ]

config :core, ecto_repos: [Prodigy.Core.Data.Repo], ecto_adapter: Ecto.Adapters.Postgres

config :logger, :console, format: "$time $metadata[$level] $message\n"
config :logger, level: :info

import_config "#{Mix.env()}.exs"
