defmodule ClickhouseExLogger.WorkloadTest do
  @moduledoc """
  Drives the pipeline hard, against a real ClickHouse, and asserts the promises
  the library makes about load and failure.

  The interesting half is the stall. `ClickhouseExLogger.BufferFailureTest` can
  only provoke a *fast* failure — it points the repo at a database that does not
  exist, so every insert errors immediately and the batch dies on its first
  chunk. A ClickHouse that has gone *slow* is a different thing: connections stay
  open, nothing errors, and each insert blocks until the client's 15s
  `recv_timeout`. That is the condition this module exists to cover, and
  `ClickhouseExLogger.TestContainer.pause/0` is the only practical way to produce
  it — a stopped container refuses connections and fails instantly.

  Synchronous, because pausing the container freezes it for every other module.
  `ClickhouseExLogger.Case` defaults to that for exactly this reason.

  Ordering is not asserted across producers. It is not a property this library
  can hold: `id` is a random UUID, so `ORDER BY timestamp, id` cannot recover
  the order of two events that share a microsecond, and concurrent producers
  produce such pairs routinely.
  """

  use ClickhouseExLogger.Case

  require Logger

  alias ClickhouseExLogger.Buffer
  alias ClickhouseExLogger.Handler
  alias ClickhouseExLogger.TestContainer

  @moduletag :capture_log
  @moduletag timeout: 180_000

  @producers 8
  @per_producer 400
  @max_buffer_size 500

  # A logging call formats a row and casts it. Anything near this is a stall in
  # the handler itself rather than ordinary work.
  @max_call_micros 50_000

  setup do
    # Stop a buffer left by an earlier test *before* truncating: its shutdown
    # write lands in `logs`, and would otherwise be counted as this test's rows.
    if Process.whereis(Buffer), do: Buffer.stop()

    truncate_logs!()

    # Safety net for a test that fails before `install!/1` runs its own cleanup.
    on_exit(fn -> TestContainer.unpause() end)

    :ok
  end

  describe "sustained load against a healthy ClickHouse" do
    test "every accepted row is delivered and the buffer drains" do
      install!(batch_size: 200, flush_interval_ms: 200)

      latencies = hammer()

      eventually(&(&1.accepted == @producers * @per_producer))
      :ok = Buffer.flush(Buffer, 30_000)
      stats = settled()

      assert stats.delivered == @producers * @per_producer
      assert stats.discarded == 0
      assert stats.lost == 0
      assert stats.failed == 0
      assert stats.buffered == 0
      assert stats.accepted == stats.delivered + stats.discarded + stats.lost
      assert stored_count() == "#{stats.delivered}"

      assert Enum.max(latencies) < @max_call_micros,
             "a logging call blocked for #{Enum.max(latencies)}us"
    end
  end

  describe "load while ClickHouse is stalled" do
    test "the caller is never blocked, memory stays bounded, and loss is counted" do
      install!(batch_size: 100, flush_interval_ms: 100, max_buffer_size: @max_buffer_size)

      # Get a write in flight so the buffer has something to pile up behind.
      #
      # Wait for it to be *delivered* before pausing, not merely accepted: a row
      # that is only buffered races the pause, and if its write happens to land
      # first, `delivered` is 1 by the time the stall begins and the assertion
      # below is measuring the test's timing rather than the pipeline. Waiting
      # leaves the buffer idle at the moment of the pause, so the first
      # post-pause flush is the one that stalls — which is the state that test is
      # about.
      Logger.info("before the stall")
      eventually(&(&1.delivered >= 1))
      delivered_before_stall = Buffer.stats(Buffer).delivered

      TestContainer.pause()
      start_sampler()
      latencies = hammer()
      samples = drain_samples()

      # Nothing was delivered while paused, and the buffer never grew past its
      # cap however much arrived.
      assert Enum.max(latencies) < @max_call_micros,
             "a logging call blocked for #{Enum.max(latencies)}us while ClickHouse was paused"

      assert samples != []
      assert Enum.max(Enum.map(samples, & &1.buffered)) <= @max_buffer_size

      assert Enum.all?(samples, &(&1.buffered <= @max_buffer_size))
      assert Enum.all?(samples, & &1.active?)

      stats = Buffer.stats(Buffer)

      # The cap was actually reached, so the bound above is not vacuous.
      assert stats.discarded > 0
      assert stats.buffered <= @max_buffer_size

      # Nothing was delivered while paused: the write started after the pause is
      # still waiting on the stalled server.
      assert stats.delivered == delivered_before_stall

      # Mid-flight the counters need not reconcile — rows are buffered or in
      # flight. What must hold is that nothing was lost *silently*: every
      # accepted row is delivered, discarded, lost, or still held.
      assert stats.accepted >= stats.delivered + stats.discarded + stats.lost
    end

    test "the pipeline recovers once ClickHouse answers again" do
      install!(batch_size: 100, flush_interval_ms: 100, max_buffer_size: @max_buffer_size)

      Logger.info("before the stall")
      eventually(&(&1.accepted >= 1))

      TestContainer.pause()
      hammer()
      stalled = Buffer.stats(Buffer)

      TestContainer.unpause()

      # Writes resume on their own once the container answers; give the first
      # one room to come out of its recv_timeout and finish.
      eventually(&(&1.delivered > stalled.delivered), 1_200)
      :ok = Buffer.flush(Buffer, 60_000)
      settled = settled()

      assert settled.buffered == 0
      assert settled.delivered > stalled.delivered

    end
  end

  describe "removing the handler while ClickHouse is stalled" do
    test "returns in bounded time instead of waiting on the insert" do
      handler_id = install!(batch_size: 1_000, flush_interval_ms: 60_000)

      TestContainer.pause()
      hammer()

      # `uninstall/1` gives its own flush 5s and `terminate/2` gives the final
      # write another 5s. Unbounded, this is ten 1000-row chunks at 15s each.
      {elapsed, _result} = :timer.tc(fn -> Handler.uninstall(handler_id) end)
      elapsed_ms = div(elapsed, 1_000)

      assert elapsed_ms < 30_000,
             "uninstall/1 took #{elapsed_ms}ms with ClickHouse paused"

      refute Process.whereis(Buffer)
    end
  end

  # --- helpers ------------------------------------------------------------

  defp install!(options) do
    handler_id = String.to_atom("clickhouse_ex_logger_workload_#{System.unique_integer([:positive])}")

    # `Handler.install/2` is idempotent by design: if a buffer is already running
    # it is reused, options and counters included. That is right for an
    # application and wrong here, where each case needs its own batching config
    # and a zeroed counter. `setup/0` stops any leftover before truncating.
    {:ok, ^handler_id} = Handler.install(handler_id, options)

    on_exit(fn -> cleanup(handler_id) end)

    handler_id
  end

  # One callback, in a deliberate order, rather than several relying on the
  # order `on_exit` happens to run them in.
  #
  # The pause has to come off first: `uninstall/1` flushes, and a flush against
  # a frozen container writes nothing, so unpausing afterwards would leave those
  # rows to land in some later module's table.
  #
  # The truncate at the end catches the write this module left in flight. It is
  # an unlinked `spawn_monitor` that can still be running when the buffer stops,
  # so its rows can arrive just after `uninstall/1` returns.
  defp cleanup(handler_id) do
    TestContainer.unpause()
    Handler.uninstall(handler_id)
    Process.sleep(250)
    truncate_logs!()
  end

  # Drives `@producers * @per_producer` events through the handler from
  # concurrent processes, and returns each producer's worst single-call latency.
  defp hammer do
    1..@producers
    |> Enum.map(fn _ ->
      Task.async(fn ->
        Enum.reduce(1..@per_producer, 0, fn index, worst ->
          max(worst, timed_log(index))
        end)
      end)
    end)
    |> Enum.map(&Task.await(&1, 120_000))
  end

  defp timed_log(index) do
    started = System.monotonic_time(:microsecond)
    Logger.info("workload-#{index}", workload: true)
    System.monotonic_time(:microsecond) - started
  end

  # Samples the counters while the producers run.
  #
  # Expect few samples, not many: `Buffer.stats/1` is a `call` into the very
  # process the producers are saturating with casts, so the sampler queues
  # behind the load it is trying to observe. It is a spot check that the buffer
  # is not observed over its cap, not a peak measurement — the cap is enforced
  # per row inside `ClickhouseExLogger.Buffer`, so asserting it at rest below is
  # the real check.
  defp start_sampler do
    parent = self()

    pid =
      spawn_link(fn -> sample_loop(parent) end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp sample_loop(parent) do
    send(parent, {:sample, Buffer.stats(Buffer)})
    Process.sleep(25)
    sample_loop(parent)
  end

  defp drain_samples(acc \\ []) do
    receive do
      {:sample, stats} -> drain_samples([stats | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp eventually(fun, attempts \\ 600) do
    stats = Buffer.stats(Buffer)

    cond do
      fun.(stats) -> stats
      attempts == 0 -> flunk("condition never became true; last stats: #{inspect(stats)}")
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  # "At rest": nothing buffered and nothing in flight, which is when the
  # counters reconcile.
  defp at_rest?(stats) do
    stats.buffered == 0 and stats.accepted == stats.delivered + stats.discarded + stats.lost
  end

  defp settled, do: eventually(&at_rest?/1, attempts: 1_200)

  defp stored_count do
    ClickhouseExLogger.TestServer.query!("SELECT count() FROM logs") |> String.trim()
  end
end
