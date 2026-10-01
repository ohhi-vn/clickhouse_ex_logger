defmodule ClickhouseExLogger.Repo do
  @moduledoc """
  ClickHouse connection configuration for log inserts.

  Configure it under your application's config:

      config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
        url: "http://localhost:8123",
        username: "default",
        password: "",
        database: "my_app"

  Add it to your supervision tree *before* you attach
  `ClickhouseExLogger.Handler`, so the first flush has a live connection:

      children = [
        ClickhouseExLogger.Repo,
        # then, from your Application.start/2 callback:
        # Logger.add_handlers(:my_app)
        ...
      ]

  The supported keys are those of `AshClickhouse.Repo`: `:url`, `:username`,
  `:password`, `:database`, `:pool_size`, and `:ipv4_only`. See
  `AshClickhouse.Repo` for their defaults.

  ## Missing configuration is an error, not a default

  AshClickhouse's own `config/0` callback returns `[]` when the application
  environment has no entry for this repo, and `config_to_conn_opts/1` then
  fills in `url: "http://localhost:8123"`. That default would let a host that
  misconfigured the key start cleanly and write to whatever ClickHouse happens
  to be on localhost, or report every flush as lost — which reads as an outage
  rather than the configuration mistake it is.

  So `config/0` is overridden here to raise when this repo is not configured.
  The one thing this library's failure modes are not is a wrong destination
  chosen silently, and "ClickHouse is unreachable" is precisely the symptom that
  already means everything else in this pipeline.
  """

  use AshClickhouse.Repo, otp_app: :clickhouse_ex_logger

  @impl AshClickhouse.Repo
  @spec config() :: keyword()
  def config do
    case Application.fetch_env(:clickhouse_ex_logger, __MODULE__) do
      {:ok, config} when is_list(config) ->
        config

      {:ok, other} ->
        raise AshClickhouse.Error.ConfigurationError,
              "Expected the :clickhouse_ex_logger config for #{inspect(__MODULE__)} " <>
                "to be a keyword list, got: #{inspect(other)}"

      :error ->
        raise AshClickhouse.Error.ConfigurationError,
              "ClickhouseExLogger.Repo is not configured.\n\n" <>
                "Add this to your application's config:\n\n" <>
                "    config :clickhouse_ex_logger, ClickhouseExLogger.Repo,\n" <>
                "      url: \"http://localhost:8123\",\n" <>
                "      username: \"default\",\n" <>
                "      password: \"\",\n" <>
                "      database: \"my_app\"\n"
    end
  end
end
