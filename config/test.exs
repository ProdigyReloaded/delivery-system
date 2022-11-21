import Config

config :core, Prodigy.Core.Data.Repo,
  database: "prodigytest",
  username: "prodigytest",
  password: "prodigytest",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

config :server,
  auth_timeout: 1000

config :logger, level: :error
