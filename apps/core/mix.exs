defmodule Prodigy.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Prodigy.Core.Application, []},
      # phoenix_pubsub must start before our supervisor tries to boot the
      # shared Prodigy.Core.PubSub process.
      extra_applications: [:logger, :phoenix_pubsub]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.0"},
      {:postgrex, "~> 0.17.1"},
      {:pbkdf2_elixir, "~> 1.4"},
      # Shared Prodigy.Core.PubSub for cross-app runtime events
      # (e.g. SessionManager broadcasts logon/logoff to admin LVs).
      {:phoenix_pubsub, "~> 2.1"},
      # Needed so Postgrex can encode the :map / jsonb profile columns
      # on Service.User + Service.Household. Without it, any insert
      # that touches :profile blows up with Jason.encode_to_iodata!/1
      # undefined - visible in pomsutil / podbutil escripts since they
      # don't otherwise depend on Jason.
      {:jason, "~> 1.4"}
    ]
  end
end
