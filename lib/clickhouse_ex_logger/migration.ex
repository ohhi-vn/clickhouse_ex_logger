defmodule ClickhouseExLogger.Migration do
  @moduledoc """
  Creates the ClickHouse database and the `logs` table.

  This is the single place that knows how to prepare the schema. It backs
  `mix clickhouse_ex_logger.migrate` and `ClickhouseExLogger.Utils.migrate/1`
  (what a host application runs, with Mix and without it respectively), and the
  test harness in `test/test_helper.exs`.

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
  `ClickhouseExLogger.Repo.CreateDatabase` with no database, and only then is the
  real `ClickhouseExLogger.Repo` connection started. Two names, two independent
  client registrations, no restart.

  ## One call per VM

  `setup/1` starts the `ClickhouseExLogger.Repo` connection, and it cannot be
  called twice in one VM: `ClickHouse.Interface.HTTP` creates a named ETS table
  in its `init/1`, so the second start raises `ArgumentError: table name already
  exists` from inside the new process — before
  `AshClickhouse.Connection.start_link/1` can map `{:error, {:already_started,
  pid}}`, and outside `setup/0`'s `try/after`, so the caller gets an exception
  rather than an error tuple.

  That is not a constraint a host can meet by accident.
  `mix clickhouse_ex_logger.migrate` is one invocation in one VM, and applying a
  migration twice — the actual requirement — is a matter of
  `AshClickhouse.MigrationRunner` finding nothing left to apply.

  The release entry point is the case where the connection is already up:
  `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"` boots the release before
  evaluating the expression, so the host's supervision tree has usually started
  `ClickhouseExLogger.Repo` by then. `setup/1` therefore reuses a live repo
  connection when it finds one and starts a connection only when it does not.

  ## Nothing here changes schema at application boot

  A library must not create schema behind its host's back. `setup/1` — the only
  function here that writes DDL — is reachable only from an explicit call:
  `mix clickhouse_ex_logger.migrate`, `ClickhouseExLogger.Utils.migrate/1`, or test
  setup. Never from starting the `:clickhouse_ex_logger` application.

  `logs_table_status/0` *is* reached at boot, by
  `ClickhouseExLogger.HandlerInstaller`, and is deliberately read-only: one
  `SELECT count()` against `system.tables`.
  """

  @bootstrap_name ClickhouseExLogger.Repo.CreateDatabase

  # How long the readiness query may take. Bounded because the caller is a
  # supervised child: a `GenServer` blocked in `handle_continue/2` does not run its
  # `terminate/1`, so an unbounded query here would defer handler removal on
  # shutdown for as long as the server took to answer.
  #
  # Generous enough for a `system.tables` count over a real network, small enough
  # to stay well inside the buffer's own 5s shutdown budget. Exceeding it is not
  # dangerous: the query fails, the failure reads as `:unreachable`, and an
  # unreachable server attaches the handler anyway. The timeout fails in the safe
  # direction.
  @readiness_timeout 2_000

  @doc """
  Reports whether the `logs` table is there, changing nothing.

  Returns `:present`, `:absent`, or `:unreachable`.

  The three answers are not one question with two outcomes, because the caller
  acts differently on each: a missing table means the host has not run the
  migration, which is worth one readable message, while an unreachable server
  means ClickHouse is briefly down, which is not a reason to stop capturing logs.
  Collapsing them would either disable logging through an outage or say nothing
  useful on a first install.

  ## Why `system.tables` and not the configured database

  A plain statement against the configured database cannot answer this when that
  database does not exist — the server rejects it with `UNKNOWN_DATABASE`, which
  is indistinguishable from the server being down. That is the case a first
  install is in, and it is the case most worth catching.

  The `database` query option is what resolves it: it is sent per request, so
  asking for `system` overrides whatever the connection was bound to. A
  connection bound to a database that does not exist can therefore still be asked
  whether that database exists. Verified against the suite's container; see
  `ClickhouseExLogger.HandlerInstaller`.

  ## Read-only

  One `SELECT count()`. It creates no database, no table, and records no
  migration, which is what lets boot ask the question at all.
  """
  @spec logs_table_status() :: :present | :absent | :unreachable
  def logs_table_status do
    case ClickhouseExLogger.Repo.query(readiness_sql(), [], readiness_opts()) do
      {:ok, result} ->
        if String.trim(result.raw) == "0", do: :absent, else: :present

      {:error, _reason} ->
        :unreachable
    end
  end

  @doc """
  Reports whether `ClickhouseExLogger.LogEntry`'s table exists.

  Read from the resource rather than repeated here, so the table this library
  writes to and the table this library reports on cannot drift apart — the same
  reason the `CREATE TABLE` statement is generated from the resource.
  """
  @spec logs_table() :: String.t()
  def logs_table, do: AshClickhouse.DataLayer.Dsl.table(ClickhouseExLogger.LogEntry)

  defp readiness_sql do
    # Interpolated rather than bound: the `clickhouse` client's parameter binding
    # is for INSERT row data, not for `SELECT` predicates. Both values are known
    # to us — the table name comes from our own resource, the database from the
    # host's config — and both are quoted as string literals, so a name carrying
    # a quote cannot terminate the literal.
    database = escape_literal(ClickhouseExLogger.Repo.database() || "default")

    """
    SELECT count() FROM system.tables \
    WHERE database = '#{database}' AND name = '#{escape_literal(logs_table())}'
    """
  end

  defp readiness_opts do
    [
      database: "system",
      default_format: "TabSeparated",
      connect_timeout: @readiness_timeout,
      recv_timeout: @readiness_timeout
    ]
  end

  defp escape_literal(value) do
    value |> to_string() |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
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

    Code.ensure_loaded!(ClickhouseExLogger.Repo)

    with {:ok, _apps} <- Application.ensure_all_started(:hackney),
         {:ok, _bootstrap} <- start_bootstrap_connection(),
         :ok <- ensure_database(dry_run?),
         {:ok, _repo_conn} <- ensure_repo_connection(),
         {:ok, summary} <- apply_migrations(dry_run?) do
      {:ok, summary}
    end
  end

  defp start_bootstrap_connection do
    ClickhouseExLogger.Repo
    |> AshClickhouse.Repo.config_to_conn_opts()
    |> Keyword.merge(name: @bootstrap_name, database: nil)
    |> AshClickhouse.Connection.start_link()
  end

  defp stop_bootstrap_connection do
    AshClickhouse.Connection.stop(@bootstrap_name)
  end

  defp ensure_repo_connection do
    case running_repo_connection() do
      {:ok, pid} -> {:ok, pid}
      nil -> start_repo_connection()
    end
  end

  defp start_repo_connection do
    AshClickhouse.Connection.start_link(
      AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)
    )
  end

  # A running release has usually already started `ClickhouseExLogger.Repo`
  # through the host's supervision tree, because `bin/my_app eval` boots the
  # release before evaluating the expression. Starting a second client under the
  # same name would raise `ArgumentError: table name already exists` from inside
  # the new process, so reuse the running one instead.
  #
  # `get_conn/1` erases its `:persistent_term` entry when the client process dies
  # (the monitor `AshClickhouse.Connection.start_link/1` installs), so the
  # `:persistent_term` lookup alone would usually be enough. The liveness check is
  # kept because this function is the difference between running a migration and
  # silently not running one.
  defp running_repo_connection do
    case AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo) do
      %{pid: pid} when is_pid(pid) -> if(Process.alive?(pid), do: {:ok, pid})
      _ -> nil
    end
  end

  defp ensure_database(true = _dry_run?), do: :ok

  defp ensure_database(false) do
    database = ClickhouseExLogger.Repo.database() || "default"

    # `AshClickhouse.Identifier` has a bang validator that raises, and using it here
    # meant a name the server would not accept escaped `setup/1` as an exception
    # rather than arriving as the `{:error, reason}` both callers are written to
    # report. That cost each entry point its own actionable message: the Mix task's
    # checklist of what to check, and the release function's advice about which
    # config key to fix. A host cannot act on a dependency's exception.
    #
    # `valid_identifier?/1` is the same test the bang validator performs.
    if AshClickhouse.Identifier.valid_identifier?(database) do
      case AshClickhouse.Connection.query(@bootstrap_name, create_database_sql(database)) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error,
       "invalid ClickHouse database name: #{inspect(database)}. It must be an " <>
         "unquoted identifier — letters, digits and underscores, starting with a " <>
         "letter or underscore. Set it with `config :clickhouse_ex_logger, " <>
         "ClickhouseExLogger.Repo, database: \"...\"`."}
    end
  end

  defp create_database_sql(database) do
    "CREATE DATABASE IF NOT EXISTS #{AshClickhouse.Identifier.quote_name(database)}"
  end

  defp apply_migrations(dry_run?) do
    AshClickhouse.MigrationRunner.migrate(ClickhouseExLogger.Repo,
      migration_path: migrations_path(),
      dry_run: dry_run?,
      logger: true
    )
  end

  # `AshClickhouse.MigrationRunner` defaults `:migration_path` to the *relative*
  # `"priv/repo/migrations"`, which resolves against the caller's working
  # directory rather than ours. Resolve it through the OTP application instead,
  # the same way `AshClickhouse.Release` does, so it works from any cwd.
  #
  # No fallback for a `:code.priv_dir/1` error: the application is loaded to get
  # this far, so it always has a directory. Falling back to the relative path
  # would resolve against the caller's cwd, which is the bug this exists to
  # avoid.
  defp migrations_path do
    :clickhouse_ex_logger
    |> :code.priv_dir()
    |> then(&Path.join(&1, "repo/migrations"))
  end
end
