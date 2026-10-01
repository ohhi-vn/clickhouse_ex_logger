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
  alias ClickhouseExLogger.TestServer

  setup do
    truncate_logs!()
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
      assert {:ok, 1} = Insert.insert([row("naive", %{timestamp: ~U[2026-01-02 03:04:05.000006Z]})])

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
    end
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
    try do
      AshClickhouse.Connection.stop(ClickhouseExLogger.Repo)
    catch
      :exit, _reason -> :ok
    end

    {:ok, conn} =
      AshClickhouse.Connection.start_link(
        AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)
      )

    Process.unlink(conn)

    :ok
  end
end