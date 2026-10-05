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

  describe "domain inclusion suppression" do
    # `ClickhouseExLogger.Domain` and `ClickhouseExLogger.LogEntry` set Ash's
    # `validate_*_inclusion?` options, because a host compiling this package has
    # no `:ash_domains` entry to add and so cannot resolve the report Ash would
    # otherwise print into its build.
    #
    # What these tests establish is that the option is scoped to *those two*
    # modules. The global alternative — `config :ash, validate_domain_resource_inclusion?: false`
    # — would silence the check for every resource and domain in the host's project
    # too, which is a real loss of signal and not this library's call to make.
    #
    # Each pair compiles two probes differing only in the option, against a domain
    # that declares no resources at all — so a probe resource is genuinely outside
    # every known domain, which is the situation a host's own resource is in. They
    # are compiled at runtime rather than in `test/support` because the report is
    # emitted while the module compiles, and only a compile performed inside
    # `capture_io` can be asserted on.

    @empty_domain ClickhouseExLogger.EmptyDomainProbe
    @reported ClickhouseExLogger.ReportedResourceProbe
    @suppressed ClickhouseExLogger.SuppressedResourceProbe
    @reported_domain ClickhouseExLogger.ReportedDomainProbe
    @suppressed_domain ClickhouseExLogger.SuppressedDomainProbe

    test "a resource outside every known domain is still reported" do
      report = capture_resource_compile(@reported, validate: false)

      assert report =~ "is not present in any known Ash.Domain module"
      assert report =~ inspect(@reported)
    end

    test "the same resource with the option set is not reported" do
      refute capture_resource_compile(@suppressed, validate: true) =~
               "is not present in any known Ash.Domain module"
    end

    test "a domain outside the configured list is still reported" do
      report = capture_domain_compile(@reported_domain, validate: false)

      assert report =~ "is not present in"
      assert report =~ inspect(@reported_domain)
    end

    test "the same domain with the option set is not reported" do
      refute capture_domain_compile(@suppressed_domain, validate: true) =~ "is not present in"
    end

    # Compiles a resource shaped like `ClickhouseExLogger.LogEntry` and returns
    # whatever that compile wrote to stderr.
    defp capture_resource_compile(module, opts) do
      options =
        ["data_layer: AshClickhouse.DataLayer", "domain: #{inspect(@empty_domain)}"]
        |> maybe_validate(opts[:validate])
        |> Enum.join(",\n    ")

      capture_compile("""
      defmodule #{inspect(module)} do
        use Ash.Resource,
          #{options}

        attributes do
          uuid_primary_key(:id, public?: true, writable?: true)
        end

        actions do
          create :create do
            primary?(true)
            accept([:id])
          end
        end
      end
      """)
    end

    defp capture_domain_compile(module, opts) do
      options =
        case opts[:validate] do
          true -> "Ash.Domain, validate_config_inclusion?: false"
          _ -> "Ash.Domain"
        end

      capture_compile("""
      defmodule #{inspect(module)} do
        use #{options}
      end
      """)
    end

    defp capture_compile(source) do
      ensure_empty_domain()

      ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)
    end

    # `Ash.Resource`'s check reads `Ash.Domain.Info.allow_unregistered?/1` and the
    # resource list off the compiled domain, so the domain has to exist before the
    # resource naming it is compiled. It declares nothing, so every probe resource
    # is outside it.
    #
    # Its own inclusion report is expected and irrelevant to every assertion here,
    # so it is captured and discarded. Left to the caller's capture it would land
    # in whichever assertion happened to run first and make the result depend on
    # test order.
    defp ensure_empty_domain do
      unless Code.ensure_loaded?(@empty_domain) do
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule #{inspect(@empty_domain)} do
            use Ash.Domain
          end
          """)
        end)
      end

      :ok
    end

    # Left off entirely rather than set to `true`, so the reported case is the one
    # a host's own resource actually hits: the default.
    defp maybe_validate(options, true), do: options ++ ["validate_domain_inclusion?: false"]
    defp maybe_validate(options, _validate), do: options
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
