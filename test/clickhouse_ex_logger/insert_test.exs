defmodule ClickhouseExLogger.InsertTest do
  @moduledoc """
  Verifies `ClickhouseExLogger.Insert.insert/1`'s contract.

  The parts that matter to the rest of the library are the return shape and the
  committed-row count: `ClickhouseExLogger.Buffer` derives `delivered` and `lost`
  from them, and `clickhouse-log-handler` requires
  `accepted == delivered + discarded + lost` to hold exactly.

  A flush is chunked at 1000 rows and stops at the first chunk that fails, so
  `{:error, message, committed}` has to be *earned* here: chunk one committing
  while chunk two is refused. That is arranged with a row the server rejects —
  an `id` that is not a UUID — placed past the chunk boundary, rather than by
  stubbing the client.

  Synchronous: truncates `logs` and writes to the shared container.
  """

  use ClickhouseExLogger.Case

  alias ClickhouseExLogger.Insert
  alias ClickhouseExLogger.LogEntry
  alias ClickhouseExLogger.TestServer

  setup do
    truncate_logs!()

    # This module repoints the shared repo connection; put it back whatever happens,
    # so a failure here cannot leave later modules without one.
    on_exit(&restart_repo_connection/0)

    :ok
  end

  describe "insert/1 with nothing to write" do
    test "is a no-op that never reaches the server" do
      assert Insert.insert([]) == {:ok, 0}
    end
  end

  describe "insert/1 timestamp handling" do
    test "passes an already-encoded timestamp through untouched" do
      # `normalize/1` re-encodes a `DateTime` because the data layer's encoder
      # overflows `DateTime64(6)`; anything else is handed on as written.
      at = ~U[2026-01-02 03:04:05.000006Z]

      assert {:ok, 1} =
               Insert.insert([row("encoded", %{timestamp: DateTime.to_iso8601(at)})])

      assert TestServer.query!("SELECT toString(timestamp) FROM logs") |> String.trim() ==
               "2026-01-02 03:04:05.000006"
    end

    test "encodes a DateTime at full microsecond precision" do
      assert {:ok, 1} =
               Insert.insert([row("naive", %{timestamp: ~U[2026-01-02 03:04:05.000006Z]})])

      assert TestServer.query!("SELECT toString(timestamp) FROM logs") |> String.trim() ==
               "2026-01-02 03:04:05.000006"
    end
  end

  describe "insert/1 across the chunk boundary" do
    test "writes more than one chunk and reports every row committed" do
      rows = Enum.map(1..2_500, &row("chunked-#{&1}"))

      assert Insert.insert(rows) == {:ok, 2_500}
      assert stored_count() == "2500"
    end

    test "reports the rows an earlier chunk committed when a later one is refused" do
      # 1000 good rows, then one the server rejects. Chunk one commits; chunk
      # two is refused and is not retried, so exactly 1000 rows are committed.
      rows =
        Enum.map(1..1_000, &row("committed-#{&1}")) ++
          [Map.put(row("rejected"), :id, "not-a-uuid")]

      assert {:error, message, 1_000} = Insert.insert(rows)

      assert is_binary(message)
      assert message =~ "Cannot parse UUID"

      # The committed chunk is really in ClickHouse, not merely accounted for.
      assert stored_count() == "1000"
    end
  end

  describe "insert/1 error reporting" do
    test "reports the server's complaint rather than swallowing it" do
      assert {:error, message, 0} = Insert.insert([Map.put(row("bad"), :id, "nope")])

      assert message =~ "Cannot parse UUID"
      assert message =~ "CANNOT_PARSE_UUID"
    end

    test "reports the reason when the database does not exist" do
      # The server answers UNKNOWN_DATABASE, which reaches `describe/1` as a
      # client error struct rather than a raised exception.
      original = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      Application.put_env(
        :clickhouse_ex_logger,
        ClickhouseExLogger.Repo,
        Keyword.put(original, :database, "clickhouse_ex_logger_absent_database")
      )

      restart_repo_connection()

      on_exit(fn ->
        Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
        restart_repo_connection()
      end)

      assert {:error, message, 0} = Insert.insert([row("absent")])
      assert message =~ "UNKNOWN_DATABASE"

      # The reason an operator reads is the server's text, not an inspection of the
      # client's error struct. `inspect/1` happens to *contain* the server's text
      # too, so matching on the text alone does not tell the two apart — reading a
      # `%ClickHouse.DatabaseError{…}` to find out why your logs stopped is not a
      # diagnosable failure.
      refute inspect_error_struct?(message)
    end

    test "reports the client's own message when the server cannot be reached" do
      # Nothing is listening on this port, so the client returns a connection error
      # struct. The clause in `describe/1` that matched only a *raised* wrapped
      # error never fired for this, which is the ordinary path for an unreachable
      # server — the most common failure a host has to diagnose.
      original = Application.fetch_env!(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

      Application.put_env(
        :clickhouse_ex_logger,
        ClickhouseExLogger.Repo,
        Keyword.put(original, :url, "http://127.0.0.1:1")
      )

      restart_repo_connection()

      on_exit(fn ->
        Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
        restart_repo_connection()
      end)

      assert {:error, message, 0} = Insert.insert([row("unreachable")])

      assert is_binary(message)
      refute inspect_error_struct?(message)
    end

    test "reports the client's own message when the connection is gone" do
      # The connection is registered per repo module, so stopping it leaves the name
      # resolvable but the client's state table behind. The client answers with a
      # bare string rather than an error struct, which is the other shape
      # `describe/1` has to pass through unchanged.
      stop_repo_connection()

      assert {:error, message, 0} = Insert.insert([row("no-connection")])

      assert is_binary(message)
      assert String.trim(message) != ""
      refute inspect_error_struct?(message)
    end
  end

  describe "insert/1 field names come from the resource" do
    # `insert/1` converts each row's field names to wire form once per flush, from
    # the resource's own attribute list. These pin the consequence: a wrong name in
    # that list is not a cosmetic difference — the encoder looks the row up by
    # string key, so a name it does not recognise leaves the column null. Writing a
    # fully-populated row and reading every column back is what catches that.

    test "every field's value lands in its own column" do
      at = ~U[2026-01-02 03:04:05.000006Z]
      id = Ash.UUID.generate()

      assert {:ok, 1} =
               Insert.insert([
                 %{
                   id: id,
                   timestamp: at,
                   level: :warning,
                   message: "every-column",
                   module: "MyApp.Worker",
                   file: "/app/lib/my_app/worker.ex",
                   line: 4242,
                   function: "run/2",
                   metadata: %{"user_id" => "7"},
                   node: "my_app@10.0.0.5"
                 }
               ])

      stored =
        TestServer.query!(
          "SELECT toString(id), toString(timestamp), level, message, module, file, " <>
            "toString(line), function, metadata['user_id'], node FROM logs"
        )
        |> String.trim()
        |> String.split("\t")

      assert stored == [
               to_string(id),
               "2026-01-02 03:04:05.000006",
               "warning",
               "every-column",
               "MyApp.Worker",
               "/app/lib/my_app/worker.ex",
               "4242",
               "run/2",
               "7",
               "my_app@10.0.0.5"
             ]
    end

    test "a field the resource does not define does not become a column" do
      # If the column list were restated in `ClickhouseExLogger.Insert`, this key
      # would either raise or grow a column. Driven by the resource, it is ignored.
      assert {:ok, 1} = Insert.insert([Map.put(row("extra"), :not_a_column, "ignored")])

      assert table_columns() == resource_columns()
      refute "not_a_column" in table_columns()
    end

    test "the table's columns are the resource's, in the resource's order" do
      assert table_columns() == resource_columns()
    end
  end

  # The resource's attributes as wire-form names — compared as strings because
  # `DESCRIBE TABLE` reports strings and comparing terms across the two would fail
  # on their types rather than on the thing under test.
  defp resource_columns do
    LogEntry
    |> Ash.Resource.Info.attributes()
    |> Enum.map(&to_string(&1.name))
  end

  defp table_columns do
    TestServer.query!("DESCRIBE TABLE logs")
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.split("\t") |> hd() end)
  end

  defp stored_count, do: TestServer.query!("SELECT count() FROM logs") |> String.trim()

  defp row(message, overrides \\ %{}) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        timestamp: DateTime.utc_now(),
        level: :info,
        message: message,
        module: "InsertTest",
        file: "insert_test.exs",
        line: 1,
        function: "row/2",
        metadata: %{},
        node: nil
      },
      overrides
    )
  end

  defp restart_repo_connection do
    stop_repo_connection()

    {:ok, conn} =
      AshClickhouse.Connection.start_link(
        AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)
      )

    Process.unlink(conn)

    :ok
  end

  defp stop_repo_connection do
    try do
      AshClickhouse.Connection.stop(ClickhouseExLogger.Repo)
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  # Whether a message is an inspected struct rather than a reason. A struct's
  # `inspect/1` output starts with `%Module{`, which no client or server message
  # does.
  defp inspect_error_struct?(message) do
    String.starts_with?(String.trim_leading(message), "%")
  end
end
