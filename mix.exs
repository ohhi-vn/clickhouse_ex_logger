defmodule ClickhouseLogger.MixProject do
  use Mix.Project

  def project do
    [
      app: :clickhouse_logger,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      description:
        "Ship Elixir Logger events into ClickHouse through Ash and AshClickhouse.",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
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
      {:ash, "~> 3.33"},
      {:ash_clickhouse, "~> 0.7"},
      {:clickhouse, "~> 0.32"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
