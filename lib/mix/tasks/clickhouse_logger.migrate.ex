defmodule Mix.Tasks.ClickhouseLogger.Migrate do
  @shortdoc "Creates the ClickHouse database and the `logs` table"

  @moduledoc """
  Creates the ClickHouse database and the `logs` table that
  `ClickhouseLogger.Handler` writes to.

      mix clickhouse_logger.migrate
      mix clickhouse_logger.migrate --dry-run

  Run this from your host application **before** you attach the handler.

  ## Why this task and not `mix ash_clickhouse.migrate`

  `mix ash_clickhouse.migrate` finds AshClickhouse resources by listing the
  modules of the *current* Mix project, so it never sees
  `ClickhouseLogger.LogEntry` — that resource belongs to the `clickhouse_logger`
  dependency. This task targets it explicitly.

  It delegates to `ClickhouseLogger.Migration`, which starts a connection,
  creates the database if it is missing, and then applies the versioned
  migration files this library ships under `priv/repo/migrations` through
  `AshClickhouse.MigrationRunner`. The `CREATE TABLE` statement itself is
  generated from the resource by `AshClickhouse.Migration.create_table_cql/1`,
  so the table never drifts from the resource definition.

  Applied migrations are recorded in ClickHouse's `schema_migrations` table, so
  re-running this task is a no-op.
  """

  use Mix.Task

  @switches [dry_run: :boolean]
  @aliases [d: :dry_run]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    Mix.Task.run("app.config", ["--no-start"])

    case ClickhouseLogger.Migration.setup(opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "ClickhouseLogger schema is up to date: #{length(summary.applied)} applied, " <>
            "#{length(summary.skipped)} already applied."
        )

      {:error, reason} ->
        Mix.raise("""
        Could not create the ClickhouseLogger schema.

        #{format_reason(reason)}

        Check that:
          * `CLICKHOUSE_URL` (or your `config :clickhouse_logger, ClickhouseLogger.Repo`)
            points at a reachable ClickHouse server
          * `:url`, `:username` and `:password` are correct
          * `:database` names a database you are allowed to create
        """)
    end
  end

  defp format_reason(reason), do: if(is_binary(reason), do: reason, else: inspect(reason))
end
