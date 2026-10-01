defmodule ClickhouseLogger.Migration do
  @moduledoc """
  Creates the ClickHouse database and the `logs` table.

  This is the single place that knows how to prepare the schema. It backs
  `mix clickhouse_logger.migrate` (what a host application runs) and the test
  harness in `test/test_helper.exs`.

  ## Why a separate bootstrap connection

  A ClickHouse client binds to a database for the life of the connection, and
  `AshClickhouse.Connection` caches one globally registered client per repo
  module. Two problems follow, both avoided here:

    1. If the database does not exist yet, *every* statement on a connection
       bound to it fails with `UNKNOWN_DATABASE` — including the
       `CREATE DATABASE` that would fix it:

           $ curl 'http://localhost:8123/?database=app' \\
               --data-binary 'CREATE DATABASE IF NOT EXISTS app'
           Code: 81. Database app does not exist. (UNKNOWN_DATABASE)

    2. Restarting a connection to rebind it does not work. `start_link/1` maps
       `{:error, {:already_started, pid}}` to `{:ok, pid}`, so a second start
       silently reuses the still-unbound client.

  So `CREATE DATABASE` runs over a throwaway connection registered under
  `ClickhouseLogger.Repo.CreateDatabase` with no database, and only then is the
  real `ClickhouseLogger.Repo` connection started. Two names, two independent
  client registrations, no restart.

  ## Nothing here runs at application boot

  A library must not create schema behind its host's back. This module is only
  reachable from `mix clickhouse_logger.migrate` and from test setup.
  """

  @bootstrap_name ClickhouseLogger.Repo.CreateDatabase

  @doc """
  Whether a ClickHouse server answers at the configured `:url`.

  Does not require the configured database to exist, so it is safe to call
  before anything has been created.
  """
  @spec server_available?() :: boolean()
  def server_available? do
    available? =
      case start_bootstrap_connection() do
        {:ok, _conn} -> match?({:ok, _result}, ping_bootstrap())
        {:error, _reason} -> false
      end

    stop_bootstrap_connection()
    available?
  end

  @doc """
  Ensures the configured database exists and applies pending migrations.

  Returns `{:ok, summary}` where `summary` has `:applied` and `:skipped` lists of
  migration modules, or `{:error, reason}`.

  ## Options

    * `:dry_run` — report what would run without executing it.
  """
  @spec setup(keyword()) :: {:ok, %{applied: [module()], skipped: [module()]}} | {:error, term()}
  def setup(opts \\ []) do
    try do
      create_schema(opts)
    after
      # The bootstrap client owns a globally named ETS table, so it must be
      # released on every path or the next `start_bootstrap_connection/0` dies
      # with "table name already exists".
      stop_bootstrap_connection()
    end
  end

  defp create_schema(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    Code.ensure_loaded!(ClickhouseLogger.Repo)

    with {:ok, _apps} <- Application.ensure_all_started(:hackney),
         {:ok, _bootstrap} <- start_bootstrap_connection(),
         :ok <- ensure_database(dry_run?),
         {:ok, _repo_conn} <- start_repo_connection(),
         {:ok, summary} <- apply_migrations(dry_run?) do
      {:ok, summary}
    end
  end

  defp start_bootstrap_connection do
    ClickhouseLogger.Repo
    |> AshClickhouse.Repo.config_to_conn_opts()
    |> Keyword.merge(name: @bootstrap_name, database: nil)
    |> AshClickhouse.Connection.start_link()
  end

  defp stop_bootstrap_connection do
    AshClickhouse.Connection.stop(@bootstrap_name)
  end

  defp start_repo_connection do
    AshClickhouse.Connection.start_link(
      AshClickhouse.Repo.config_to_conn_opts(ClickhouseLogger.Repo)
    )
  end

  defp ping_bootstrap do
    AshClickhouse.Connection.query(@bootstrap_name, "SELECT 1")
  end

  defp ensure_database(true = _dry_run?), do: :ok

  defp ensure_database(false) do
    database = ClickhouseLogger.Repo.database() || "default"
    :ok = AshClickhouse.Identifier.validate_database!(database)

    case AshClickhouse.Connection.query(@bootstrap_name, create_database_sql(database)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_database_sql(database) do
    "CREATE DATABASE IF NOT EXISTS #{AshClickhouse.Identifier.quote_name(database)}"
  end

  defp apply_migrations(dry_run?) do
    AshClickhouse.MigrationRunner.migrate(ClickhouseLogger.Repo,
      migration_path: migrations_path(),
      dry_run: dry_run?,
      logger: true
    )
  end

  # `AshClickhouse.MigrationRunner` defaults `:migration_path` to the *relative*
  # `"priv/repo/migrations"`, which resolves against the caller's working
  # directory rather than ours. Resolve it through the OTP application instead,
  # the same way `AshClickhouse.Release` does, so it works from any cwd.
  defp migrations_path do
    case :code.priv_dir(:clickhouse_logger) do
      {:error, _reason} -> "priv/repo/migrations"
      priv_dir -> Path.join(priv_dir, "repo/migrations")
    end
  end
end
