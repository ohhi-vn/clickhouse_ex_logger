defmodule Mix.Tasks.ClickhouseExLogger.Migrate do
  @shortdoc "Creates the ClickHouse database and the `logs` table"

  @moduledoc """
  Creates the ClickHouse database and the `logs` table that
  `ClickhouseExLogger.Handler` writes to.

      mix clickhouse_ex_logger.migrate
      mix clickhouse_ex_logger.migrate --dry-run

  Run this from your host application **before** you attach the handler.

  ## Why this task and not `mix ash_clickhouse.migrate`

  `mix ash_clickhouse.migrate` finds AshClickhouse resources by listing the
  modules of the *current* Mix project, so it never sees
  `ClickhouseExLogger.LogEntry` — that resource belongs to the `clickhouse_ex_logger`
  dependency. This task targets it explicitly.

  It delegates to `ClickhouseExLogger.Migration`, which starts a connection,
  creates the database if it is missing, and then applies the versioned
  migration files this library ships under `priv/repo/migrations` through
  `AshClickhouse.MigrationRunner`. The `CREATE TABLE` statement itself is
  generated from the resource by `AshClickhouse.Migration.create_table_cql/1`,
  so the table never drifts from the resource definition.

  Applied migrations are recorded in ClickHouse's `schema_migrations` table, so
  re-running this task is a no-op.

  ## In a release, use `ClickhouseExLogger.Utils.migrate/1`

  This task needs Mix, which a production release does not have. Run the same
  operation from the release instead:

      bin/my_app eval "ClickhouseExLogger.Utils.migrate()"

  Same migrations, same configuration, same outcome — reported through `Logger`
  rather than through `Mix.shell/0`.

  ## Run this again when you upgrade

  A later version of this library writes a `node` column that tables created by
  an earlier version do not have. ClickHouse rejects the whole batch with
  `No such column node in table`, and because nothing raises in your application
  the symptom is only that rows start disappearing from the `lost` counter.

  So run this task as part of every deploy, before the new version starts
  logging. The same command you already run — it just has to run again, because
  a migration is skipped once its version is recorded and a column added by a new
  version of the resource cannot come from a migration that will never re-run.
  In a release, that is `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"`.
  """

  use Mix.Task

  @switches [dry_run: :boolean]
  @aliases [d: :dry_run]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    Mix.Task.run("app.config", ["--no-start"])

    case ClickhouseExLogger.Migration.setup(opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "ClickhouseExLogger schema is up to date: #{length(summary.applied)} applied, " <>
            "#{length(summary.skipped)} already applied."
        )

      {:error, reason} ->
        Mix.raise("""
        Could not create the ClickhouseExLogger schema.

        #{format_reason(reason)}

        Check that:
          * `CLICKHOUSE_URL` (or your `config :clickhouse_ex_logger, ClickhouseExLogger.Repo`)
            points at a reachable ClickHouse server
          * `:url`, `:username` and `:password` are correct
          * `:database` names a database you are allowed to create
        """)
    end
  end

  defp format_reason(reason), do: if(is_binary(reason), do: reason, else: inspect(reason))
end
