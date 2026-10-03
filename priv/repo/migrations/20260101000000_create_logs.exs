defmodule ClickhouseExLogger.Migrations.CreateLogsTable do
  @moduledoc """
  Creates the `logs` table.

  Run it with `mix clickhouse_ex_logger.migrate`. See `README.md`.
  """

  @behaviour AshClickhouse.Schema

  @version "20260101000000"

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
  The `CREATE TABLE` statement.

  Generated from `ClickhouseExLogger.LogEntry` by
  `AshClickhouse.Migration.create_table_cql/1`, so the table and the resource
  cannot drift apart. Do not hand-edit this.
  """
  @impl true
  def change do
    [AshClickhouse.Migration.create_table_cql(ClickhouseExLogger.LogEntry)]
  end

  @doc "Rolls the migration back by dropping the table."
  @impl true
  def down do
    Enum.map(change(), &AshClickhouse.Migration.reverse_statement/1)
    |> Enum.reject(&is_nil/1)
  end
end
