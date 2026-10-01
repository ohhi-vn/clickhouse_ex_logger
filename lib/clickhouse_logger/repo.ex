defmodule ClickhouseLogger.Repo do
  @moduledoc """
  ClickHouse connection configuration for log inserts.

  Configure it under your application's config:

      config :clickhouse_logger, ClickhouseLogger.Repo,
        url: "http://localhost:8123",
        username: "default",
        password: "",
        database: "my_app"

  Add it to your supervision tree *before* you attach
  `ClickhouseLogger.Handler`, so the first flush has a live connection:

      children = [
        ClickhouseLogger.Repo,
        # then, from your Application.start/2 callback:
        # Logger.add_handlers(:my_app)
        ...
      ]

  The supported keys are those of `AshClickhouse.Repo`: `:url`, `:username`,
  `:password`, `:database`, `:pool_size`, and `:ipv4_only`. See
  `AshClickhouse.Repo` for their defaults.
  """

  use AshClickhouse.Repo, otp_app: :clickhouse_logger
end
