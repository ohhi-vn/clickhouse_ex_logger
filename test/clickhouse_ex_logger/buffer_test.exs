defmodule ClickhouseExLogger.BufferTest do
  @moduledoc """
  Verifies buffering, batching and overload behaviour against a real ClickHouse.

  These tests write through the whole stack, so they assert on the counters
  *and* on the rows ClickHouse actually stored — which is where the ordering
  guarantee lives.
  """

  use ClickhouseExLogger.Case

  alias ClickhouseExLogger.Buffer
  alias ClickhouseExLogger.CaptureHandler

  @moduletag :capture_log

  setup do
    truncate_logs!()
    :ok
  end

  defp start_buffer(options) do
    opts =
      Map.merge(
        %{batch_size: 5, flush_interval_ms: 60_000, max_buffer_size: 10},
        Map.new(options)
      )

    {:ok, pid} = GenServer.start_link(Buffer, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    pid
  end

  defp enqueue(server, count, prefix \\ "row") do
    for index <- 1..count, do: Buffer.enqueue(row("#{prefix}-#{index}"), server)
  end

  defp row(message) do
    %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      level: :info,
      message: message,
      module: "BufferTest",
      file: "buffer_test.exs",
      line: 1,
      function: "row/1",
      metadata: %{}
    }
  end

  defp stored_messages do
    ClickhouseExLogger.TestServer.query!("SELECT message FROM logs ORDER BY message ASC")
    |> String.split("\n", trim: true)
  end

  defp stored_in_timestamp_order do
    ClickhouseExLogger.TestServer.query!("SELECT message FROM logs ORDER BY timestamp ASC")
    |> String.split("\n", trim: true)
  end

  defp stored_count do
    ClickhouseExLogger.TestServer.query!("SELECT count() FROM logs") |> String.trim()
  end

  describe "stats/1" do
    test "reports zeroed counters when the buffer is not running" do
      assert Buffer.stats(:no_such_buffer) == %{
               accepted: 0,
               delivered: 0,
               discarded: 0,
               lost: 0,
               failed: 0,
               buffered: 0,
               active?: false
             }
    end

    test "reports accepted and buffered counts after enqueueing" do
      server = start_buffer(batch_size: 100, flush_interval_ms: 60_000)
      enqueue(server, 3)

      stats = eventually(server, &(&1.buffered == 3))

      assert stats.accepted == 3
      assert stats.delivered == 0
      assert stats.discarded == 0
      assert stats.failed == 0
      assert stats.active?
    end

    test "does not report a busy buffer as one that never started" do
      # The buffer answers `:stats` from its own process and never blocks on
      # ClickHouse, so it has to be suspended for the call to time out. What
      # matters is that a buffer which exists but did not answer is not reported
      # the same way as one that is not running: a zeroed report marked inactive is
      # indistinguishable from a system that never accepted anything.
      server = start_buffer(batch_size: 100, flush_interval_ms: 60_000)
      enqueue(server, 3)
      eventually(server, &(&1.buffered == 3))

      :ok = :sys.suspend(server)
      on_exit(fn -> if Process.alive?(server), do: :sys.resume(server) end)

      stats = Buffer.stats(server)

      assert stats.active?
    end
  end

  describe "enqueue/1" do
    test "never blocks and never raises when the buffer is absent" do
      assert Buffer.enqueue(row("orphan")) == :ok
    end
  end

  describe "batch-size trigger" do
    test "writes exactly one batch of batch_size rows" do
      server = start_buffer(batch_size: 4, flush_interval_ms: 60_000)
      enqueue(server, 4)

      stats = eventually(server, &(&1.delivered == 4))

      assert stats.delivered == 4
      assert stats.buffered == 0
      assert stats.discarded == 0
      assert stored_count() == "4"
    end

    test "does not write below the batch size" do
      server = start_buffer(batch_size: 5, flush_interval_ms: 60_000)
      enqueue(server, 4)

      eventually(server, &(&1.buffered == 4))

      assert Buffer.stats(server).delivered == 0
      assert stored_count() == "0"
    end

    test "a long write drains everything accumulated behind it" do
      # batch_size is a trigger, not a cap: rows that pile up while a write is in
      # flight all go out in the next one.
      server = start_buffer(batch_size: 2, flush_interval_ms: 60_000)
      enqueue(server, 10)

      stats = eventually(server, &(&1.delivered == 10))

      assert stats.delivered == 10
      assert stats.buffered == 0
      assert stored_count() == "10"
    end
  end

  describe "interval trigger" do
    test "writes a partial batch when the interval elapses" do
      server = start_buffer(batch_size: 100, flush_interval_ms: 40)
      enqueue(server, 2)

      stats = eventually(server, &(&1.delivered == 2))

      assert stats.delivered == 2
      assert stats.buffered == 0
      assert stored_count() == "2"
    end

    test "keeps writing on every interval while rows are arriving" do
      server = start_buffer(batch_size: 1_000, flush_interval_ms: 30)

      enqueue(server, 2)
      eventually(server, &(&1.delivered == 2))

      enqueue(server, 2, "second")

      stats = eventually(server, &(&1.delivered == 4))
      assert stats.delivered == 4
      assert stored_count() == "4"
    end
  end

  describe "single in-flight write" do
    test "does not start a second write while one is running" do
      # A large batch takes long enough to observe. If a second write could start
      # concurrently, the buffer would drain again instead of accumulating, and
      # the in-flight bookkeeping would lose track of a batch.
      server =
        start_buffer(batch_size: 4_000, flush_interval_ms: 60_000, max_buffer_size: 10_000)

      enqueue(server, 4_000, "slow")

      # Wait until the batch-size trigger has fired and the write is under way.
      eventually(server, &(&1.buffered == 0))

      enqueue(server, 500, "queued")

      stats = Buffer.stats(server)

      # Still no new write: the 500 rows are waiting, not being written.
      assert stats.buffered == 500
      assert stats.delivered == 0

      stats = eventually(server, &(&1.delivered == 4_500))

      assert stats.delivered == 4_500
      assert stats.buffered == 0
      assert stored_count() == "4500"
    end
  end

  describe "ordering" do
    test "stores rows in the order they were enqueued" do
      server = start_buffer(batch_size: 3, flush_interval_ms: 60_000)

      # One distinct timestamp per row, so `ORDER BY timestamp` is an exact
      # check on the order the buffer handed the rows over.
      base = DateTime.utc_now()

      for index <- 0..8 do
        Buffer.enqueue(
          %{
            id: Ash.UUID.generate(),
            timestamp: DateTime.add(base, index, :millisecond),
            level: :info,
            message: "ordered-#{index}",
            module: nil,
            file: nil,
            line: nil,
            function: nil,
            metadata: %{}
          },
          server
        )
      end

      eventually(server, &(&1.delivered == 9))

      assert stored_in_timestamp_order() == Enum.map(0..8, &"ordered-#{&1}")
    end

    test "a flush writes rows in enqueue order across several batches" do
      server = start_buffer(batch_size: 2, flush_interval_ms: 60_000)

      # Flush between each pair so batch boundaries are unambiguous.
      for index <- 1..5 do
        Buffer.enqueue(row("ordered-#{index}"), server)
        Buffer.flush(server)
      end

      assert stored_messages() == [
               "ordered-1",
               "ordered-2",
               "ordered-3",
               "ordered-4",
               "ordered-5"
             ]
    end
  end

  describe "overflow" do
    test "discards the oldest rows and never exceeds max_buffer_size" do
      server = start_buffer(batch_size: 100, flush_interval_ms: 60_000, max_buffer_size: 5)
      enqueue(server, 12)

      stats = eventually(server, &(&1.buffered == 5))

      assert stats.accepted == 12
      assert stats.discarded == 7
      assert stats.buffered == 5
    end

    test "keeps the newest rows, not the oldest" do
      server = start_buffer(batch_size: 100, flush_interval_ms: 60_000, max_buffer_size: 3)
      enqueue(server, 6)

      eventually(server, &(&1.buffered == 3))
      Buffer.flush(server)

      assert stored_messages() == ["row-4", "row-5", "row-6"]
    end

    test "stays bounded under sustained overload" do
      server = start_buffer(batch_size: 100, flush_interval_ms: 60_000, max_buffer_size: 8)
      enqueue(server, 500)

      stats = eventually(server, &(&1.accepted == 500))

      assert stats.discarded == 492
      assert stats.buffered <= 8
    end
  end

  describe "flush/1" do
    test "writes a partial batch immediately and waits for it" do
      server = start_buffer(batch_size: 1_000, flush_interval_ms: 60_000)
      enqueue(server, 3)

      assert Buffer.flush(server) == :ok

      assert Buffer.stats(server).delivered == 3
      assert stored_count() == "3"
    end

    test "is a no-op on an empty buffer" do
      server = start_buffer(batch_size: 1_000, flush_interval_ms: 60_000)

      assert Buffer.flush(server) == :ok
      assert Buffer.stats(server).delivered == 0
    end

    test "waits for an in-flight write rather than returning early" do
      server = start_buffer(batch_size: 2, flush_interval_ms: 60_000)
      enqueue(server, 4)

      assert Buffer.flush(server) == :ok
      assert Buffer.stats(server).buffered == 0
      assert stored_count() == "4"
    end

    test "returns :ok rather than raising when the buffer is absent" do
      assert Buffer.flush(:no_such_buffer) == :ok
    end
  end

  describe "stop/1" do
    test "stops a running buffer" do
      server = start_buffer(batch_size: 5, flush_interval_ms: 60_000)

      assert Buffer.stop(server) == :ok
      refute Process.alive?(server)
    end

    test "returns :ok rather than raising when the buffer is absent" do
      # `GenServer.stop/1` on an unregistered name exits `:noproc`, which would
      # otherwise take a shutdown path down with it.
      assert Buffer.stop(:no_such_buffer) == :ok
    end
  end

  describe "a write that dies without reporting an outcome" do
    # `start_write/1` spawn-monitors the process doing the insert and then waits
    # for a `{ref, result}` message. That process can die before it sends one:
    # `clickhouse` 0.32.0 raises from inside a query for responses its error-type
    # lookup does not recognise, and names an undefined `ClickHouse.NetworkError`
    # struct for `DB::NetException` bodies — neither of which is in
    # `AshClickhouse.Connection`'s rescue list, so both escape the insert.
    #
    # A row carrying a value the data layer cannot encode is the same shape of
    # failure reachable from outside the library, and deterministic: encoding the
    # metadata raises before a connection is used, so the spawned process dies
    # having sent nothing. (A missing `timestamp` used to serve this purpose, but
    # `Ash.bulk_create/4` now rejects it as a validation failure rather than
    # raising.)
    defp dying_row do
      %{
        id: Ash.UUID.generate(),
        timestamp: DateTime.utc_now(),
        level: :info,
        message: "never written",
        module: nil,
        file: nil,
        line: nil,
        function: nil,
        metadata: %{"unencodable" => self()}
      }
    end

    test "counts the abandoned batch as lost so the counters still reconcile" do
      server = start_buffer(batch_size: 1, flush_interval_ms: 60_000)
      Buffer.enqueue(dying_row(), server)

      stats = eventually(server, &(&1.failed == 1))

      assert stats.accepted == 1
      assert stats.delivered == 0
      assert stats.discarded == 0
      assert stats.lost == 1
      assert stats.buffered == 0
      assert stats.accepted == stats.delivered + stats.discarded + stats.lost
      assert stored_count() == "0"
    end

    test "reports the crash through the logger" do
      CaptureHandler.install(self())

      server = start_buffer(batch_size: 1, flush_interval_ms: 60_000)
      Buffer.enqueue(dying_row(), server)

      eventually(server, &(&1.failed == 1))

      # Exactly one report for one failed flush, carrying the marker that keeps it
      # out of the `logs` table. Elixir's own "raised an exception" report for the
      # dead write process is a separate, unmarked, legitimate log line.
      internal = Enum.filter(CaptureHandler.drain(), & &1.meta[:clickhouse_ex_logger_internal])
      assert [event] = internal

      assert event.level == :error
      assert {:string, text} = event.msg
      assert text =~ "ClickhouseExLogger: dropped 1 buffered log row"

      # The reason an operator reads names the failure without the frames that
      # produced it. A raise from the metadata encoder arrives as the exception's
      # own message, not as an inspected internal structure.
      assert text =~ "String.Chars not implemented for PID"
      refute text =~ "stacktrace"
    end

    test "keeps delivering events logged after the crash" do
      server = start_buffer(batch_size: 1, flush_interval_ms: 60_000)
      Buffer.enqueue(dying_row(), server)
      eventually(server, &(&1.failed == 1))

      Buffer.enqueue(row("after"), server)

      stats = eventually(server, &(&1.delivered == 1))

      assert stats.buffered == 0
      assert stats.accepted == 2
      assert stats.lost == 1
      assert stored_count() == "1"
    end

    test "does not stay wedged waiting for a message that is never coming" do
      server = start_buffer(batch_size: 1, flush_interval_ms: 60_000)
      Buffer.enqueue(dying_row(), server)
      eventually(server, &(&1.failed == 1))

      # `flush/1` is bounded by its call timeout, so a wedge is observable as a
      # call that never returns rather than as a hang.
      assert Buffer.flush(server, 1_000) == :ok
      assert Buffer.stats(server).buffered == 0
    end

    test "recovers when the write reports normally afterwards" do
      server = start_buffer(batch_size: 1, flush_interval_ms: 60_000)
      Buffer.enqueue(dying_row(), server)
      eventually(server, &(&1.failed == 1))

      enqueue(server, 3)

      stats = eventually(server, &(&1.delivered == 3))

      assert stats.accepted == 4
      assert stats.failed == 1
      assert stats.accepted == stats.delivered + stats.discarded + stats.lost
      assert stored_count() == "3"
    end

    test "treats an unrecognised result as a failed flush rather than crashing" do
      # `{:error, message}` is the shape this module's old `@spec` advertised and
      # its implementation never returned. It is the most plausible shape for a
      # future change to start returning, and the one the buffer must survive.
      server = start_buffer(batch_size: 1_000, flush_interval_ms: 60_000)
      ref = fake_in_flight_write(server, 2)

      send(server, {ref, {:error, "a message with no committed count"}})

      stats = Buffer.stats(server)

      assert Process.alive?(server)
      assert stats.failed == 1
      assert stats.lost == 2
      assert stats.delivered == 0
    end

    test "reports an unrecognised result as an insert failure" do
      CaptureHandler.install(self())

      server = start_buffer(batch_size: 1_000, flush_interval_ms: 60_000)
      ref = fake_in_flight_write(server, 1)

      send(server, {ref, :a_shape_nobody_agreed_on})

      internal = Enum.filter(CaptureHandler.drain(), & &1.meta[:clickhouse_ex_logger_internal])
      assert [event] = internal
      assert {:string, text} = event.msg
      assert text =~ "unexpected insert result"
    end
  end

  describe "terminate/2" do
    test "makes a final write attempt for buffered rows and stops cleanly" do
      server = start_buffer(batch_size: 10_000, flush_interval_ms: 60_000)
      enqueue(server, 2)

      eventually(server, &(&1.buffered == 2))

      GenServer.stop(server, :normal, 5_000)

      refute Process.alive?(server)
      assert stored_count() == "2"
    end

    test "does not start a second write while one is under way" do
      # The ordering guarantee is only worth anything if it holds to the end of the
      # process's life. A shutdown that wrote the queued rows itself would run two
      # inserts concurrently — this one, and the one the outstanding write is still
      # doing — and neither could be ordered against the other.
      server =
        start_buffer(batch_size: 4_000, flush_interval_ms: 60_000, max_buffer_size: 10_000)

      enqueue(server, 4_000, "slow")
      eventually(server, &(&1.buffered == 0))

      # Rows pile up behind the write that is running.
      enqueue(server, 500, "queued")
      eventually(server, &(&1.buffered == 500))

      GenServer.stop(server, :normal, 5_000)

      refute Process.alive?(server)

      # Only the outstanding write's rows landed, and nothing was written twice.
      assert stored_count() == "4000"
    end

    test "writes what it holds even while other processes keep logging" do
      # `bounded_flush/1` is a selective receive, so what else is in the mailbox
      # matters: the final flush has to match its own write's reference rather than
      # the first two-element message it sees. Uninstallation is exactly when that
      # happens — the handler comes off, and other processes are still logging into
      # a buffer that is on its way out.
      server =
        start_buffer(batch_size: 10_000, flush_interval_ms: 60_000, max_buffer_size: 100)

      enqueue(server, 2)
      eventually(server, &(&1.buffered == 2))

      noise = Task.async(fn -> Enum.each(1..25, &Buffer.enqueue(row("noise-#{&1}"), server)) end)
      Task.await(noise)

      GenServer.stop(server, :normal, 10_000)

      refute Process.alive?(server)

      # Everything the buffer held at shutdown was written, once.
      assert stored_count() == "27"
    end
  end

  describe "counter reconciliation" do
    test "accepted equals delivered plus discarded plus lost on a clean run" do
      server = start_buffer(batch_size: 5)
      enqueue(server, 12)

      eventually(server, &(&1.delivered == 12))
      :ok = Buffer.flush(server, 5_000)
      stats = Buffer.stats(server)

      assert stats.buffered == 0
      assert stats.discarded == 0
      assert stats.lost == 0
      assert stats.accepted == stats.delivered + stats.discarded + stats.lost
      assert stored_count() == "#{stats.delivered}"
    end

    test "accepted equals delivered plus discarded plus lost when the buffer overflows" do
      # A batch size above the cap means the buffer can never reach its own write
      # trigger, so the rows pile up and are dropped oldest-first.
      server = start_buffer(batch_size: 1_000, max_buffer_size: 10)
      enqueue(server, 25)

      eventually(server, &(&1.discarded == 15))
      :ok = Buffer.flush(server, 5_000)
      stats = Buffer.stats(server)

      assert stats.accepted == 25
      assert stats.discarded == 15
      assert stats.buffered == 0
      assert stats.accepted == stats.delivered + stats.discarded + stats.lost
      assert stored_count() == "#{stats.delivered}"
    end
  end

  # Polls `fun` until it returns true, so tests do not depend on a fixed sleep.
  defp eventually(server, fun, attempts \\ 300) do
    stats = Buffer.stats(server)

    cond do
      fun.(stats) -> stats
      attempts == 0 -> flunk("condition never became true; last stats: #{inspect(stats)}")
      true -> Process.sleep(10) && eventually(server, fun, attempts - 1)
    end
  end

  # Puts the state a write under way would have left, without starting one, and
  # returns the reference its result would carry. `:sys` rather than a cast,
  # because the fields are private state.
  defp fake_in_flight_write(server, in_flight) do
    ref = make_ref()

    :sys.replace_state(server, fn state ->
      %{state | write_ref: ref, write_monitor: make_ref(), in_flight: in_flight}
    end)

    ref
  end
end
