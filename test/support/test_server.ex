defmodule ClickhouseExLogger.TestServer do
  @moduledoc """
  Test-only helper for talking to the suite's ClickHouse.

  Compiled into the test build only (see `elixirc_paths/1` in `mix.exs`), never
  shipped in the hex package.

  Everything here goes through `ClickhouseExLogger.Repo`, so the suite exercises
  the same code path a host application uses rather than a parallel one. The
  connection points at a container started by
  `ClickhouseExLogger.TestContainer` — see `test/test_helper.exs`.
  """

  @doc """
  The ClickHouse URL the suite talks to.
  """
  @spec url() :: String.t()
  def url, do: repo_config() |> Keyword.fetch!(:url)

  @doc """
  The database the suite writes to.
  """
  @spec database() :: String.t()
  def database, do: repo_config() |> Keyword.fetch!(:database)

  @doc """
  Whether the `logs` table exists in the test database.
  """
  @spec table_exists?() :: boolean()
  def table_exists?, do: query!("EXISTS TABLE #{qualified_logs()}") == "1\n"

  @doc """
  Removes every row from the `logs` table.
  """
  @spec truncate_logs!() :: :ok
  def truncate_logs! do
    query!("TRUNCATE TABLE #{qualified_logs()}")
    :ok
  end

  @doc """
  Runs a ClickHouse query and returns the response body as tab-separated text.

  The data layer's own default format is `JSONCompactEachRow`, which would wrap
  every scalar in JSON. Tests assert on plain values, so ask for TSV.
  """
  @spec query!(String.t()) :: String.t()
  def query!(sql) do
    opts = [database: database(), default_format: "TabSeparated"]

    case ClickhouseExLogger.Repo.query(sql, [], opts) do
      {:ok, result} ->
        result.raw

      {:error, reason} ->
        raise "ClickHouse query failed: #{inspect(reason)}\nSQL: #{sql}"
    end
  end

  @doc """
  Runs a query against ClickHouse's `system` database.

  Use this to inspect the server itself (which databases and tables exist)
  without depending on the configured database being reachable.
  """
  @spec system_query!(String.t()) :: String.t()
  def system_query!(sql) do
    case ClickhouseExLogger.Repo.query(sql, [], database: "system", default_format: "TabSeparated") do
      {:ok, result} -> result.raw
      {:error, reason} -> raise "ClickHouse query failed: #{inspect(reason)}\nSQL: #{sql}"
    end
  end

  defp qualified_logs, do: "#{database()}.logs"

  defp repo_config, do: Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)
end
