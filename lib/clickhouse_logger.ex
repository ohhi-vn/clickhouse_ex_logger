defmodule ClickhouseLogger do
  @moduledoc """
  Ships Elixir `Logger` events into ClickHouse through Ash and AshClickhouse.

  This module is the entry point for documentation. The pieces are:

    * `ClickhouseLogger.Handler` — the `:logger` handler you register.
    * `ClickhouseLogger.Buffer` — the process that batches and flushes rows.
    * `ClickhouseLogger.LogEntry` — the Ash resource mapped to the `logs` table.
    * `ClickhouseLogger.Repo` — the ClickHouse connection configuration.

  See `ClickhouseLogger.Handler` for setup and `ClickhouseLogger.Buffer` for the
  runtime statistics operators inspect.
  """
end
