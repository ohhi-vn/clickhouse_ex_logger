defmodule ClickhouseLogger.Case do
  @moduledoc """
  Case template for tests that need a live ClickHouse.

  Tests using it are tagged `:clickhouse`. `test/test_helper.exs` excludes that
  tag when no ClickHouse answers at `CLICKHOUSE_URL`, so the suite stays green on
  a machine without one, and creates the test schema when one does.

  Start a server with the `docker-compose.yml` in this repo, or point
  `CLICKHOUSE_URL` at your own.
  """

  use ExUnit.CaseTemplate

  alias ClickhouseLogger.TestServer

  using do
    quote do
      import ClickhouseLogger.Case

      @moduletag :clickhouse
    end
  end

  setup_all do
    unless TestServer.table_exists?() do
      raise """
      #{TestServer.database()}.logs is missing even though #{TestServer.url()} is reachable.

      test/test_helper.exs normally creates it. If you are running a subset,
      create it with `mix clickhouse_logger.migrate`.
      """
    end

    :ok
  end

  @doc """
  Empties the `logs` table so the test starts from a known state.
  """
  def truncate_logs!, do: TestServer.truncate_logs!()
end
