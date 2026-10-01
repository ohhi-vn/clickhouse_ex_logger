defmodule ClickhouseExLogger.MigrateTaskTest do
  @moduledoc """
  Verifies `mix clickhouse_ex_logger.migrate`, the one command a host runs.

  Called directly through `Mix.Task.run/2` rather than shelled out to `mix`,
  because the suite already holds a live connection to the same database and a
  subprocess would race it on `schema_migrations`. The task re-reads the repo
  configuration through `AshClickhouse.Repo.config/0`, so calling it in-process
  reads the same environment a host would.

  Synchronous: the failure case rewrites the globally-configured repo
  connection, exactly as `ClickhouseExLogger.BufferFailureTest` does.
  `ClickhouseExLogger.Case` defaults to that; see the template for why.
  """

  use ClickhouseExLogger.Case

  alias ClickhouseExLogger.TestServer

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    # `ClickhouseExLogger.Migration.setup/1` starts the repo connection itself,
    # and a *second* start in the same VM dies: `ClickHouse.Interface.HTTP`
    # creates a named ETS table in `init/1`, so the crash happens before
    # `AshClickhouse.Connection.start_link/1`'s already-started branch can apply,
    # and the raise escapes `setup/0`'s `try/after`. The suite's connection has
    # been running since `test/test_helper.exs` called `setup/1` once, so drop it
    # first — which is also the state a host is in, since
    # `mix clickhouse_ex_logger.migrate` is one invocation in a fresh VM.
    stop_repo_connection()

    # `Migration.setup/1` links the connection it starts to whichever process
    # called it — here, the test process — so leaving it to the test's exit would
    # take the shared connection down with it and invalidate every module that
    # runs after this one. Put a fresh, unlinked one back instead.
    on_exit(&restart_repo_connection/0)

    :ok
  end

  describe "run/1 on a reachable server" do
    test "reports the schema as up to date, and stays a no-op when run again" do
      assert migrate([]) == :ok
      assert_received {:mix_shell, :info, [first]}

      assert first =~ "ClickhouseExLogger schema is up to date"

      # Idempotency is the spec's requirement. The suite's schema was created by
      # `test/test_helper.exs` through this same code path, so this call already
      # takes the already-applied branch; running it again must not change that.
      assert migrate([]) == :ok
      assert_received {:mix_shell, :info, [second]}

      assert second =~ "0 applied"
      assert second =~ "2 already applied"
      assert TestServer.table_exists?()
    end

    test "leaves the table the library documents" do
      assert migrate([]) == :ok

      assert TestServer.table_exists?()

      columns =
        TestServer.query!(
          "SELECT name FROM system.columns WHERE database = '#{TestServer.database()}' AND table = 'logs'"
        )
        |> String.split("\n", trim: true)
        |> Enum.sort()

      assert columns == ~w(file function id level line message metadata module node timestamp)
    end
  end

  describe "run/1 with --dry-run" do
    test "reports the schema without changing it" do
      assert migrate(["--dry-run"]) == :ok
      assert_received {:mix_shell, :info, [message]}

      assert message =~ "ClickhouseExLogger schema is up to date"
      assert TestServer.table_exists?()
    end

    test "accepts the -d alias" do
      assert migrate(["-d"]) == :ok
      assert_received {:mix_shell, :info, [_message]}
    end
  end

  describe "run/1 against an unreachable server" do
    setup do
      # A port nothing is listening on, so the bootstrap connection cannot be
      # established at all. Distinct from `BufferFailureTest`, which keeps the
      # server reachable and fails on the database instead.
      original = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      Application.put_env(
        :clickhouse_ex_logger,
        ClickhouseExLogger.Repo,
        Keyword.put(original, :url, "http://127.0.0.1:1")
      )

      restart_repo_connection()

      # Config first, then the connection: this module's outer `on_exit` restarts
      # the connection too, and it must do so against the restored URL.
      on_exit(fn ->
        Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
      end)

      :ok
    end

    test "raises with a diagnostic naming the likely causes" do
      assert_raise Mix.Error, ~r/Could not create the ClickhouseExLogger schema/, fn ->
        Mix.Tasks.ClickhouseExLogger.Migrate.run([])
      end
    end

    test "names the connection problem rather than a bare failure" do
      error = assert_raise Mix.Error, fn -> Mix.Tasks.ClickhouseExLogger.Migrate.run([]) end

      message = Exception.message(error)

      assert message =~ "CLICKHOUSE_URL"
      assert message =~ "points at a reachable ClickHouse server"
    end
  end

  # Runs the task the way a host does: no repo connection yet, because
  # `mix clickhouse_ex_logger.migrate` is one invocation in a fresh VM. Every
  # call in this module goes through here for that reason.
  defp migrate(args) do
    stop_repo_connection()

    Mix.Tasks.ClickhouseExLogger.Migrate.run(args)
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

    # See `BufferFailureTest`: a `setup`/`on_exit` process exits immediately,
    # which would take the shared connection down with it.
    Process.unlink(conn)

    :ok
  end
end