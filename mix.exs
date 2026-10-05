defmodule SimpleFit.MixProject do
  use Mix.Project

  def project do
    [
      app: :simple_fit,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SimpleFit.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Every dependency must be justified. See docs/architecture/README.md
  # ("Dependencies") and the deferred list in docs/architecture/adr/0004.
  defp deps do
    [
      # Web
      {:phoenix, "~> 1.8.15"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},

      # Persistence
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:phoenix_ecto, "~> 4.7"},

      # API contract (OpenAPI 3, code-first). See docs/architecture/adr/0002.
      {:open_api_spex, "~> 3.22"},

      # Observability
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:logger_json, "~> 7.0"},

      # Quality tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix],
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      quality: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "openapi.check",
        "dialyzer"
      ]
    ]
  end
end
