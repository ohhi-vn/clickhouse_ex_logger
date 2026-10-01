defmodule ClickhouseLogger.ResourceTest do
  @moduledoc """
  Verifies the repo/domain/resource wiring the rest of the library depends on.
  """

  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Dsl

  describe "ClickhouseLogger.Repo/0 configuration" do
    test "reads the values this application configured" do
      config = Application.fetch_env!(:clickhouse_logger, ClickhouseLogger.Repo)

      assert ClickhouseLogger.Repo.config() == config
    end

    test "reports the configured database and OTP app" do
      assert ClickhouseLogger.Repo.database() ==
               Keyword.fetch!(
                 Application.fetch_env!(:clickhouse_logger, ClickhouseLogger.Repo),
                 :database
               )

      assert ClickhouseLogger.Repo.otp_app() == :clickhouse_logger
    end

    test "is discoverable as an AshClickhouse repo" do
      assert ClickhouseLogger.Repo.__ash_clickhouse_repo__()
    end
  end

  describe "ClickhouseLogger.Domain/0" do
    test "declares the log entry resource" do
      assert Ash.Domain.Info.resource(
               ClickhouseLogger.Domain,
               ClickhouseLogger.LogEntry
             ) == {:ok, ClickhouseLogger.LogEntry}
    end

    test "declares no other resource" do
      assert Ash.Domain.Info.resources(ClickhouseLogger.Domain) == [ClickhouseLogger.LogEntry]
    end
  end

  describe "ClickhouseLogger.LogEntry ClickHouse DSL" do
    test "targets the logs table through ClickhouseLogger.Repo" do
      assert Dsl.table(ClickhouseLogger.LogEntry) == "logs"
      assert Dsl.repo(ClickhouseLogger.LogEntry) == ClickhouseLogger.Repo
    end

    test "uses a MergeTree engine ordered by timestamp" do
      assert Dsl.engine(ClickhouseLogger.LogEntry) == "MergeTree()"
      assert Dsl.order_by(ClickhouseLogger.LogEntry) == "timestamp"
    end

    test "is included in migrations" do
      assert Dsl.migrate?(ClickhouseLogger.LogEntry)
    end

    test "does not set an unsupported partition or primary key" do
      assert Dsl.partition_by(ClickhouseLogger.LogEntry) == nil
      assert Dsl.primary_key(ClickhouseLogger.LogEntry) == nil
    end
  end

  describe "ClickhouseLogger.LogEntry insert options" do
    test "asks ClickHouse to batch server-side but still confirms the write" do
      assert Dsl.insert_opts(ClickhouseLogger.LogEntry) == [
               async_insert: 1,
               wait_for_async_insert: 1
             ]
    end

    test "the data layer forwards them to the repo insert" do
      assert AshClickhouse.DataLayer.Insert.insert_opts(ClickhouseLogger.LogEntry, [])
             |> Enum.sort() ==
               [async_insert: 1, wait_for_async_insert: 1]
    end

    test "a caller can still override them per insert" do
      assert AshClickhouse.DataLayer.Insert.insert_opts(ClickhouseLogger.LogEntry,
               async_insert: 0
             )
             |> Enum.sort() == [async_insert: 0, wait_for_async_insert: 1]
    end
  end

  describe "ClickhouseLogger.LogEntry attributes" do
    test "has exactly the documented row shape" do
      attributes =
        ClickhouseLogger.LogEntry
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert attributes == [
               :file,
               :function,
               :id,
               :level,
               :line,
               :message,
               :metadata,
               :module,
               :timestamp
             ]
    end

    test "id is a generated UUID primary key" do
      id = Ash.Resource.Info.attribute(ClickhouseLogger.LogEntry, :id)

      assert id.primary_key?
      assert id.type == Ash.Type.UUID
      assert id.allow_nil? == false
    end

    test "timestamp, level and message are required" do
      for name <- [:timestamp, :level, :message, :metadata] do
        assert Ash.Resource.Info.attribute(ClickhouseLogger.LogEntry, name).allow_nil? == false,
               "expected #{name} to be required"
      end
    end

    test "source location attributes are optional" do
      for name <- [:module, :file, :line, :function] do
        assert Ash.Resource.Info.attribute(ClickhouseLogger.LogEntry, name).allow_nil?,
               "expected #{name} to be optional"
      end
    end
  end

  describe "generated DDL" do
    setup do
      %{cql: AshClickhouse.Migration.create_table_cql(ClickhouseLogger.LogEntry)}
    end

    test "creates the table with IF NOT EXISTS", %{cql: cql} do
      assert cql =~ ~s|CREATE TABLE IF NOT EXISTS `logs`|
    end

    test "orders by timestamp", %{cql: cql} do
      assert cql =~ "ORDER BY (timestamp)"
    end

    test "uses the MergeTree engine", %{cql: cql} do
      assert cql =~ "ENGINE = MergeTree()"
    end

    test "maps timestamp to DateTime64(6)", %{cql: cql} do
      assert cql =~ "`timestamp` DateTime64(6)"
    end

    test "maps id to UUID", %{cql: cql} do
      assert cql =~ "`id` UUID"
    end

    test "maps line to a nullable Int64", %{cql: cql} do
      assert cql =~ "`line` Nullable(Int64)"
    end

    test "maps metadata to a Map of strings", %{cql: cql} do
      assert cql =~ "`metadata` Map(String, String)"
    end
  end
end
