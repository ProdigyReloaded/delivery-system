defmodule Server.MixProject do
  use Mix.Project

  def project do
    [
      app: :server,
      name: "Server",
      #      docs: [
      #        api_reference: false,
      #        extras: ["README.md"],
      #        main: "README",
      #        nest_modules_by_prefix: [
      #          Prodigy.Server,
      #          Prodigy.Server.Protocol,
      #          Prodigy.Server.Service,
      #        ]
      #      ],
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
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
      # Explicit HTTP + JSON deps for the in-repo DowJones.Api client
      # module (the previous quote-fetch dep had been pulling both
      # transitively).
      {:httpoison, "~> 1.0"},
      {:poison, "~> 5.0"},
      {:number, "~> 1.0.3"},
      {:quantum, "~> 3.0"},
      {:core, in_umbrella: true},
      # WebSock behavior - implemented by TcsWebSocket so portal's
      # websock_adapter can upgrade browser sockets onto TCS.
      {:websock, "~> 0.5"},
      {:mock, "~> 0.3.0", only: :test},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:req, "~> 0.5.17"}
    ]
  end
end
