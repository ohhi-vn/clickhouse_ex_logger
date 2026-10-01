defmodule ClickhouseExLogger.Domain do
  @moduledoc """
  The Ash domain holding `ClickhouseExLogger.LogEntry`.

  You do not need to add this domain to your own. `ClickhouseExLogger.Buffer`
  writes through the resource directly, and the resource names this domain, so
  as long as `clickhouse_ex_logger` is a dependency the write path resolves on its
  own.

  You only need it if you want to `Ash.read/1` log rows through Ash.
  """

  use Ash.Domain

  resources do
    resource(ClickhouseExLogger.LogEntry)
  end
end
