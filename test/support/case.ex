defmodule ClickhouseExLogger.Case do
  @moduledoc """
  Case template for tests that need the suite's ClickHouse.

  Tests using it are tagged `:clickhouse` and run **synchronously** by default.
  That default is load-bearing rather than cautious:

    * `ClickhouseExLogger.Buffer` is a globally-named process, and so is the
      `ClickhouseExLogger.Repo` connection. `Handler.install/2` starts the first,
      `Handler.uninstall/1` stops it, and tests that swap the repo's database or
      URL restart the second. Two `async: true` modules doing either of those
      pull state out from under each other.

    * `ClickhouseExLogger.WorkloadTest` freezes the shared container to simulate a
      stalled ClickHouse. That must not happen while another module is writing.

  ExUnit runs every `async: true` module to completion before any synchronous
  one, so a synchronous module has the container to itself by construction
  rather than by timing.

  A module that only reads shared state, and cannot collide, can opt in:

      use ClickhouseExLogger.Case, async: true

  ## Requirements

  `mix test` starts the container (see `ClickhouseExLogger.TestContainer`), so a
  running Podman or Docker engine is required. The suite fails with a diagnostic
  rather than skipping when there is none.
  """

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false)

    quote do
      use ExUnit.Case, async: unquote(async)

      import ClickhouseExLogger.Case

      @moduletag :clickhouse

      setup_all do
        unless ClickhouseExLogger.TestServer.table_exists?() do
          raise """
          #{ClickhouseExLogger.TestServer.database()}.logs is missing even though \
          #{ClickhouseExLogger.TestServer.url()} is reachable.

          test/test_helper.exs creates it. If you are running a subset, create it
          with `mix clickhouse_ex_logger.migrate`.
          """
        end

        :ok
      end
    end
  end

  @doc """
  Empties the `logs` table so the test starts from a known state.
  """
  def truncate_logs!, do: ClickhouseExLogger.TestServer.truncate_logs!()
end
