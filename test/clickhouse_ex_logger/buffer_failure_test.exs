defmodule ClickhouseExLogger.BufferFailureTest do
  @moduledoc """
  Verifies what happens when the ClickHouse insert fails.

  Failure is provoked the honest way — by pointing the repo at a database that
  does not exist — rather than by stubbing a private function.

  Synchronous because it rewrites the globally-configured repo connection and
  restarts it: an `async: true` module would repoint every other module's
  writes at a database that does not exist. `ClickhouseExLogger.Case` defaults to
  that; see the template for why.
  """

  use ClickhouseExLogger.Case

  alias ClickhouseExLogger.Buffer
  alias ClickhouseExLogger.CaptureHandler

  @moduletag :capture_log

  setup do
    # A database that is never created, so every insert fails with
    # UNKNOWN_DATABASE while the server itself stays reachable.
    original = Application.get_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

    Application.put_env(
      :clickhouse_ex_logger,
      ClickhouseExLogger.Repo,
      Keyword.put(original, :database, "clickhouse_ex_logger_absent_database")
    )

    restart_repo_connection()

    on_exit(fn ->
      Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
      restart_repo_connection()
    end)

    :ok
  end

  # `AshClickhouse.Connection.stop/1` raises `:noproc` when the client is already
  # gone, which would abort the test and leave later modules without a
  # connection.
  defp restart_repo_connection do
    try do
      AshClickhouse.Connection.stop(ClickhouseExLogger.Repo)
    catch
      :exit, _reason -> :ok
    end

    {:ok, conn} =
      AshClickhouse.Connection.start_link(
        AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)
      )

    # `start_link` ties the client's lifetime to the process that started it. A
    # `setup` or `on_exit` process exits immediately, which would take the
    # connection — and every later test module — down with it.
    Process.unlink(conn)

    :ok
  end

  defp start_buffer(options) do
    opts =
      Map.merge(
        %{batch_size: 2, flush_interval_ms: 60_000, max_buffer_size: 10},
        Map.new(options)
      )

    {:ok, pid} = GenServer.start_link(Buffer, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    pid
  end

  defp row(message) do
    %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      level: :error,
      message: message,
      module: nil,
      file: nil,
      line: nil,
      function: nil,
      metadata: %{}
    }
  end

  test "counts one failure per flush, not per row" do
    server = start_buffer(batch_size: 2)
    Buffer.enqueue(row("a"), server)
    Buffer.enqueue(row("b"), server)

    stats = eventually(server, &(&1.failed == 1))

    assert stats.failed == 1
    assert stats.delivered == 0
    # Rows are discarded, never retried.
    assert stats.buffered == 0
  end

  test "reports the failure once, through Logger, carrying the internal marker" do
    CaptureHandler.install(self())

    server = start_buffer(batch_size: 1)
    Buffer.enqueue(row("a"), server)

    ExUnit.CaptureLog.capture_log(fn -> Buffer.flush(server) end)

    # Exactly one report for one failed flush.
    assert [event] = CaptureHandler.drain()

    assert event.level == :error
    assert {:string, text} = event.msg
    assert text =~ "ClickhouseExLogger: dropped"
    assert event.meta.clickhouse_ex_logger_internal == true
  end

  test "keeps accepting and counting rows after a failed write" do
    server = start_buffer(batch_size: 1)

    Buffer.enqueue(row("first"), server)
    eventually(server, &(&1.failed == 1))

    Buffer.enqueue(row("second"), server)
    stats = eventually(server, &(&1.failed == 2))

    assert stats.accepted == 2
    assert stats.delivered == 0
    assert Process.alive?(server)
  end

  test "does not retry a failed batch" do
    server = start_buffer(batch_size: 1, flush_interval_ms: 60_000)
    Buffer.enqueue(row("a"), server)

    eventually(server, &(&1.failed == 1))

    # Give a would-be retry plenty of chances to misfire.
    Process.sleep(150)

    assert Buffer.stats(server).failed == 1
    assert Buffer.stats(server).buffered == 0
  end

  test "counts the unwritten rows as lost, and still reconciles" do
    server = start_buffer(batch_size: 3)

    for index <- 1..9, do: Buffer.enqueue(row("row-#{index}"), server)

    # Wait for the flushes to land; the counts asserted below are read after an
    # explicit flush, not from here.
    _ = eventually(server, &(&1.lost == 9))
    :ok = Buffer.flush(server, 5_000)
    stats = Buffer.stats(server)

    # Every insert fails before the first chunk, so nothing was committed and
    # every row is accounted for as lost rather than only "some flush failed".
    assert stats.delivered == 0
    assert stats.lost == 9
    assert stats.accepted == stats.delivered + stats.discarded + stats.lost

    # Fewer than three flushes, not three: `batch_size` is a trigger, so the
    # write after the first takes every row that piled up behind it.
    assert stats.failed >= 1
  end

  defp eventually(server, fun, attempts \\ 300) do
    stats = Buffer.stats(server)

    cond do
      fun.(stats) ->
        stats

      attempts == 0 ->
        flunk("condition never became true; last stats: #{inspect(stats)}")

      true ->
        Process.sleep(10)
        eventually(server, fun, attempts - 1)
    end
  end
end
