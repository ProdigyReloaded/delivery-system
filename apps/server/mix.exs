defmodule Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Prodigy.Server.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ranch, "~> 2.1.0"},
      {:crc, "~> 0.10.4"},
      {:enum_type, "~> 1.1.0"},
      {:calendar, "~> 1.0.0"},
      {:timex, "~> 3.0"},
      {:pbkdf2_elixir, "~> 1.0"},
      {:yahoo_finance_elixir, "~> 0.1.3"},
      {:number, "~> 1.0.3"},
      {:quantum, "~> 3.0"},
      {:core, in_umbrella: true},
      {:mock, "~> 0.3.0", only: :test}
    ]
  end
end
