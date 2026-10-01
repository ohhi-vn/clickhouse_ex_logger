defmodule ClickhouseExLogger do
  @moduledoc """
  Ships Elixir `Logger` events into ClickHouse through Ash and AshClickhouse.

  This module is the entry point for documentation. The pieces are:

    * `ClickhouseExLogger.Handler` — the `:logger` handler you register.
    * `ClickhouseExLogger.Buffer` — the process that batches and flushes rows.
    * `ClickhouseExLogger.LogEntry` — the Ash resource mapped to the `logs` table.
    * `ClickhouseExLogger.Repo` — the ClickHouse connection configuration.

  See `ClickhouseExLogger.Handler` for setup and `ClickhouseExLogger.Buffer` for the
  runtime statistics operators inspect.
  """
end
