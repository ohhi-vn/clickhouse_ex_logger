defmodule ClickhouseExLogger.HandlerInstaller do
  @moduledoc """
  Attaches the `:logger` handler when the library starts itself.

  One child of `ClickhouseExLogger.Application`, started after the connection and
  the buffer. It exists to answer two questions the automatic start has to answer
  before `ClickhouseExLogger.Handler.install/2` can be called, and to undo the
  attachment in the right order when the host shuts down.

  You do not use this module. `ClickhouseExLogger.Handler.install/2` is the
  operation; this is the caller that runs it at boot. Set
  `config :clickhouse_ex_logger, auto_start: false` and it never runs at all.

  ## Why it is a `GenServer` that stays alive

  Children terminate in the reverse of the order they started, so this being last
  in the list is what makes shutdown come out right: the handler comes off before
  the buffer drains, and the connection closes last. `Handler.uninstall/1`
  performs that same order by hand; here the supervisor does it.

  Which means this process has to still be *alive* at shutdown to have its
  `terminate/1` run — which is why it does not exit after attaching. A detached
  task would be tidier and would silently lose the ordering.

  Its `terminate/1` calls `ClickhouseExLogger.Handler.uninstall/1`, so the shutdown
  sequence is the library's existing one rather than a second implementation of
  it. See that function's own documentation for why the drain has to happen here
  rather than in the buffer's `terminate/2`.

  ## Why the work happens in `handle_continue/2`

  `init/1` returns immediately and the check runs in `handle_continue/2`, so a
  ClickHouse that is slow or absent adds nothing to a host's boot. The check runs
  in a `Task` for a second reason: `install/2` guarantees it performs no network
  work, and that guarantee is worth keeping true of the process that calls it
  rather than only of a human reading the docs.

  ## When the table is not there

  `ClickhouseExLogger.Migration.logs_table_status/0` answers `:present`,
  `:absent`, or `:unreachable`. Only `:absent` stops the attachment, and it is
  the one case where stopping is right: the host has not created the schema, and
  attaching anyway would turn a missing table into a rising `lost` count that is
  indistinguishable from a ClickHouse outage.

  `:unreachable` attaches anyway. A server that is briefly down at boot must not
  leave the host without log capture until its next restart — and delivery
  failures are already reported and counted per
  `ClickhouseExLogger.Handler`'s failure handling.
  """

  use GenServer

  require Logger

  alias ClickhouseExLogger.{Handler, Migration}

  @handler_id :clickhouse_ex_logger

  # How long to wait for the readiness answer before giving up on it and
  # attaching anyway.
  #
  # The query inside is already bounded at 2s
  # (`ClickhouseExLogger.Migration.logs_table_status/0`), so this is only
  # headroom for the Task to report — not a second, longer deadline. It has to
  # stay under the buffer's own 5s shutdown budget, because a `GenServer` blocked
  # in `handle_continue/2` does not run the `terminate/1` that removes the
  # handler.
  @readiness_budget 3_000

  @doc """
  Starts the installer. `config` is the handler configuration to install with.
  """
  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Blocks until the automatic start has decided whether to attach, and returns that
  decision.

  `:attached`, or `:not_attached` when the handler was deliberately left off —
  which happens when the `logs` table is missing. Returns `{:error, :timeout}` if
  the installer has not answered within `timeout`.

  The wait is a real barrier rather than a poll. The startup work runs in
  `handle_continue/2`, and a `GenServer` processes messages in order, so a message
  sent after the continue has begun cannot be handled until the continue returns.
  Polling `:logger` for the handler instead could not tell "not attached yet" from
  "not attached on purpose", which is the distinction this function exists to
  report.

  Useful to a host that wants to know whether logging is live before it serves
  traffic, and to this library's own tests.
  """
  @spec await_attach(timeout()) :: :attached | :not_attached | {:error, :timeout}
  def await_attach(timeout \\ 5_000) do
    ref = make_ref()

    if request_decision(ref) do
      receive do
        {^ref, decision} -> decision
      after
        timeout -> {:error, :timeout}
      end
    else
      {:error, :timeout}
    end
  end

  # `false` when nothing is installing: the name is unregistered, so the send has
  # no destination. No decision is coming and waiting cannot produce one, so this
  # answers the same as a timeout rather than raising at the caller — which is the
  # whole point of asking.
  defp request_decision(ref) do
    send(__MODULE__, {:await_attach, self(), ref})
    true
  rescue
    ArgumentError -> false
  end

  @impl GenServer
  def init(config) do
    # Trapped so `terminate/1` runs on a supervisor shutdown, which is a normal
    # exit signal rather than a kill.
    Process.flag(:trap_exit, true)

    {:ok, %{config: config, attached: nil}, {:continue, :attach}}
  end

  @impl GenServer
  def handle_continue(:attach, state) do
    {:noreply, %{state | attached: attach(state.config)}}
  end

  @impl GenServer
  def handle_info({:await_attach, pid, ref}, state) do
    send(pid, {ref, state.attached || :not_attached})

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    # `Handler.uninstall/1` rather than a reimplementation of it: it already is
    # this exact sequence — handler off, bounded flush, stop the buffer — in this
    # exact order, and it is the sequence this library documents and tests for the
    # explicit path.
    #
    # The ordering comes from where this process sits: it is the last child
    # started, so it is the first terminated. The buffer is therefore still up
    # here, and still has its rows.
    #
    # Doing this rather than removing the handler alone is deliberate. A
    # supervisor shuts a child down with an exit *signal*, and a process that does
    # not trap exits dies on the spot — so `ClickhouseExLogger.Buffer`'s
    # `terminate/2`, where its bounded final write lives, never runs for a
    # supervised buffer. Draining here is what keeps that write reachable; the
    # buffer's own `terminate/2` then finds nothing left to do.
    #
    # The result is ignored. `:logger` answers for a handler that was never
    # registered, `Buffer.flush/2` answers `:ok` whether or not it drained, and
    # `Buffer.stop/1` swallows its own timeout. This runs on a shutdown path where
    # there is nothing useful to do with a failure — and the rows that could not be
    # delivered are counted as lost where they are counted, by the buffer.
    _ = Handler.uninstall(@handler_id)

    :ok
  end

  defp attach(config) do
    case readiness() do
      :present ->
        install(config)

      :unreachable ->
        # Not a reason to withhold log capture. Say so once, so an operator
        # reading a `lost` count knows the server was already unreachable at boot
        # rather than having gone away afterwards.
        Logger.error(fn ->
          "ClickhouseExLogger: ClickHouse did not answer at startup, so the " <>
            "`logs` table could not be checked. Attaching the handler anyway; " <>
            "delivery failures are reported and counted until it recovers."
        end)

        install(config)

      :absent ->
        Logger.error(fn ->
          "ClickhouseExLogger: the `logs` table does not exist in #{database()}, " <>
            "so the handler was not attached and nothing is being shipped to " <>
            "ClickHouse. Create the table, then restart: " <>
            "`mix clickhouse_ex_logger.migrate`, or " <>
            "`ClickhouseExLogger.Utils.migrate()` from a release. " <>
            "See ClickhouseExLogger.Migration."
        end)

        :not_attached
    end
  end

  defp readiness do
    # In a Task, so that the process calling `install/2` below — for which
    # "no network or database work" is a guarantee this library documents — has
    # not itself touched the database.
    task = Task.async(fn -> Migration.logs_table_status() end)

    case Task.yield(task, @readiness_budget) do
      {:ok, answer} ->
        answer

      {:exit, reason} ->
        Logger.error(fn ->
          "ClickhouseExLogger: the startup check for the `logs` table exited " <>
            "without an answer (#{inspect(reason)}). Attaching the handler anyway."
        end)

        :unreachable

      nil ->
        # Bounded, so a server that accepts the connection and then stops
        # responding cannot hold up a boot indefinitely.
        _ = Task.shutdown(task, :brutal_kill)

        Logger.error(fn ->
          "ClickhouseExLogger: the startup check for the `logs` table did not " <>
            "answer within #{@readiness_budget}ms. Attaching the handler anyway."
        end)

        :unreachable
    end
  end

  # One failure branch, not one per reason shape, and the reason is reported as
  # `install/2` returned it.
  #
  # Splitting these would misreport. `Handler.install/2` answers `{:error,
  # {option, message}}` for an option this library validates, but `:logger`'s own
  # rejections arrive in the same shape — a bad formatter is
  # `{:invalid_formatter, value}` — so matching on the tuple would present a
  # logging-system internal as one of this library's documented options, and tell
  # the host to change something that is not theirs to change. Inspecting the
  # reason shows both cases correctly, and `install/2`'s own return value is
  # where a caller that wants the option name precisely gets it.
  defp install(config) do
    case Handler.install(@handler_id, config) do
      {:ok, @handler_id} ->
        :attached

      {:error, reason} ->
        # Reported and swallowed, deliberately. The host's application is already
        # up by the time this runs, so failing the tree here would take the host
        # down over a logging option — and `install/2` has already rolled back
        # whatever it started, so there is nothing to clean up.
        Logger.error(fn ->
          "ClickhouseExLogger: could not attach the log handler: #{inspect(reason)}. " <>
            "Log events are not being shipped."
        end)

        :not_attached
    end
  end

  defp database do
    ClickhouseExLogger.Repo.database() || "the configured database"
  rescue
    # `Repo.database/0` reads the host's configuration, which is exactly what the
    # missing-table branch is usually about. An unreadable or absent value must
    # not stop the message that explains the problem from being logged.
    AshClickhouse.Error.ConfigurationError -> "the configured database"
  end
end
