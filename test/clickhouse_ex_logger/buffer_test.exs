defmodule ClickhouseExLogger.BufferTest do
  @moduledoc """
  Verifies buffering, batching and overload behaviour against a real ClickHouse.

  These tests write through the whole stack, so they assert on the counters
  *and* on the rows ClickHouse actually stored — which is where the ordering
  guarantee lives.
  """

  use ClickhouseExLogger.Case

  alias ClickhouseExLogger.Buffer

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

  describe "the write monitor" do
    test "ignores a DOWN that matches the write in flight" do
      # `start_write/1` spawn-monitors the process doing the insert. The result
      # message carries everything the buffer needs, so the `:DOWN` is noise; and
      # Erlang does not order a message against a signal, so the `:DOWN` can
      # arrive while `write_ref` is still set. Sending one directly is the only
      # way to reach that clause.
      server = start_buffer(batch_size: 1_000, flush_interval_ms: 60_000)
      enqueue(server, 1)

      eventually(server, &(&1.buffered == 1))
      ref = write_ref(server)

      send(server, {:DOWN, ref, :process, self(), :killed})

      # Ignored rather than treated as a crash: the buffered rows survive and are
      # still written on the next trigger.
      assert Buffer.stats(server).buffered == 1
      assert Buffer.stats(server).lost == 0

      :ok = Buffer.flush(server, 5_000)
      assert Buffer.stats(server).delivered == 1
      assert stored_count() == "1"
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

  # The reference the buffer is monitoring the in-flight write with. `:sys` rather
  # than a cast, because the field is private state.
  defp write_ref(server) do
    %{write_ref: ref} = :sys.get_state(server)
    ref
  end
end
