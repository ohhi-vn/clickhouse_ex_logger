defmodule ClickhouseExLogger.Handler do
  @moduledoc """
  A `:logger` handler that ships log events to ClickHouse.

  ## Setup

  Configure the connection:

      config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
        url: "http://localhost:8123",
        username: "default",
        password: "",
        database: "my_app"

  Create the schema — **before** you attach the handler, so the first flush has
  somewhere to go:

      mix clickhouse_ex_logger.migrate

  Add `ClickhouseExLogger.Repo` to your supervision tree, then install the handler
  once the repo is up:

      def start(_type, _args) do
        children = [ClickhouseExLogger.Repo, ...]

        with {:ok, _pid} <- Supervisor.start_link(children, strategy: :one_for_one) do
          :ok = ClickhouseExLogger.Handler.install(:clickhouse_ex_logger)
          :ok
        end
      end

  Order matters: before the repo is up, early flushes fail and are counted, which
  is safe but noisy.

  ## Why not `config :my_app, :logger`

  You can register the handler declaratively instead:

      config :my_app, :logger,
        handler: [
          {:handler, :clickhouse_ex_logger, ClickhouseExLogger.Handler,
           %{batch_size: 500, flush_interval_ms: 1_000, max_buffer_size: 10_000}}
        ]

  and then call `Logger.add_handlers(:my_app)` from `Application.start/2`.

  Prefer `install/2`. Declarative registration hands the batching config straight
  to `:logger`, which neither validates it nor gives this library a hook to flush
  on removal, so a typo in `:batch_size` surfaces as a misbehaving buffer rather
  than an error at boot, and removing the handler discards whatever was buffered.
  `install/2` does both. See `uninstall/1`.

  ## Configuration

    * `:level` — minimum level to ship. Default `:all`. Must be one of the
      syslog severity atoms `:logger` accepts. `:logger` filters on this before
      `log/2` is called.

    * `:batch_size` — buffered rows that trigger a write. Default `500`. A
      *trigger*, not a cap: a write always takes everything buffered. It cannot
      exceed `:max_buffer_size`; see that option.

    * `:flush_interval_ms` — how often to write a partial batch. Default `1_000`.

    * `:max_buffer_size` — hard cap on buffered rows. Past it the oldest row is
      discarded to make room, so a slow or unreachable ClickHouse costs you the
      oldest logs rather than unbounded memory or a blocked application. Default
      `10_000`.

      This is also the ceiling `:batch_size` is measured against. Set the two
      equal for the smallest batch the buffer can write; set `:batch_size` above
      this and the size trigger can never fire, because the buffer is capped below
      it — every row past the cap is discarded rather than written, and a
      `discarded` count that climbs for that reason is indistinguishable from
      ClickHouse being too slow. `install/2` rejects that combination.

    * `:include_node` — whether each row records the name of the node that handled
      it, e.g. `"my_app@10.0.0.5"`. Default `true`. This is a *handler* option, not
      a batching one, so it does not appear in `Buffer.options()`.

      Turning it off writes no value; it does **not** remove the column. The
      schema is the same either way, so a query written against `node` keeps
      working and turning capture back on needs no migration. The value is also
      absent on a system that is not distributed (`:nonode@nohost`), so filter
      distributed rows with `WHERE node IS NOT NULL`.

  Invalid values (zero, negative, or a non-integer; a non-boolean `:include_node`;
  a `:level` that is not an atom; a `:batch_size` above `:max_buffer_size`) fail
  `install/2` with an error naming the option, rather than failing later during
  event delivery. An unrecognised *option name* is not among them: a key this
  library does not know is passed through to `:logger`, and ignored here.

  ## What it guarantees

    * **It never raises into the caller.** `log/2` runs in the process that
      logged, and that process is none the wiser.
    * **It never blocks.** The row is `cast` to `ClickhouseExLogger.Buffer`; writing
      happens on the buffer's own process.
    * **It never writes a row about itself.** See `ClickhouseExLogger.Event.internal?/1`.
  """

  @behaviour :logger_handler

  require Logger

  alias ClickhouseExLogger.Buffer
  alias ClickhouseExLogger.Event

  @default_batch_size 500
  @default_flush_interval_ms 1_000
  @default_max_buffer_size 10_000

  # `:logger`'s `logger:level()` type, which is the whole of what it will accept
  # for a handler's `:level`.
  @levels ~w(all debug info notice warning error critical alert emergency)a

  @doc """
  The batching defaults applied when a handler config omits them.
  """
  @spec defaults() :: Buffer.options()
  def defaults do
    %{
      batch_size: @default_batch_size,
      flush_interval_ms: @default_flush_interval_ms,
      max_buffer_size: @default_max_buffer_size
    }
  end

  @impl :logger_handler
  def log(event, config) do
    unless internal?(event) do
      # `cast` never waits and never fails, so nothing here can reach the
      # process that logged.
      #
      # The whole handler config is handed to `Event.row/2` rather than just
      # `:include_node`, so an option this module does not know about still
      # reaches row construction instead of being silently dropped.
      event |> Event.row(config) |> Buffer.enqueue(buffer(config))
    end

    :ok
  rescue
    # A `:logger` handler runs in the caller's process. Anything raised here
    # would crash code that was merely trying to log, so a mapping failure is
    # reported and swallowed.
    exception ->
      Logger.error(
        "ClickhouseExLogger: could not queue a log event: #{Exception.message(exception)}",
        clickhouse_ex_logger_internal: true
      )

      :ok
  end

  @doc """
  Validates a handler config and returns the options in it.

  Returns `{:ok, options}` or `{:error, {option, message}}`. Useful on its own for
  checking a `config/*.exs` at boot.
  """
  @spec validate(map() | keyword()) :: {:ok, Buffer.options()} | {:error, {atom(), String.t()}}
  def validate(config) when is_map(config), do: validate(Map.to_list(config))

  def validate(config) when is_list(config) do
    with {:ok, batch_size} <- positive_integer(config, :batch_size, @default_batch_size),
         {:ok, interval} <-
           positive_integer(config, :flush_interval_ms, @default_flush_interval_ms),
         {:ok, max} <- positive_integer(config, :max_buffer_size, @default_max_buffer_size),
         :ok <- validate_level(config),
         :ok <- validate_batch_fits_buffer(batch_size, max) do
      {:ok, %{batch_size: batch_size, flush_interval_ms: interval, max_buffer_size: max}}
    end
  end

  @doc """
  Starts the buffer, registers the handler, and returns `{:ok, handler_id}`.

  Idempotent in the parts that matter: an already-running buffer is reused rather
  than duplicated, and an already-registered `handler_id` is not registered
  twice.

  All-or-nothing. Every option is validated before anything is started, and if
  `:logger` still refuses the registration the buffer this call started is stopped
  again — a rejected registration leaves no batching machinery behind. A buffer
  that was already running when the call arrived is never stopped, because this
  call did not start it.

  Fails with `{:error, {option, message}}` if the handler config is invalid, and
  with whatever `:logger` returns if it refuses the registration.
  """
  @spec install(atom(), map() | keyword()) ::
          {:ok, atom()} | {:error, {atom(), String.t()}} | {:error, term()}
  def install(handler_id, config \\ %{}) when is_atom(handler_id) do
    with {:ok, options} <- validate(config),
         :ok <- validate_include_node(config),
         {:ok, started?} <- ensure_buffer_started(options) do
      case register(handler_id, config) do
        {:ok, handler_id} ->
          {:ok, handler_id}

        {:error, _reason} = error ->
          # `:logger` rejected the handler. Undo the one effect this call had, and
          # only that one — a buffer already running belongs to whoever started it.
          if started?, do: Buffer.stop()
          error
      end
    end
  end

  @doc """
  Removes the handler and flushes whatever is still buffered.

  This is the counterpart to `install/2`. Removal is ordered so no event is
  accepted after the flush starts: the handler comes off first, then the buffer
  drains, then the buffer stops.

  Returns `:ok` even if the handler was not registered, so it is safe to call
  from a shutdown path unconditionally.

  Both waits are bounded and the row accounting happens where the rows are: the
  flush's own timeout means it may return without having drained, and this
  function cannot tell — `Buffer.flush/2` answers `:ok` either way. So nothing is
  decided from that `:ok`. `Buffer.stop/3` runs the buffer's `terminate/2`, which
  waits for any outstanding write and makes one final bounded attempt within a
  fixed budget, and that is the step which decides what happens to rows still
  held. No branch is needed here for a flush that did not finish, because there is
  nothing further this function could do about it.
  """
  @spec uninstall(atom()) :: :ok
  def uninstall(handler_id) do
    _ = remove(handler_id)

    case GenServer.whereis(Buffer) do
      nil ->
        :ok

      _pid ->
        # A bounded wait: draining must not hang a shutdown behind an
        # unresponsive ClickHouse.
        _ = Buffer.flush(Buffer, 5_000)
        Buffer.stop()
        :ok
    end
  end

  @doc """
  Validates the node-capture option, which `validate/1` deliberately ignores.

  Kept separate because `:include_node` is not a batching concern — it decides
  whether a row records a value, and the buffer never sees it. Folding it into
  `Buffer.options()` would widen a type whose only job is sizing a buffer.

  Returns the same `{:error, {option, message}}` shape as `validate/1`, so a host
  sees one consistent failure format whichever option is wrong. An option that is
  present but not a boolean is rejected rather than coerced: `include_node: "no"`
  silently reading as enabled would be worse than failing at install.
  """
  @spec validate_include_node(map() | keyword()) :: :ok | {:error, {atom(), String.t()}}
  def validate_include_node(config) do
    case fetch(config, :include_node, true) do
      value when is_boolean(value) ->
        :ok

      value ->
        {:error, {:include_node, ":include_node must be a boolean, got: #{inspect(value)}"}}
    end
  end

  @doc """
  Ensures the buffer is running with the given batching options.

  Idempotent: if a buffer is already up it is left alone, so a host that both
  supervises `ClickhouseExLogger.Buffer` and installs the handler does not end up
  with two writers.

  Returns `{:ok, started?}`, where `started?` is `true` when *this call* started
  the buffer. `install/2` needs that to undo only its own effect if registration
  then fails, and cannot get it from `GenServer.whereis/1` — by then it cannot
  tell a buffer it started from one that was already there.
  """
  @spec ensure_buffer_started(map() | keyword()) :: {:ok, boolean()} | {:error, term()}
  def ensure_buffer_started(config) do
    case GenServer.whereis(Buffer) do
      nil ->
        case validate(config) do
          {:ok, options} ->
            # No `{:error, {:already_started, _pid}}` clause: the `whereis` above
            # checked microseconds ago, and losing that race is harmless — the
            # buffer another caller started is serving the same rows. The
            # `started?` it would have reported is `false`, which is also right:
            # this call did not start it.
            case Buffer.start_link(options) do
              {:ok, _pid} -> {:ok, true}
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            error
        end

      _pid ->
        {:ok, false}
    end
  end

  # The buffer a row should go to. A host that runs its own buffer can route rows to
  # it by setting `:buffer` in the handler's config — and the value must be a **pid**,
  # not a registered name. A name is silently ignored and rows go to the default
  # buffer, which is worse than rejecting it: the host's own buffer stays empty and
  # nothing says why. `GenServer.cast/2` takes either, so this narrows what the
  # option accepts rather than what works.
  defp buffer(%{buffer: pid}) when is_pid(pid), do: pid
  defp buffer(_config), do: Buffer

  defp internal?(event), do: Event.internal?(event)

  defp register(handler_id, config) do
    given = Map.new(config)

    handler_config =
      Map.merge(given, %{
        module: __MODULE__,
        level: Map.get(given, :level, :all),
        filter_default: :log,
        formatter: Map.get(given, :formatter, Logger.Formatter.new())
      })

    case :logger.add_handler(handler_id, __MODULE__, handler_config) do
      :ok -> {:ok, handler_id}
      {:error, {:already_exist, ^handler_id}} -> {:ok, handler_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove(handler_id) do
    :logger.remove_handler(handler_id)
  end

  # Every level `:logger` accepts, per its `logger:level()` type. Checking membership
  # here rather than passing the value through is what makes a bad level an error
  # naming the option, like every other one — `:logger` reports it as
  # `{:error, {:invalid_level, value}}`, which names neither the option this
  # library documents nor the fact that the host set it. An `is_atom/1` check
  # would not do either: `nil`, `true` and `false` are atoms and none of them is a
  # level.
  defp validate_level(config) do
    case fetch(config, :level, :all) do
      value when value in @levels ->
        :ok

      value ->
        {:error, {:level, ":level must be one of #{inspect(@levels)}, got: #{inspect(value)}"}}
    end
  end

  # `Buffer` caps its queue at `max_buffer_size`, dropping the oldest row to make
  # room. So a `batch_size` above that cap is a size trigger that can never fire:
  # the queue is held below it, and every row past the cap is discarded for a
  # reason that has nothing to do with ClickHouse. In a `discarded` count that is
  # indistinguishable from the database being too slow, which is the one thing the
  # counter has to be able to tell a host.
  #
  # Equal is fine — that is a host asking for the smallest batch it can get, and
  # the trigger still fires.
  defp validate_batch_fits_buffer(batch_size, max)
       when batch_size > max do
    {:error,
     {:batch_size,
      ":batch_size (#{batch_size}) cannot exceed :max_buffer_size (#{max}); " <>
        "the buffer is capped at :max_buffer_size, so the batch trigger could never " <>
        "fire and rows would be discarded rather than written"}}
  end

  defp validate_batch_fits_buffer(_batch_size, _max), do: :ok

  defp positive_integer(config, key, default) do
    case fetch(config, key, default) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value ->
        {:error, {key, "#{key} must be a positive integer, got: #{inspect(value)}"}}
    end
  end

  defp fetch(config, key, default) when is_list(config), do: Keyword.get(config, key, default)
  defp fetch(config, key, default) when is_map(config), do: Map.get(config, key, default)
end
