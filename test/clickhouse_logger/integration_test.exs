defmodule ClickhouseLogger.IntegrationTest do
  @moduledoc """
  The whole pipeline, end to end.

  Logs through real `Logger` calls, through the real handler and buffer, into a
  real ClickHouse, and reads the rows back. This is the test that would catch a
  break between the pieces — a column the mapper writes that the resource does not
  have, a level that survives `:logger` but not the round trip.
  """

  use ClickhouseLogger.Case

  require Logger

  @moduletag :capture_log

  alias ClickhouseLogger.Buffer
  alias ClickhouseLogger.Handler

  setup do
    truncate_logs!()

    handler_id = String.to_atom("clickhouse_logger_e2e_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      _ = Handler.uninstall(handler_id)

      case GenServer.whereis(Buffer) do
        nil -> :ok
        _pid -> Buffer.stop()
      end
    end)

    %{handler_id: handler_id}
  end

  defp stored do
    ClickhouseLogger.TestServer.query!("""
    SELECT level, message, module, file, line, function, metadata
    FROM logs
    ORDER BY timestamp ASC, id ASC
    FORMAT JSONEachRow
    """)
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "logs at several levels become queryable rows with the documented columns", %{
    handler_id: handler_id
  } do
    {:ok, _} =
      Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

    # The test suite's primary level is `:info`, so `:debug` and below never
    # reach any handler at all. Those are covered exhaustively against the
    # normaliser in ClickhouseLogger.EventTest; this test covers what a default
    # application actually emits.
    Logger.info("an info line")
    Logger.notice("a notice line")
    Logger.warning("a warning line")
    Logger.error("an error line")
    Logger.critical("a critical line")
    Logger.error("an error with metadata", user_id: 7, request_id: "req-1")

    eventually(fn -> Buffer.stats().accepted == 6 end)
    assert :ok = Buffer.flush()

    rows = stored()
    messages = Enum.map(rows, & &1["message"])

    assert "an info line" in messages
    assert "a notice line" in messages
    assert "a warning line" in messages
    assert "an error line" in messages
    assert "a critical line" in messages
    assert "an error with metadata" in messages

    levels = rows |> Enum.map(& &1["level"]) |> Enum.sort()

    assert levels == ["critical", "error", "error", "info", "notice", "warning"]
  end

  test "records source location and metadata for a row", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

    Logger.info("with context", user_id: 42, request_id: "abc")

    eventually(fn -> Buffer.stats().accepted == 1 end)
    assert :ok = Buffer.flush()

    [row] = stored()

    assert row["message"] == "with context"
    assert row["module"] == inspect(__MODULE__)
    assert row["file"] =~ "integration_test.exs"
    assert is_integer(row["line"])
    assert row["function"] =~ "records source location and metadata for a row"
    assert row["metadata"]["user_id"] == "42"
    assert row["metadata"]["request_id"] == "abc"
  end

  test "stores compound metadata as a marked, round-trippable term", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

    Logger.info("compound metadata", payload: %{a: [1, 2]})

    eventually(fn -> Buffer.stats().accepted == 1 end)
    assert :ok = Buffer.flush()

    [row] = stored()

    assert row["metadata"]["payload"] == "term:%{a: [1, 2]}"

    # `Code.eval_string/1` returns `{value, bindings}`, and these terms bind no
    # variables.
    assert row["metadata"]["payload"]
           |> String.replace_prefix("term:", "")
           |> Code.eval_string() == {%{a: [1, 2]}, []}
  end

  test "an event with no source location still becomes a row", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

    # `Logger.bare_log/3` does not attach `:mfa`, `:file` or `:line`.
    Logger.bare_log(:info, "no source location")

    eventually(fn -> Buffer.stats().accepted == 1 end)
    assert :ok = Buffer.flush()

    [row] = stored()

    assert row["message"] == "no source location"
    assert row["module"] == nil
    assert row["file"] == nil
    assert row["line"] == nil
  end

  test "rows come back ordered by timestamp and id", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 3, flush_interval_ms: 60_000})

    for index <- 1..9 do
      Logger.info("ordered-#{index}")
    end

    eventually(fn -> Buffer.stats().delivered == 9 end)

    ordered = stored() |> Enum.map(& &1["message"])

    assert ordered == Enum.map(1..9, &"ordered-#{&1}")
  end

  test "an OTP-sourced event is stored with its level", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

    :logger.warning("straight from erlang", %{user_id: 3})

    eventually(fn -> Buffer.stats().accepted == 1 end)
    assert :ok = Buffer.flush()

    [row] = stored()

    assert row["level"] == "warning"
    assert row["message"] == "straight from erlang"
    assert row["metadata"]["user_id"] == "3"
  end

  test "the batch-size trigger writes without an explicit flush", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 5, flush_interval_ms: 60_000})

    for index <- 1..5, do: Logger.info("batched-#{index}")

    eventually(fn -> Buffer.stats().delivered == 5 end)

    assert length(stored()) == 5
  end

  test "the interval trigger writes without an explicit flush", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 40})

    Logger.info("written by the timer")

    eventually(fn -> Buffer.stats().delivered == 1 end)

    assert [row] = stored()
    assert row["message"] == "written by the timer"
  end

  test "removing the handler drains what was already accepted", %{handler_id: handler_id} do
    {:ok, _} =
      Handler.install(handler_id, %{
        batch_size: 10_000,
        flush_interval_ms: 60_000,
        max_buffer_size: 100
      })

    for index <- 1..4, do: Logger.info("drained-#{index}")

    eventually(fn -> Buffer.stats().buffered == 4 end)

    assert :ok = Handler.uninstall(handler_id)

    messages = stored() |> Enum.map(& &1["message"]) |> Enum.sort()
    assert messages == ["drained-1", "drained-2", "drained-3", "drained-4"]
  end

  test "the backend never writes a row for its own failure report", %{handler_id: handler_id} do
    {:ok, _} =
      Handler.install(handler_id, %{
        level: :all,
        batch_size: 1,
        flush_interval_ms: 60_000
      })

    # Simulate what the buffer does when an insert fails.
    Logger.error(
      "ClickhouseLogger: dropped 1 buffered log row(s); the ClickHouse insert failed: boom",
      clickhouse_logger_internal: true
    )

    Process.sleep(100)
    assert :ok = Buffer.flush()

    assert stored() == []
    assert Buffer.stats().accepted == 0
  end

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true; stats: #{inspect(Buffer.stats())}")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
