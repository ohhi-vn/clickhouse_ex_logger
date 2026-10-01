defmodule ClickhouseExLogger.TestServerTest do
  @moduledoc """
  Verifies the ClickHouse test harness itself, so a red suite can be told apart
  from a broken environment.
  """

  use ExUnit.Case, async: true

  alias ClickhouseExLogger.TestContainer
  alias ClickhouseExLogger.TestServer

  test "reads the URL and database from the application config" do
    config = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

    assert TestServer.url() == Keyword.fetch!(config, :url)
    assert TestServer.database() == Keyword.fetch!(config, :database)
  end

  test "points at the container the suite started, not a fixed port" do
    assert TestServer.url() == TestContainer.url()
    assert TestServer.database() == TestContainer.database()
  end

  test "the container's schema is in place" do
    assert TestServer.table_exists?()
  end

  @tag :clickhouse
  test "round-trips a query against the configured server" do
    assert TestServer.query!("SELECT 1") =~ "1"
  end
end
