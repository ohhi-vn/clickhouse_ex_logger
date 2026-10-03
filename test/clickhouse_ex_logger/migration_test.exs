defmodule ClickhouseExLogger.MigrationTest do
  @moduledoc """
  Verifies `ClickhouseExLogger.Migration.setup/1` called directly, as opposed to
  through the Mix task (see `ClickhouseExLogger.MigrateTaskTest`).

  Covers what the task's own tests cannot: that `--dry-run` leaves the schema
  alone, and that the migration path is resolved through the OTP application
  rather than the caller's working directory.

  Synchronous: this stops and restarts the shared repo connection, and reads the
  shared container's `schema_migrations`.
  """

  use ClickhouseExLogger.Case

  alias ClickhouseExLogger.Migration
  alias ClickhouseExLogger.TestServer

  setup do
    original = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

    on_exit(fn ->
      Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
      restart_repo_connection()
    end)

    :ok
  end

  describe "setup/1 with :dry_run" do
    test "reports what would run and changes nothing" do
      # `:dry_run` skips `CREATE DATABASE`, not the connection: `setup/1` still
      # binds a client to the configured database, so this runs against the
      # suite's real one rather than a fresh name.
      before = schema_migrations()

      assert {:ok, summary} = setup_with_fresh_connection(dry_run: true)

      assert length(summary.applied) + length(summary.skipped) == 2

      # Nothing applied, nothing recorded, table untouched.
      assert summary.applied == []
      assert schema_migrations() == before
      assert TestServer.table_exists?()
    end
  end

  describe "setup/1 with a running repo connection" do
    test "reuses it instead of starting a second client" do
      # A running release has usually already started `ClickhouseExLogger.Repo`
      # through the host's supervision tree. Starting a second client under the
      # same name raises `ArgumentError: table name already exists` from inside
      # the new process, because `ClickHouse.Interface.HTTP.init/1` creates a
      # globally named ETS table. So this is the case the Mix task never hits.
      before = schema_migrations()

      assert {:ok, summary} = Migration.setup([])

      assert length(summary.applied) + length(summary.skipped) == 2
      assert summary.applied == []

      # Nothing to apply against an already-migrated database, so `schema_migrations`
      # is untouched and the connection this run borrowed is still the shared one.
      assert schema_migrations() == before
      assert %{pid: pid} = AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo)
      assert Process.alive?(pid)
    end
  end

  describe "setup/1 migrations path" do
    test "resolves through priv_dir rather than the working directory" do
      # `AshClickhouse.MigrationRunner` defaults `:migration_path` to the
      # relative `"priv/repo/migrations"`, which resolves against the caller's
      # cwd. Running from somewhere else proves the absolute path is in use: a
      # relative one would find no migrations and report an empty summary.
      cwd = File.cwd!()
      elsewhere = Path.join(System.tmp_dir!(), "clickhouse_ex_logger_elsewhere")
      File.mkdir_p!(elsewhere)
      File.cd!(elsewhere)

      on_exit(fn ->
        File.cd!(cwd)
        File.rm_rf!(elsewhere)
      end)

      assert {:ok, summary} = setup_with_fresh_connection([])

      assert length(summary.applied) + length(summary.skipped) == 2
      assert summary.applied == []
    end
  end

  # Runs `setup/1` with no repo connection up, which is the state a host is in:
  # a second start in one VM raises on the client's named ETS table (see
  # `ClickhouseExLogger.Migration`'s moduledoc).
  defp setup_with_fresh_connection(opts) do
    stop_repo_connection()

    Migration.setup(opts)
  end

  describe "setup/1 with a database name the server would reject" do
    test "returns a diagnosable failure instead of raising" do
      # A perfectly ordinary name for a host to write — an environment suffix is a
      # dot — which ClickHouse will not take as an unquoted identifier. `setup/1`'s
      # contract is `{:error, reason}`, and both entry points have an actionable
      # message waiting for a reason: the Mix task's checklist of things to check,
      # and the release function's advice about which config key to fix. A raise
      # bypasses both and leaves the host to read a dependency's exception.
      original = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      Application.put_env(
        :clickhouse_ex_logger,
        ClickhouseExLogger.Repo,
        Keyword.put(original, :database, "app.production")
      )

      restart_repo_connection()

      on_exit(fn ->
        Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
        restart_repo_connection()
      end)

      assert {:error, reason} = Migration.setup([])
      assert reason =~ "app.production"
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
