defmodule DeliverySystem.MixProject do
  use Mix.Project

  def project do
    [
      name: "Delivery System",
      apps: [:core, :podbutil, :pomsutil, :server],
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      releases: [
        server: [
          applications: [
            core: :permanent,
            server: :permanent
          ]
        ]
      ],
      docs: [
        api_reference: false,
        extras: ["README.md"],
        main: "README",
        nest_modules_by_prefix: [
          Prodigy.Core,
          Prodigy.Core.Data,
          Prodigy.Server,
          Prodigy.Server.Protocol,
          Prodigy.Server.Service
        ]
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.10", only: :test},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false}
    ]
  end
end
