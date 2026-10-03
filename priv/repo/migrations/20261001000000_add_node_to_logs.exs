defmodule ClickhouseExLogger.Migrations.AddNodeToLogsTable do
  @moduledoc """
  Adds the `node` column to the `logs` table.

  Run it with `mix clickhouse_ex_logger.migrate`. See `README.md`.

  ## Why this is a separate migration

  `20260101000000_create_logs.exs` generates its `CREATE TABLE` from
  `ClickhouseExLogger.LogEntry`, so it *would* create the `node` column — on a
  database that has not run it yet.

  Existing databases will never run it again. `AshClickhouse.MigrationRunner`
  tracks applied migrations by version in ClickHouse's `schema_migrations` table,
  and every host that already has a `logs` table has recorded `20260101000000`.
  So the column has to arrive as a new migration, and that one is left alone:
  changing its version would re-issue `CREATE TABLE` against tables that exist.

  ## Why `change/0` is additive and derived

  `AshClickhouse.Migration.alter_table_cql/2` compares the resource's attributes
  against `system.columns` and emits `ALTER TABLE … ADD COLUMN IF NOT EXISTS` for
  whatever is missing. It never drops or retypes a column, by design, so this
  cannot damage data on a database that predates the column — and it is empty
  against one that already has it, making a re-run a no-op.

  Deriving the statement from the resource rather than hardcoding it is what
  keeps the column's type from drifting from the attribute definition.

  It needs a live repo connection to read `system.columns`.
  `ClickhouseExLogger.Migration.setup/1` starts one before applying migrations,
  including under `--dry-run`, so a dry run can report the statement it would run.

  ## Why `down/0` is hand-written

  `AshClickhouse.Migration.reverse_statement/1` reverses an
  `ADD COLUMN IF NOT EXISTS` into `DROP COLUMN IF NOT EXISTS`. ClickHouse has no
  such syntax — it accepts `DROP COLUMN IF EXISTS` — and rejects the other with:

      Code: 62. DB::Exception: Syntax error: failed at position 30 (NOT):
      NOT EXISTS node. Expected one of: EXISTS, token sequence, … (SYNTAX_ERROR)

  Verified against ClickHouse 26.9. So the reversal is written out here rather
  than derived. Do not "simplify" it back into a `reverse_statement/1` call; that
  produces SQL the server will not accept.

  The pre-existing create-table migration still uses `reverse_statement/1` and is
  unaffected, because its statement is `CREATE TABLE`, whose reversal is valid.
  """

  @behaviour AshClickhouse.Schema

  @version "20261001000000"

  @table "logs"

  @doc "The repo this migration targets."
  @impl true
  def repo, do: ClickhouseExLogger.Repo

  @doc """
  The migration version, recorded in ClickHouse's `schema_migrations` table so
  this migration is applied at most once.
  """
  @impl true
  def version, do: @version

  @doc """
  Adds any resource attribute the table is missing.

  Empty once `node` is present, so applying this to an already-migrated database
  changes nothing.
  """
  @impl true
  def change do
    AshClickhouse.Migration.alter_table_cql(ClickhouseExLogger.LogEntry, repo())
  end

  @doc """
  Drops the `node` column.

  Written out rather than derived from `change/0` — see the module doc for the
  `reverse_statement/1` defect that makes the derived form invalid SQL.
  """
  @impl true
  def down do
    ["ALTER TABLE #{@table} DROP COLUMN IF EXISTS node"]
  end
end
