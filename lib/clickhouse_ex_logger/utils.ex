defmodule ClickhouseExLogger.Utils do
  @moduledoc """
  Host-facing helpers that work in a release, where Mix is not available.

  ## Running the migration without Mix

  `mix clickhouse_ex_logger.migrate` is the entry point for a host with Mix. A
  production release built with `mix release` has no Mix task available and no
  `mix` binary on the machine, so this module is the equivalent entry point:

      bin/my_app eval "ClickhouseExLogger.Utils.migrate()"

  Run it *before* the new version starts logging. The same requirement that
  applies to the Mix task applies here — a library version whose rows carry a
  column the database does not have is rejected by ClickHouse, and the rows are
  counted as lost rather than raising. See
  `ClickhouseExLogger.Migration.setup/1` for the mechanics.
  """

  require Logger

  @doc """
  Creates the ClickHouse database and applies pending migrations.

  Equivalent to `mix clickhouse_ex_logger.migrate`, callable from a release.
  Reads the same connection configuration and applies the same migration files
  that ship under `priv/repo/migrations`, so the schema it produces is the one
  the Mix task produces. Safe to run more than once: already-applied versions
  are skipped.

  Returns `{:ok, summary}` where `summary` has `:applied` and `:skipped` lists of
  migration modules, or `{:error, reason}`. The summary is logged through
  `Logger`, which is the reporting channel available without Mix.

  ## Options

    * `:dry_run` — report what would run without executing it.

  ## Examples

      $ bin/my_app eval "ClickhouseExLogger.Utils.migrate()"
      $ bin/my_app eval "ClickhouseExLogger.Utils.migrate(dry_run: true)"
  """
  @spec migrate(keyword()) ::
          {:ok, %{applied: [module()], skipped: [module()]}} | {:error, term()}
  def migrate(opts \\ []) do
    Code.ensure_loaded!(ClickhouseExLogger.Repo)

    # A release that has already started `ClickhouseExLogger.Repo` through the
    # host's supervision tree must keep it: stopping a supervised connection
    # here would take logging down for the rest of the release's life. When there
    # was none, `setup/1` starts one to run the migration against, and that one
    # is ours to clean up.
    already_running? = repo_connection_running?()

    try do
      do_migrate(opts)
    after
      unless already_running? do
        AshClickhouse.Connection.stop(ClickhouseExLogger.Repo)
      end
    end
  end

  defp do_migrate(opts) do
    case ClickhouseExLogger.Migration.setup(opts) do
      {:ok, summary} ->
        Logger.info(fn ->
          "ClickhouseExLogger schema is up to date: #{length(summary.applied)} applied, " <>
            "#{length(summary.skipped)} already applied."
        end)

        {:ok, summary}

      {:error, reason} ->
        Logger.error(fn ->
          "Could not create the ClickhouseExLogger schema: #{inspect(reason)}. Check that " <>
            "your `config :clickhouse_ex_logger, ClickhouseExLogger.Repo` names a reachable " <>
            "ClickHouse server with correct credentials, and a database you may create."
        end)

        {:error, reason}
    end
  end

  # Mirrors `ClickhouseExLogger.Migration`'s own check for an already-running
  # client. That one decides whether to reuse the connection; this one only
  # records whether it had to, so it is about ownership rather than about
  # starting anything.
  defp repo_connection_running? do
    case AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo) do
      %{pid: pid} when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end
