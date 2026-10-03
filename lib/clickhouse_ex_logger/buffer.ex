defmodule ClickhouseExLogger.Buffer do
  @moduledoc """
  Accumulates log rows and writes them to ClickHouse in batches.

  Started by `ClickhouseExLogger.Handler`. One process owns the whole batching
  state — the pending rows, the flush timer, and the counters — so there is a
  single place where the buffer's invariants hold.

  ## Invariants

    * **Callers never block or fail.** The handler `cast`s; this process is the
      only one that ever talks to ClickHouse. A caller never learns whether the
      write worked, and never waits for it.
    * **At most one write is in flight.** Rows are appended to a FIFO and
      flushed front-first, so every write is a contiguous run of the logged
      sequence and successive writes are ordered.
    * **The buffer is bounded.** Past `max_buffer_size` the *oldest* row is
      dropped to admit the newest: for log data, the newest events are the ones
      that explain a live incident. Drop-oldest also makes the loss visible and
      attributable instead of silently unbounded.
    * **Nothing is retried.** A failed batch is discarded and counted. A log
      pipeline that queues behind an unreachable database turns a downstream
      outage into an upstream memory leak.

    * **A write is always accounted for.** A batch is tallied when the insert
      reports an outcome *or* when the process performing it dies without
      reporting one. The second case is not hypothetical: the `clickhouse` client
      raises from inside a query for some responses, and those raises escape the
      data layer's rescue. A buffer that waited for a result that was never coming
      would stop writing entirely while still reporting itself active, so the
      monitor that reports the write's death is handled as a failed flush.

  ## `batch_size` is a trigger, not a cap

  When the buffer reaches `batch_size` rows, or the flush interval elapses,
  *everything* buffered is written in one insert. A write that takes longer than
  the interval lets rows pile up, and the next write takes all of them rather
  than leaving a remainder behind.

  ## Counters

  See `stats/1`. They reconcile: `accepted == delivered + discarded + lost`, once
  nothing is in flight.

  `discarded` and `lost` are both loss, with different causes — the buffer was
  full, or ClickHouse would not take the rows. `failed` counts *flushes*, not
  rows: one bad batch is one failure regardless of how many rows it held, so it
  cannot be used to work out how much was lost.
  """

  use GenServer

  require Logger

  @typedoc "Runtime counters, as returned by `stats/1`."
  @type stats :: %{
          accepted: non_neg_integer(),
          delivered: non_neg_integer(),
          discarded: non_neg_integer(),
          lost: non_neg_integer(),
          failed: non_neg_integer(),
          buffered: non_neg_integer(),
          active?: boolean()
        }

  @typedoc "Batching options, as configured on the handler."
  @type options :: %{
          batch_size: pos_integer(),
          flush_interval_ms: pos_integer(),
          max_buffer_size: pos_integer()
        }

  @name __MODULE__

  # How long the final write in `terminate/2` may take. A flush takes everything
  # buffered, and `Insert` chunks at 1000 rows, so against a stalled ClickHouse
  # one shutdown write is up to `max_buffer_size / 1000` chunks at the client's
  # 15s `recv_timeout` each — minutes of blocked shutdown. This is the same
  # budget `ClickhouseExLogger.Handler.uninstall/1` already gives its own flush.
  @shutdown_flush_timeout 5_000

  @doc """
  Starts the buffer with the given batching `options`.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: @name)
  end

  @doc """
  Hands a row to the buffer without waiting.

  Never blocks and never fails: if the buffer is not running the row is dropped,
  because losing a log row is always better than failing the process that logged
  it. No guard is needed for that — `GenServer.cast/2` returns `:ok` for an
  absent or already-dead server and never exits.

  `server` defaults to the buffer the handler starts.
  """
  @spec enqueue(ClickhouseExLogger.Event.row(), GenServer.server()) :: :ok
  def enqueue(row, server \\ @name) do
    GenServer.cast(server, {:enqueue, row})
  end

  @doc """
  Returns the current counters.

  `active?` is `true` whenever this call succeeds, i.e. whenever the buffer is
  running and accepting rows.

  Returns zeroed counters with `active?: false` when the buffer is not running, so
  an operator's dashboard does not go down with the logger. It does **not** report
  that for a buffer that exists but did not answer in time: a timeout means the
  process is there and busy, and marking it inactive would tell an operator a
  delivering system is idle. The counters read zero in that case because they could
  not be read at all — treat `active?: true` with all-zero counters as "ask again",
  not as "nothing has happened".

  See the module doc for the rest.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server \\ @name) do
    GenServer.call(server, :stats)
  catch
    # The call timed out. `GenServer.call/3` wraps the call it gave up on, so this
    # is the one reason that means "the server is there and did not answer" rather
    # than "there is no server". See the `@doc`.
    :exit, {:timeout, _call} -> unanswered_stats()
    # `:noproc`, a server that exited normally, one that crashed — in every case
    # there is no buffer to ask.
    :exit, _reason -> empty_stats()
  end

  @doc """
  Writes everything buffered and waits for it to land.

  Bypasses the batching triggers, so it writes whatever is buffered even if
  `batch_size` was not reached. Used when the handler is removed, so that logs
  already accepted are not silently thrown away, and by tests.

  Returns `:ok` once the buffer is empty and no write is outstanding — **or** once
  the call's own `timeout` ran out, because the two are not distinguishable from
  the return value. This function is therefore not a way to ask whether the buffer
  drained. What decides the fate of rows still held is `terminate/2`, which every
  stop passes through: it waits for any outstanding write and makes one final
  bounded attempt, within a fixed budget.
  """
  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(server \\ @name, timeout \\ 5_000) do
    GenServer.call(server, :flush, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Stops the buffer after a final flush.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ @name) do
    GenServer.stop(server, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(options) do
    state = %{
      options: options,
      rows: :queue.new(),
      timer: nil,
      write_ref: nil,
      write_monitor: nil,
      in_flight: 0,
      waiting: [],
      accepted: 0,
      delivered: 0,
      discarded: 0,
      lost: 0,
      failed: 0
    }

    {:ok, schedule_flush(state)}
  end

  @impl GenServer
  def handle_cast({:enqueue, row}, state) do
    state =
      state
      |> put_row(row)
      |> maybe_start_write()
      |> schedule_flush()

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, counters(state), state}
  end

  def handle_call(:flush, from, state) do
    state =
      state
      |> flush_now()
      |> Map.update!(:waiting, &[from | &1])

    {:noreply, reply_when_drained(state)}
  end

  @impl GenServer
  def handle_info(:flush_interval, state) do
    state =
      state
      |> Map.put(:timer, nil)
      |> flush_now()

    {:noreply, schedule_flush(state)}
  end

  def handle_info({ref, result}, %{write_ref: ref} = state) do
    # `tally/2` reads `in_flight`, so it has to run before the counter is
    # cleared.
    state =
      state
      |> tally(result)
      |> clear_write()
      |> flush_now()

    {:noreply, schedule_flush(reply_when_drained(state))}
  end

  # A write that died without sending a result. Nothing is known to have been
  # committed, so the whole batch is lost — but it is lost *accounted*, and the
  # buffer returns to service.
  #
  # This is the case `spawn_monitor/1` exists to report, and it is reachable in
  # production: `clickhouse` 0.32.0 raises from inside a query for a response its
  # error-type lookup does not recognise, and names an undefined
  # `ClickHouse.NetworkError` struct for `DB::NetException` bodies. Neither raise
  # is in `AshClickhouse.Connection`'s rescue list, so both escape the insert and
  # kill the process performing it.
  #
  # Matching on `write_monitor` and not on `write_ref` is what makes this clause
  # reachable at all. `spawn_monitor/1`'s ref and the `make_ref/0` used to
  # correlate the result are *different* references — they agreed only because
  # the monitor ref was discarded — so a real `:DOWN` never matched the write it
  # belonged to, and the buffer waited forever for a message that was never coming.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{write_monitor: ref} = state) do
    state =
      state
      |> tally({:error, crash_reason(reason), 0})
      |> clear_write()
      |> flush_now()

    {:noreply, schedule_flush(reply_when_drained(state))}
  end

  # Every other message. A `:DOWN` whose write already reported normally is one
  # of these: the result message always precedes it from the same process, so
  # `clear_write/1` has already run and there is nothing left to account.
  def handle_info(_message, state), do: {:noreply, state}

  # A process killed by an uncaught error exits with `{error, stacktrace}` — but
  # `error` is not always an exception struct. Elixir translates a raise into an
  # `:erlang.error` and the process then dies with the Erlang reason, so
  # `Map.update!/3` on a missing key gives `{{:badkey, key, map}, stacktrace}`
  # rather than a `KeyError`. Both shapes have to read sensibly, and the
  # stacktrace is noise in a message an operator reads.
  defp crash_reason({error, stacktrace}) when is_list(stacktrace),
    do: format_error(error)

  defp crash_reason(reason), do: inspect(reason)

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error({:badkey, key}), do: "key #{inspect(key)} not found"
  defp format_error({:badkey, key, _map}), do: "key #{inspect(key)} not found"
  defp format_error(error), do: inspect(error)

  @impl GenServer
  def terminate(_reason, state) do
    # One last attempt at whatever is buffered, and it must not be a *second*
    # write. Bounded, because `GenServer.stop/3` waits for this and its default
    # timeout is `:infinity`: an unbounded write here means shutdown hangs behind
    # an unresponsive ClickHouse for as long as the insert takes.
    #
    # A `:brutal_kill` skips this, which is the one acceptable way to lose rows.
    #
    # A write already under way owns whatever happens next. `terminate/2` cannot
    # learn its outcome — the process is about to stop, so nothing will ever
    # `tally/2` it — and starting a second insert alongside it would break the one
    # invariant that makes the ordering guarantee mean anything: at most one write
    # outstanding, including at shutdown. So the queued rows wait for the
    # outstanding write and are written by nothing if it does not finish. They are
    # lost, and `Handler.uninstall/1`'s own flush has already accounted for what it
    # could before reaching here.
    case state.write_ref do
      nil -> bounded_flush(pending_rows(state))
      ref -> await_write(ref)
    end

    :ok
  end

  # Waits for a write this process started and will never hear the result of. The
  # receive is ref-matched: a bare two-element pattern would be satisfied by an
  # unrelated message in the mailbox — a concurrent `{:enqueue, row}` cast among
  # them — and return while the write was still running.
  defp await_write(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      @shutdown_flush_timeout -> :ok
    end
  end

  # `bulk_create/1` swallows its own failures, so the result is not interesting —
  # only whether it came back before the budget ran out. Rows written after the
  # budget expires are lost.
  defp bounded_flush([]), do: :ok

  defp bounded_flush(rows) do
    parent = self()
    ref = make_ref()

    spawn_monitor(fn -> send(parent, {ref, bulk_create(rows)}) end)

    receive do
      {^ref, _result} -> :ok
    after
      @shutdown_flush_timeout -> :ok
    end
  end

  # --- writes ------------------------------------------------------------

  defp maybe_start_write(state) do
    if state.write_ref == nil and :queue.len(state.rows) >= state.options.batch_size do
      start_write(state)
    else
      state
    end
  end

  defp flush_now(state) do
    if state.write_ref == nil do
      start_write(state)
    else
      state
    end
  end

  defp start_write(state) do
    case pending_rows(state) do
      [] ->
        state

      rows ->
        parent = self()
        ref = make_ref()

        {_pid, monitor} = spawn_monitor(fn -> send(parent, {ref, bulk_create(rows)}) end)

        %{
          state
          | rows: :queue.new(),
            write_ref: ref,
            write_monitor: monitor,
            in_flight: length(rows)
        }
    end
  end

  # `tally/2` reads `in_flight`, so every path that ends a write clears the
  # bookkeeping only after it has accounted for the rows.
  defp clear_write(state),
    do: Map.merge(state, %{write_ref: nil, write_monitor: nil, in_flight: 0})

  defp pending_rows(state), do: state.rows |> :queue.to_list()

  defp bulk_create(rows), do: ClickhouseExLogger.Insert.insert(rows)

  defp tally(state, {:ok, committed}) do
    %{state | delivered: state.delivered + committed, lost: state.lost + lost(state, committed)}
  end

  defp tally(state, {:error, reason, committed}) do
    # The marker keeps this report out of the `logs` table, so a ClickHouse
    # outage cannot feed itself.
    Logger.error(
      "ClickhouseExLogger: dropped #{lost(state, committed)} buffered log row(s); " <>
        "the ClickHouse insert failed: #{reason}",
      clickhouse_ex_logger_internal: true
    )

    %{
      state
      | delivered: state.delivered + committed,
        lost: state.lost + lost(state, committed),
        failed: state.failed + 1
    }
  end

  # Any result shape the writer was not contracted to produce. Counted as a failed
  # flush with nothing committed, so the batch lands in `lost` and the buffer keeps
  # running.
  #
  # `Insert.insert/1`'s corrected contract makes this unreachable, which is the
  # point of correcting it. The alternative is not unreachable at all: a clause
  # that does not match raises inside the only process that writes logs, and a
  # crash there discards everything buffered behind it without counting a row. The
  # buffer's job is to survive the writer, not to audit it.
  defp tally(state, unexpected) do
    tally(state, {:error, "unexpected insert result: #{inspect(unexpected)}", 0})
  end

  # One flush is several inserts, and the ones before a failure are already
  # committed. Anything the flush did not get accepted is lost, whichever
  # outcome it reported.
  defp lost(state, committed), do: state.in_flight - committed

  # --- buffer ------------------------------------------------------------

  defp put_row(state, row) do
    %{state | rows: :queue.in(row, state.rows), accepted: state.accepted + 1}
    |> enforce_max_buffer()
  end

  defp enforce_max_buffer(state) do
    max = state.options.max_buffer_size

    if :queue.len(state.rows) > max do
      {{:value, _dropped}, rows} = :queue.out(state.rows)
      %{state | rows: rows, discarded: state.discarded + 1}
    else
      state
    end
  end

  # --- timer and waiting callers ----------------------------------------

  defp schedule_flush(%{timer: timer} = state) when not is_nil(timer), do: state

  defp schedule_flush(state) do
    %{state | timer: Process.send_after(self(), :flush_interval, state.options.flush_interval_ms)}
  end

  defp reply_when_drained(state) do
    if state.write_ref == nil and :queue.is_empty(state.rows) do
      Enum.each(state.waiting, &GenServer.reply(&1, :ok))
      %{state | waiting: []}
    else
      state
    end
  end

  defp counters(state) do
    %{
      accepted: state.accepted,
      delivered: state.delivered,
      discarded: state.discarded,
      lost: state.lost,
      failed: state.failed,
      buffered: :queue.len(state.rows),
      active?: true
    }
  end

  defp empty_stats do
    %{
      accepted: 0,
      delivered: 0,
      discarded: 0,
      lost: 0,
      failed: 0,
      buffered: 0,
      active?: false
    }
  end

  # The buffer is running but did not answer within the call's timeout. The
  # counters are unknown rather than zero, and there is no value for "unknown" in
  # this map, so they read zero. `active?: true` is the load-bearing part: it is
  # what separates "delivering, ask again" from "never started".
  defp unanswered_stats, do: %{empty_stats() | active?: true}
end
