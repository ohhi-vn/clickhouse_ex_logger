defmodule ClickhouseLogger.TestServerTest do
  @moduledoc """
  Verifies the ClickHouse test harness itself, so a red suite can be told apart
  from a broken environment.
  """

  use ExUnit.Case, async: true

  alias ClickhouseLogger.TestServer

  test "reads the URL and database from the application config" do
    config = Application.fetch_env!(:clickhouse_logger, ClickhouseLogger.Repo)

    assert TestServer.url() == Keyword.fetch!(config, :url)
    assert TestServer.database() == Keyword.fetch!(config, :database)
  end

  test "reports whether the configured server answers" do
    assert is_boolean(TestServer.available?())
  end

  test "explains how to start a server when there is not one" do
    message = TestServer.unavailable_message()

    assert message =~ "no ClickHouse server at #{TestServer.url()}"
    assert message =~ "CLICKHOUSE_URL"
  end

  @tag :clickhouse
  test "round-trips a query against the configured server" do
    assert TestServer.query!("SELECT 1") =~ "1"
  end
end
