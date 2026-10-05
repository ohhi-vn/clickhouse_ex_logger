defmodule ClickhouseExLogger.Application do
  @moduledoc """
  Starts the pipeline when the `:clickhouse_ex_logger` application starts.

  This is why a host does not write any code to ship its logs. Declaring the
  dependency and configuring the connection is the whole setup: Mix starts this
  application along with the host's own, this supervises the ClickHouse
  connection and the buffer, and `ClickhouseExLogger.HandlerInstaller` attaches
  the handler.

  ## The children

  In start order:

    1. `ClickhouseExLogger.Repo` — the ClickHouse connection.
    2. `ClickhouseExLogger.Buffer` — with the host's configured batching options.
    3. `ClickhouseExLogger.HandlerInstaller` — attaches the handler.

  Termination is the reverse, which is the order that matters: the handler stops
  receiving events, then the buffer makes one bounded final attempt at writing
  what it holds, then the connection closes.

  ## Configuration

      config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
        url: "http://localhost:8123",
        username: "default",
        password: "",
        database: "my_app"

      config :clickhouse_ex_logger, handler: [level: :info, batch_size: 500]

  `:handler` takes the same options `ClickhouseExLogger.Handler.install/2`
  documents, and rejects the same values for the same reasons.

  ## `:auto_start`

      config :clickhouse_ex_logger, auto_start: false

  Set this when your application supervises `ClickhouseExLogger.Repo` itself.

  It is not a preference — it is a requirement in that case. A ClickHouse client
  binds to a database for the life of its connection and keeps a globally named
  ETS table, so a second connection under the same name cannot be started: the
  client raises `ArgumentError: table name already exists` from inside the new
  process, and your supervisor fails to start. Disabling the automatic start is
  what stops this library from starting the connection your supervision tree also
  starts.

  ## When the connection is not configured

  The start fails, naming the key you are missing. `ClickhouseExLogger.Repo`
  deliberately raises rather than falling back to a default destination, and a
  supervisor that cannot start a child terminates the ones it already started, so
  a rejected configuration leaves nothing running.

  ## What this does not do

  It creates and alters no ClickHouse schema. Creating the schema is
  `mix clickhouse_ex_logger.migrate` (or `ClickhouseExLogger.Utils.migrate/1`
  from a release), which you run once, before starting. See
  `ClickhouseExLogger.HandlerInstaller` for what the start path does read.
  """

  use Application

  alias ClickhouseExLogger.{Buffer, Handler}

  @doc """
  Starts the pipeline, or nothing at all when `auto_start: false`.

  Options are read from the application environment, not from the host's
  arguments, because the host passes none: the OTP application callback receives
  `[]`.
  """
  @impl Application
  @spec start(Application.start_type(), term()) ::
          {:ok, pid()} | {:ok, pid(), term()} | {:error, term()}
  def start(_type, _args) do
    case build() do
      {:ok, children} ->
        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: ClickhouseExLogger.Supervisor,
          # The buffer's own `terminate/2` is what bounds the final drain, and the
          # installer's readiness check is bounded well inside this. Nothing here
          # should need longer than the defaults to finish shutting down.
          shutdown: 15_000
        )

      # Reported rather than raised, so the host's boot failure names the option it
      # got wrong instead of surfacing a supervisor error about a child spec.
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The children this application starts, in order.

  Public so a test can start the same tree under `start_supervised!/1` without
  going through the application lifecycle — which it must, because a second
  connection cannot be started in one VM.

  Raises when the configuration is invalid, which `start/2` reports as an error
  instead. Both come from `build/0`; they differ only in how a caller learns
  about it.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term() | [term()]}]
  def children do
    case build() do
      {:ok, children} ->
        children

      {:error, {option, message}} ->
        raise ArgumentError,
              "ClickhouseExLogger: invalid :handler configuration — " <>
                "#{inspect(option)}: #{message}"
    end
  end

  @doc """
  Whether the pipeline starts itself. Defaults to `true`.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:clickhouse_ex_logger, :auto_start, true) != false
  end

  @doc """
  The handler configuration, as the host stated it. Empty by default.
  """
  @spec handler_config() :: map() | keyword()
  def handler_config do
    Application.get_env(:clickhouse_ex_logger, :handler, [])
  end

  # `Buffer.start_link/1` does not validate, so the options the buffer is started
  # with are validated here, before the tree exists. An invalid value therefore
  # fails the application start with an error naming the option, and the
  # supervisor unwinds whatever it had already started.
  #
  # `validate_include_node/1` is called for the same reason and its result
  # discarded on success: `:include_node` decides whether a row records a value
  # and the buffer never sees it, but a bad value still has to fail the start here
  # rather than at delivery.
  #
  # A `with` and no `else`, deliberately: both validators already answer
  # `{:error, {option, message}}`, which is the shape `start/2` hands back.
  defp build do
    if auto_start?() do
      config = handler_config()

      with {:ok, options} <- Handler.validate(config),
           :ok <- Handler.validate_include_node(config) do
        {:ok, [ClickhouseExLogger.Repo, {Buffer, options}, ClickhouseExLogger.HandlerInstaller]}
      end
    else
      {:ok, []}
    end
  end
end
