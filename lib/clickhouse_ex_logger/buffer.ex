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
  running and accepting rows. See the module doc for the rest.

  Returns zeroed counters rather than raising when the buffer is not running, so
  an operator's dashboard does not go down with the logger.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server \\ @name) do
    GenServer.call(server, :stats)
  catch
    :exit, _reason -> empty_stats()
  end

  @doc """
  Writes everything buffered and waits for it to land.

  Bypasses the batching triggers, so it writes whatever is buffered even if
  `batch_size` was not reached. Used when the handler is removed, so that logs
  already accepted are not silently thrown away, and by tests.

  Returns `:ok` once the buffer is empty and no write is outstanding.
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
      |> Map.merge(%{write_ref: nil, in_flight: 0})
      |> flush_now()

    {:noreply, schedule_flush(reply_when_drained(state))}
  end

  # `spawn_monitor/1` also delivers a `:DOWN` for every write. The result message
  # already told us everything we need, so ignore the monitor notification.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{write_ref: ref} = state) do
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # One last attempt at whatever is buffered. Bounded, because
    # `GenServer.stop/3` waits for this and its default timeout is `:infinity`:
    # an unbounded write here means shutdown hangs behind an unresponsive
    # ClickHouse for as long as the insert takes.
    #
    # A `:brutal_kill` skips this, which is the one acceptable way to lose rows.
    case pending_rows(state) do
      [] -> :ok
      rows -> bounded_flush(rows)
    end

    :ok
  end

  # `bulk_create/1` swallows its own failures, so the result is not interesting —
  # only whether it came back before the budget ran out. Rows written after the
  # budget expires are lost, which `Handler.uninstall/1`'s own flush has already
  # counted by the time it gets here.
  defp bounded_flush(rows) do
    parent = self()
    ref = make_ref()

    spawn_monitor(fn -> send(parent, {ref, bulk_create(rows)}) end)

    receive do
      {_ref, _result} -> :ok
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

        {_pid, _monitor_ref} =
          spawn_monitor(fn -> send(parent, {ref, bulk_create(rows)}) end)

        %{state | rows: :queue.new(), write_ref: ref, in_flight: length(rows)}
    end
  end

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
end
