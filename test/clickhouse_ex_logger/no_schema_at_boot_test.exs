defmodule ClickhouseExLogger.NoSchemaAtBootTest do
  @moduledoc """
  Verifies the library never creates or alters ClickHouse schema at runtime.

  This is the requirement that keeps the library safe to depend on: an app that
  boots must not touch its database, and a library that did so would be doing DDL
  behind its host's back with no migration in the review path.

  The test points the repo at a database that does not exist, starts the handler
  and buffer exactly as an application would, writes rows, and then asserts the
  database was never created.
  """

  use ClickhouseExLogger.Case

  require Logger

  @moduletag :capture_log

  alias ClickhouseExLogger.{Buffer, Handler}

  @absent_database "clickhouse_ex_logger_never_created_at_boot"

  setup do
    refute database_exists?(@absent_database)

    handler_id = String.to_atom("clickhouse_ex_logger_boot_#{System.unique_integer([:positive])}")
    original = Application.get_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo)

    Application.put_env(
      :clickhouse_ex_logger,
      ClickhouseExLogger.Repo,
      Keyword.put(original, :database, @absent_database)
    )

    restart_repo_connection()

    on_exit(fn ->
      Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, original)
      restart_repo_connection()
      _ = Handler.uninstall(handler_id)
    end)

    %{handler_id: handler_id}
  end

  # Queried against `system`, not the configured database: the point is that the
  # configured database may not exist at all.
  defp database_exists?(database) do
    ClickhouseExLogger.TestServer.system_query!(
      "SELECT count() FROM system.databases WHERE name = '#{database}'"
    )
    |> String.trim() == "1"
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

  defp eventually(fun, attempts \\ 300) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  test "installing the handler creates no database", %{handler_id: handler_id} do
    refute database_exists?(@absent_database)

    {:ok, ^handler_id} = Handler.install(handler_id, %{batch_size: 2})

    # Starting the repo, the buffer and the handler changed nothing in
    # ClickHouse's schema.
    refute database_exists?(@absent_database),
           "installing the handler created #{@absent_database}"
  end

  test "logging rows creates no database", %{handler_id: handler_id} do
    {:ok, _} = Handler.install(handler_id, %{batch_size: 2, flush_interval_ms: 30})

    Logger.warning("a row that would need a table")

    # Let both the batch-size trigger and the interval fire. Every write fails,
    # because the database does not exist and nothing created it.
    eventually(fn -> Buffer.stats().failed > 0 end)

    refute database_exists?(@absent_database),
           "writing log rows created #{@absent_database}"
  end

  test "flushing on removal creates no database", %{handler_id: handler_id} do
    {:ok, _} =
      Handler.install(handler_id, %{batch_size: 10_000, flush_interval_ms: 60_000})

    Logger.warning("buffered, then flushed at shutdown")

    eventually(fn -> Buffer.stats().buffered == 1 end)

    :ok = Handler.uninstall(handler_id)

    refute database_exists?(@absent_database),
           "the shutdown flush created #{@absent_database}"
  end

  test "the startup readiness check creates no database", %{handler_id: handler_id} do
    # The readiness check is the one piece of this library that now runs at boot,
    # so it is the one piece that has to be shown not to write. It answers
    # `:absent` here — the configured database does not exist — and asking the
    # question must not be what brings it into being.
    assert ClickhouseExLogger.Migration.logs_table_status() == :absent

    refute database_exists?(@absent_database),
           "the startup readiness check created #{@absent_database}"

    _ = handler_id
  end

  test "the library has a boot callback now, and starting it writes no schema" do
    # This library used to declare no `mod:` at all, so the strongest available
    # argument was structural: there was no `Application.start/2`, therefore
    # nothing of ours could run at a host's boot. It declares one now, so that
    # argument is gone and the guarantee has to be observed instead — which is what
    # the tests above do, for each thing boot now does: read the table's presence,
    # install the handler, write a row, and flush.
    Mix.Task.rerun("app.config", ["--no-start"])

    assert Application.spec(:clickhouse_ex_logger, :mod) ==
             {ClickhouseExLogger.Application, []}

    refute database_exists?(@absent_database)
  end
end
