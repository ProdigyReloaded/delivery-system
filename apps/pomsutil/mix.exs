defmodule Prodigy.OmsUtil.MixProject do
  use Mix.Project

  def project do
    [
      app: :pomsutil,
      escript: [main_module: Prodigy.OmsUtil.CLI],
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:core, in_umbrella: true},
      {:exprintf, "~> 0.2.0"},
      {:pbkdf2_elixir, "~> 1.0"},
    ]
  end
end
