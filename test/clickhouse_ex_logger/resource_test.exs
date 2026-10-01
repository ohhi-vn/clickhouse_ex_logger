defmodule ClickhouseExLogger.ResourceTest do
  @moduledoc """
  Verifies the repo/domain/resource wiring the rest of the library depends on.
  """

  use ExUnit.Case, async: true

  alias AshClickhouse.DataLayer.Dsl

  describe "ClickhouseExLogger.Repo/0 configuration" do
    test "reads the values this application configured" do
      config = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      assert ClickhouseExLogger.Repo.config() == config
    end

    test "reports the configured database and OTP app" do
      assert ClickhouseExLogger.Repo.database() ==
               Keyword.fetch!(
                 Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo),
                 :database
               )

      assert ClickhouseExLogger.Repo.otp_app() == :clickhouse_ex_logger
    end

    test "is discoverable as an AshClickhouse repo" do
      assert ClickhouseExLogger.Repo.__ash_clickhouse_repo__()
    end
  end

  describe "ClickhouseExLogger.Domain/0" do
    test "declares the log entry resource" do
      assert Ash.Domain.Info.resource(
               ClickhouseExLogger.Domain,
               ClickhouseExLogger.LogEntry
             ) == {:ok, ClickhouseExLogger.LogEntry}
    end

    test "declares no other resource" do
      assert Ash.Domain.Info.resources(ClickhouseExLogger.Domain) == [ClickhouseExLogger.LogEntry]
    end
  end

  describe "ClickhouseExLogger.LogEntry ClickHouse DSL" do
    test "targets the logs table through ClickhouseExLogger.Repo" do
      assert Dsl.table(ClickhouseExLogger.LogEntry) == "logs"
      assert Dsl.repo(ClickhouseExLogger.LogEntry) == ClickhouseExLogger.Repo
    end

    test "uses a MergeTree engine ordered by timestamp" do
      assert Dsl.engine(ClickhouseExLogger.LogEntry) == "MergeTree()"
      assert Dsl.order_by(ClickhouseExLogger.LogEntry) == "timestamp"
    end

    test "is included in migrations" do
      assert Dsl.migrate?(ClickhouseExLogger.LogEntry)
    end

    test "does not set an unsupported partition or primary key" do
      assert Dsl.partition_by(ClickhouseExLogger.LogEntry) == nil
      assert Dsl.primary_key(ClickhouseExLogger.LogEntry) == nil
    end
  end

  describe "ClickhouseExLogger.LogEntry insert options" do
    test "asks ClickHouse to batch server-side but still confirms the write" do
      assert Dsl.insert_opts(ClickhouseExLogger.LogEntry) == [
               async_insert: 1,
               wait_for_async_insert: 1
             ]
    end

    test "the data layer forwards them to the repo insert" do
      assert AshClickhouse.DataLayer.Insert.insert_opts(ClickhouseExLogger.LogEntry, [])
             |> Enum.sort() ==
               [async_insert: 1, wait_for_async_insert: 1]
    end

    test "a caller can still override them per insert" do
      assert AshClickhouse.DataLayer.Insert.insert_opts(ClickhouseExLogger.LogEntry,
               async_insert: 0
             )
             |> Enum.sort() == [async_insert: 0, wait_for_async_insert: 1]
    end
  end

  describe "ClickhouseExLogger.LogEntry attributes" do
    test "has exactly the documented row shape" do
      attributes =
        ClickhouseExLogger.LogEntry
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
               :node,
               :timestamp
             ]
    end

    test "id is a generated UUID primary key" do
      id = Ash.Resource.Info.attribute(ClickhouseExLogger.LogEntry, :id)

      assert id.primary_key?
      assert id.type == Ash.Type.UUID
      assert id.allow_nil? == false
    end

    test "timestamp, level and message are required" do
      for name <- [:timestamp, :level, :message, :metadata] do
        assert Ash.Resource.Info.attribute(ClickhouseExLogger.LogEntry, name).allow_nil? == false,
               "expected #{name} to be required"
      end
    end

    test "source location attributes are optional" do
      for name <- [:module, :file, :line, :function] do
        assert Ash.Resource.Info.attribute(ClickhouseExLogger.LogEntry, name).allow_nil?,
               "expected #{name} to be optional"
      end
    end

    test "node is optional, because it is genuinely absent in two cases" do
      # Absent for a system that is not distributed, and for a host that disabled
      # capture with `:include_node`. `allow_nil?: true` is what makes the column
      # `Nullable(String)`; a non-null column would force a placeholder value.
      assert Ash.Resource.Info.attribute(ClickhouseExLogger.LogEntry, :node).allow_nil?
    end

    test "node is declared last, so a fresh table matches a migrated one" do
      attributes =
        ClickhouseExLogger.LogEntry
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)

      # `alter_table_cql/2` appends columns, so a migrated table has `node` after
      # `metadata`. Declaring it anywhere else would give a freshly created table
      # a different `SELECT *` order from a migrated one.
      assert List.last(attributes) == :node
    end
  end

  describe "generated DDL" do
    setup do
      %{cql: AshClickhouse.Migration.create_table_cql(ClickhouseExLogger.LogEntry)}
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
