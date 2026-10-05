defmodule ClickhouseExLogger.ApplicationTest do
  @moduledoc """
  Verifies `ClickhouseExLogger.Application`'s supervision tree, and the
  `ClickhouseExLogger.HandlerInstaller` that attaches the handler inside it.

  Starts the real children rather than a stand-in: the whole point of this
  library's automatic start is which processes exist and in what order they come
  up and go down, and a fake tree would not exercise any of it.

  ## Why the tree here has no connection child

  `ClickhouseExLogger.Repo` is a globally-named connection and a second one cannot
  be started in a VM — `ClickHouse.Interface.HTTP` keeps a globally named ETS table
  per connection, so the second start raises `table name already exists` from
  inside the new process. The suite already owns that connection, and this module
  would otherwise have to stop and restart it around every test, which is a race
  between a test and its own predecessor's teardown rather than a property of the
  library.

  So the trees started here are `Application.children/0` with the `Repo` child
  removed, and the suite's connection serves them. That the connection really is
  part of the tree, and really is consulted, is asserted where it belongs: the
  `children/0` tests check it is in the list, and the unconfigured-connection test
  proves the start reaches `Repo.config/0` through `child_spec/1` and fails with
  the message a host needs.

  Synchronous because two of its tests repoint the repository and restart that one
  connection — which inherits that from `ClickhouseExLogger.Case`.
  """

  use ClickhouseExLogger.Case

  import ExUnit.CaptureLog

  require Logger

  # `ClickhouseExLogger.Application` is deliberately not aliased. Aliasing it
  # would shadow `Elixir.Application` for this whole module, so every
  # `Application.put_env/3` below would resolve to a module that has no such
  # function — the same trap a host hits if it aliases ours.
  alias ClickhouseExLogger.{Buffer, Handler, HandlerInstaller, TestServer}

  @handler_id :clickhouse_ex_logger
  # Nothing listens here, so a connection to it starts and then fails every
  # statement — which is what `:unreachable` has to mean.
  @dead_url "http://localhost:1"

  setup do
    repo = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)
    auto_start = Application.get_env(:clickhouse_ex_logger, :auto_start)
    handler = Application.get_env(:clickhouse_ex_logger, :handler)

    # The suite turns the automatic start off — see `config/test.exs`, where the
    # reason is that Mix starts this application before the harness can point it
    # at the container. This module is the one that exercises the enabled path, so
    # it turns it back on. Both values are restored on exit.
    Application.put_env(:clickhouse_ex_logger, :auto_start, true)

    # A supervisor started by `ClickhouseExLogger.Application.start/2` rather than
    # by `start_supervised!/1` is not stopped when the test ends, and the name is
    # taken. Cleared here so one test cannot fail on another's leftovers.
    stop_supervisor()

    on_exit(fn ->
      # The tree attached the handler, and its installer's `terminate/1` removes it
      # on the way down. Belt and braces for a test that failed before the tree
      # ever started.
      _ = :logger.remove_handler(@handler_id)

      stop_supervisor()

      # Restored before the connection, because restarting it is what makes the
      # restored configuration the one in force.
      Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, repo)
      restart_repo_connection()

      if auto_start == nil,
        do: Application.delete_env(:clickhouse_ex_logger, :auto_start),
        else: Application.put_env(:clickhouse_ex_logger, :auto_start, auto_start)

      if handler == nil,
        do: Application.delete_env(:clickhouse_ex_logger, :handler),
        else: Application.put_env(:clickhouse_ex_logger, :handler, handler)
    end)

    :ok
  end

  defp stop_supervisor do
    case Process.whereis(ClickhouseExLogger.Supervisor) do
      nil ->
        :ok

      pid ->
        Supervisor.stop(pid)
        :ok
    end
  end

  describe "children/0" do
    test "are the connection, the buffer, then the installer" do
      assert [ClickhouseExLogger.Repo, {Buffer, options}, HandlerInstaller] =
               ClickhouseExLogger.Application.children()

      assert options == Handler.defaults()
    end

    test "are the host's configured batching options when it gave any" do
      Application.put_env(:clickhouse_ex_logger, :handler,
        level: :warning,
        batch_size: 7,
        flush_interval_ms: 11,
        max_buffer_size: 13
      )

      assert [ClickhouseExLogger.Repo, {Buffer, options}, _] =
               ClickhouseExLogger.Application.children()

      assert options == %{batch_size: 7, flush_interval_ms: 11, max_buffer_size: 13}
    end

    test "are empty when the automatic start is disabled" do
      Application.put_env(:clickhouse_ex_logger, :auto_start, false)

      assert ClickhouseExLogger.Application.children() == []
      refute ClickhouseExLogger.Application.auto_start?()
    end

    test "raise naming the offending option when the configuration is invalid" do
      Application.put_env(:clickhouse_ex_logger, :handler, batch_size: -1)

      assert_raise ArgumentError, ~r/batch_size/, fn ->
        ClickhouseExLogger.Application.children()
      end
    end

    test "raise naming the offending option for a non-boolean :include_node" do
      Application.put_env(:clickhouse_ex_logger, :handler, include_node: "yes")

      assert_raise ArgumentError, ~r/include_node/, fn ->
        ClickhouseExLogger.Application.children()
      end
    end
  end

  describe "start/2" do
    test "returns an error naming the option rather than starting a broken tree" do
      Application.put_env(:clickhouse_ex_logger, :handler, batch_size: 0)

      assert {:error, {:batch_size, message}} = ClickhouseExLogger.Application.start(:normal, [])
      assert message =~ "positive integer"
    end

    test "leaves nothing running when the configuration is invalid" do
      Application.put_env(:clickhouse_ex_logger, :handler, max_buffer_size: -5)

      assert {:error, {:max_buffer_size, _message}} =
               ClickhouseExLogger.Application.start(:normal, [])

      # Nothing from a rejected start is left running. Asserted on the supervisor
      # rather than on the buffer, because a buffer left by an earlier test is not
      # this start's to account for.
      assert Process.whereis(ClickhouseExLogger.Supervisor) == nil
      assert :logger.get_handler_ids() |> Enum.count(&(&1 == @handler_id)) == 0
    end

    test "fails naming the missing configuration when the connection is unset" do
      Application.delete_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      # The message the host needs, rather than a supervisor failure about a child
      # spec: `Repo.config/0` raises this, and `child_spec/1` is where the
      # supervisor reaches it — so the exception surfaces from the start rather
      # than being wrapped in an `{:error, reason}`.
      assert_raise AshClickhouse.Error.ConfigurationError,
                   ~r/ClickhouseExLogger.Repo is not configured/,
                   fn -> ClickhouseExLogger.Application.start(:normal, []) end
    end

    test "starts nothing when the automatic start is disabled" do
      Application.put_env(:clickhouse_ex_logger, :auto_start, false)

      assert {:ok, pid} = ClickhouseExLogger.Application.start(:normal, [])
      assert %{active: 0} = Supervisor.count_children(pid)

      Supervisor.stop(pid)
    end
  end

  describe "the running pipeline" do
    test "supervises the buffer and the installer, and attaches the handler" do
      assert :attached = start_pipeline!()

      # Two, because this module's trees drop the `Repo` child — see the moduledoc.
      assert %{active: 2} = Supervisor.count_children(ClickhouseExLogger.Supervisor)
      assert GenServer.whereis(Buffer)
      assert {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config[:module] == Handler
      assert Buffer.stats().active?
    end

    test "delivers a logged row to ClickHouse" do
      truncate_logs!()
      assert :attached = start_pipeline!(handler: [batch_size: 1, flush_interval_ms: 60_000])

      Logger.warning("a row through the automatic start")

      eventually(fn -> row_count() == "1" end)
    end

    test "attaches once when the host also calls install/2 itself" do
      assert :attached = start_pipeline!()

      assert {:ok, @handler_id} = Handler.install(@handler_id, [])

      assert :logger.get_handler_ids() |> Enum.count(&(&1 == @handler_id)) == 1
      assert buffer_process_count() == 1
    end
  end

  describe "the readiness check" do
    @tag :capture_log
    test "attaches when the table is there" do
      log = capture_log(fn -> send(self(), {:decision, start_pipeline!()}) end)

      assert_received {:decision, :attached}
      assert {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config[:module] == Handler
      refute log =~ "logs` table does not exist"
    end

    @tag :capture_log
    test "does not attach, and says so, when the table is not there" do
      # A database that does not exist. The connection still starts — a ClickHouse
      # client binds lazily enough for that — and the check reads `system.tables`
      # per request, so it can tell this apart from the server being down.
      configure_database("clickhouse_ex_logger_startup_absent")
      restart_repo_connection()

      log = capture_log(fn -> send(self(), {:decision, start_pipeline!()}) end)

      assert_received {:decision, :not_attached}
      assert {:error, {:not_found, @handler_id}} = :logger.get_handler_config(@handler_id)
      assert log =~ "logs` table does not exist"
      assert log =~ "mix clickhouse_ex_logger.migrate"
      assert log =~ "ClickhouseExLogger.Utils.migrate()"
    end

    @tag :capture_log
    test "attaches anyway when the server cannot be reached" do
      configure_url(@dead_url)
      restart_repo_connection()

      log = capture_log(fn -> send(self(), {:decision, start_pipeline!()}) end)

      assert_received {:decision, :attached}
      assert {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config[:module] == Handler
      assert log =~ "did not answer at startup"
    end

    @tag :capture_log
    test "attaches when the table exists but predates this version's columns" do
      # Existence, not shape. A table from before a later version's column still
      # attaches, and the writes ClickHouse rejects are reported and counted as
      # lost — which is what the documented upgrade path says to expect.
      capture_log(fn ->
        send(
          self(),
          {:decision, start_pipeline!(handler: [batch_size: 1, flush_interval_ms: 60_000])}
        )
      end)

      assert_received {:decision, :attached}

      TestServer.query!("ALTER TABLE #{TestServer.database()}.logs DROP COLUMN IF EXISTS node")

      on_exit(&restore_node_column/0)
      truncate_logs!()

      Logger.warning("a row the table cannot take")

      eventually(fn ->
        stats = Buffer.stats()
        stats.lost > 0 and stats.failed > 0
      end)

      assert {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config[:module] == Handler
    end
  end

  describe "shutdown" do
    @tag :capture_log
    test "removes the handler and still drains what was buffered" do
      # The ordering the tree exists for. Children terminate in reverse start
      # order, so the installer takes the handler off first; the buffer then makes
      # its own bounded final attempt. If the removal happened after the drain, or
      # instead of it, the row below would be lost rather than delivered.
      truncate_logs!()

      assert :attached =
               start_pipeline!(handler: [batch_size: 10_000, flush_interval_ms: 60_000])

      Logger.warning("buffered, then drained at shutdown")

      eventually(fn -> Buffer.stats().buffered == 1 end)

      capture_log(fn -> stop_pipeline!() end)

      # The row was written during the drain, which is the point: removing the
      # handler must not cost the buffer what it was holding.
      assert row_count() == "1"
      assert {:error, {:not_found, @handler_id}} = :logger.get_handler_config(@handler_id)
    end

    @tag :capture_log
    test "completes in bounded time while ClickHouse is stalled" do
      configure_url(@dead_url)
      restart_repo_connection()

      assert :attached =
               start_pipeline!(handler: [batch_size: 10_000, flush_interval_ms: 60_000])

      Logger.warning("a row that cannot be written")

      eventually(fn -> Buffer.stats().buffered == 1 end)

      {microseconds, _} =
        :timer.tc(fn ->
          capture_log(fn -> stop_pipeline!() end)
        end)

      assert microseconds < 20_000_000
    end
  end

  # Starts the tree the application would start, as a supervised child of the
  # test so ExUnit stops it for us — except in the shutdown tests, which need to
  # stop it themselves and watch what that does.
  #
  # Returns the installer's decision, so a caller can tell "attached" from
  # "deliberately not attached" without inspecting side effects.
  defp start_pipeline!(overrides \\ []) do
    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:clickhouse_ex_logger, key, value)
    end)

    # An explicit child spec, not `{Supervisor, args}`: passing arguments to a
    # supervisor module is deprecated, and this is the shape it asks for instead.
    start_supervised!(%{
      id: :clickhouse_ex_logger_test_pipeline,
      start:
        {Supervisor, :start_link,
         [
           tree_children(),
           [strategy: :one_for_one, name: ClickhouseExLogger.Supervisor, shutdown: 15_000]
         ]},
      type: :supervisor
    })

    HandlerInstaller.await_attach()
  end

  describe "HandlerInstaller on its own" do
    test "starts with no configuration and attaches" do
      start_supervised!(HandlerInstaller)

      assert :attached = HandlerInstaller.await_attach()
    end

    test "reports a configuration this library rejects" do
      # `:level` is validated by `Handler.validate/1`, which `Application` runs
      # before the tree exists — so through the application this branch is
      # unreachable. Started directly, it is the same rejection one layer down,
      # and it must be reported rather than crash the installer.
      log =
        capture_log(fn ->
          start_supervised!({HandlerInstaller, [level: :not_a_level]})
          send(self(), {:decision, HandlerInstaller.await_attach()})
        end)

      assert_received {:decision, :not_attached}
      assert log =~ "could not attach the log handler"
      assert log =~ ":level"
    end

    test "reports a configuration the logging system itself rejects" do
      # A formatter is passed through to `:logger` unvalidated by this library,
      # and `:logger` refuses one. The two failures have different shapes and a
      # host has to be able to tell them apart: one names an option this library
      # documents, the other reports what `:logger` said.
      log =
        capture_log(fn ->
          start_supervised!({HandlerInstaller, [formatter: :not_a_formatter]})
          send(self(), {:decision, HandlerInstaller.await_attach()})
        end)

      assert_received {:decision, :not_attached}
      assert log =~ "could not attach the log handler"
      assert log =~ "invalid_formatter"
    end

    test "await_attach/1 times out instead of hanging when nothing is installing" do
      assert {:error, :timeout} = HandlerInstaller.await_attach(0)
    end
  end

  # `Application.children/0` without the `Repo` child, for the reason in the
  # moduledoc: this module's trees share the suite's one connection.
  defp tree_children do
    Enum.reject(ClickhouseExLogger.Application.children(), &(&1 == ClickhouseExLogger.Repo))
  end

  defp stop_pipeline! do
    Supervisor.stop(Process.whereis(ClickhouseExLogger.Supervisor))
  end

  defp buffer_process_count do
    ClickhouseExLogger.Buffer
    |> Process.whereis()
    |> then(fn
      nil -> 0
      pid -> if Process.alive?(pid), do: 1, else: 0
    end)
  end

  defp row_count do
    TestServer.query!("SELECT count() FROM #{TestServer.database()}.logs") |> String.trim()
  end

  # Copied from the other synchronous modules rather than shared: `Case` is the
  # only shared seam in this suite and this helper is eight lines that each of
  # those modules already carries its own copy of.
  defp eventually(fun, attempts \\ 300) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  defp configure_database(database) do
    repo = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

    Application.put_env(
      :clickhouse_ex_logger,
      ClickhouseExLogger.Repo,
      Keyword.put(repo, :database, database)
    )
  end

  defp configure_url(url) do
    repo = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

    Application.put_env(
      :clickhouse_ex_logger,
      ClickhouseExLogger.Repo,
      Keyword.put(repo, :url, url)
    )
  end

  defp stop_repo_connection do
    try do
      AshClickhouse.Connection.stop(ClickhouseExLogger.Repo)
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  defp restart_repo_connection do
    stop_repo_connection()

    {:ok, conn} =
      AshClickhouse.Connection.start_link(
        AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)
      )

    Process.unlink(conn)

    :ok
  end

  # Put the column back from the resource's own DDL, the same way
  # `ClickhouseExLogger.MigrationTest` restores a dropped table: `setup/1` is
  # idempotent by version, so it would not re-add a column on its own.
  defp restore_node_column do
    TestServer.query!(
      "ALTER TABLE #{TestServer.database()}.logs ADD COLUMN IF NOT EXISTS node Nullable(String)"
    )

    :ok
  end
end
