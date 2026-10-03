defmodule ClickhouseExLogger.UtilsTest do
  @moduledoc """
  Verifies `ClickhouseExLogger.Utils.migrate/1`, the release entry point a host
  runs when Mix is not available.

  Covers what `ClickhouseExLogger.MigrationTest` cannot: that the host-facing
  function reaches the same schema, that re-running it is a no-op, that
  `:dry_run` changes nothing, and — the reason this function exists — that it
  leaves a host-supervised `ClickhouseExLogger.Repo` running rather than stopping
  the connection it borrowed.

  Synchronous: this stops and restarts the shared repo connection, and reads the
  shared container's `schema_migrations`. Same reason as
  `ClickhouseExLogger.MigrationTest`.
  """

  use ClickhouseExLogger.Case

  import ExUnit.CaptureLog

  alias ClickhouseExLogger.TestServer
  alias ClickhouseExLogger.Utils

  setup do
    on_exit(&restart_repo_connection/0)
    :ok
  end

  describe "migrate/1 against a reachable server" do
    test "reports the schema as up to date, and stays a no-op when run again" do
      log =
        capture_log(fn ->
          assert {:ok, summary} = Utils.migrate()

          assert length(summary.applied) + length(summary.skipped) == 2

          # Already migrated by `test/test_helper.exs`, so nothing is pending.
          assert summary.applied == []
        end)

      assert log =~ "ClickhouseExLogger schema is up to date"

      assert TestServer.table_exists?()
    end

    test "applies the shipped migrations, not a parallel set" do
      # The suite's database was migrated by `test/test_helper.exs` through
      # `ClickhouseExLogger.Migration.setup/1`. A second call that applied
      # anything would mean the two entry points disagree about which files are
      # the library's.
      versions =
        TestServer.query!(
          "SELECT version FROM #{TestServer.database()}.schema_migrations ORDER BY version"
        )

      assert versions =~ "20260101000000"
      assert versions =~ "20261001000000"
    end
  end

  describe "migrate/1 with :dry_run" do
    test "reports what would run and changes nothing" do
      before = schema_migrations()

      capture_log(fn ->
        assert {:ok, summary} = Utils.migrate(dry_run: true)

        assert length(summary.applied) + length(summary.skipped) == 2
        assert summary.applied == []
      end)

      assert schema_migrations() == before
      assert TestServer.table_exists?()
    end
  end

  describe "migrate/1 connection ownership" do
    test "leaves a running repo connection alive" do
      # This is the state a release is in: `bin/my_app eval` boots the release,
      # so the host's supervision tree has already started `ClickhouseExLogger.Repo`.
      # Stopping it here would leave the running release with no connection and no
      # logs, which is a worse outcome than the migration was meant to enable.
      assert %{pid: pid} = AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo)
      assert Process.alive?(pid)

      capture_log(fn -> assert {:ok, _summary} = Utils.migrate() end)

      assert %{pid: ^pid} = AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo)
      assert Process.alive?(pid)
    end

    test "does not leave behind a connection it started itself" do
      # The mirror image: with no connection up, `setup/1` starts one, and it is
      # this call's to clean up rather than the release's to inherit.
      stop_repo_connection()

      capture_log(fn -> assert {:ok, _summary} = Utils.migrate() end)

      assert AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo) == nil
    end
  end

  describe "migrate/1 against an unreachable server" do
    test "returns a diagnosable error rather than raising" do
      original = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      on_exit(fn ->
        Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
        restart_repo_connection()
      end)

      Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo,
        url: "http://localhost:1",
        database: TestServer.database()
      )

      stop_repo_connection()

      log =
        capture_log(fn ->
          assert {:error, reason} = Utils.migrate()
          # Whatever the client's shape, it has to survive `inspect/1` — that is
          # what the operator reads.
          assert is_binary(inspect(reason))
        end)

      assert log =~ "Could not create the ClickhouseExLogger schema"
      assert log =~ "reachable"
    end
  end

  defp schema_migrations do
    TestServer.query!(
      "SELECT version FROM #{TestServer.database()}.schema_migrations ORDER BY version"
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

  # `on_exit/1` runs in a different process from the test, so the connection
  # `Migration.setup/1` links to whatever called it would otherwise be taken down
  # by the test's exit. Put a fresh, unlinked one back, as
  # `ClickhouseExLogger.MigrationTest` does.
  defp restart_repo_connection do
    stop_repo_connection()

    {:ok, conn} =
      AshClickhouse.Connection.start_link(
        AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)
      )

    Process.unlink(conn)

    :ok
  end
end
