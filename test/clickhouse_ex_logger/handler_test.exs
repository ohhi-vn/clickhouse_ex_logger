defmodule ClickhouseExLogger.HandlerTest do
  @moduledoc """
  Verifies handler registration, configuration, and the promises the handler makes
  to the process that logs.
  """

  use ClickhouseExLogger.Case

  require Logger

  @moduletag :capture_log

  alias ClickhouseExLogger.Buffer
  alias ClickhouseExLogger.CaptureHandler
  alias ClickhouseExLogger.Handler

  setup do
    truncate_logs!()

    handler_id = String.to_atom("clickhouse_ex_logger_test_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :ok = Handler.uninstall(handler_id)
      on_exit_stop_buffer()
    end)

    %{handler_id: handler_id}
  end

  defp on_exit_stop_buffer do
    case GenServer.whereis(Buffer) do
      nil -> :ok
      _pid -> Buffer.stop()
    end
  end

  defp stored_count do
    ClickhouseExLogger.TestServer.query!("SELECT count() FROM logs") |> String.trim()
  end

  describe "install/2" do
    test "registers the handler and returns its id", %{handler_id: handler_id} do
      assert {:ok, ^handler_id} = Handler.install(handler_id, %{batch_size: 2})
      assert {:ok, %{module: ClickhouseExLogger.Handler}} = :logger.get_handler_config(handler_id)
    end

    test "starts the buffer", %{handler_id: handler_id} do
      refute GenServer.whereis(Buffer)

      assert {:ok, _} = Handler.install(handler_id, %{batch_size: 2})
      assert is_pid(GenServer.whereis(Buffer))
    end

    test "is idempotent for an already-registered id", %{handler_id: handler_id} do
      assert {:ok, ^handler_id} = Handler.install(handler_id, %{batch_size: 2})
      assert {:ok, ^handler_id} = Handler.install(handler_id, %{batch_size: 2})
    end

    test "does not start a second buffer when one is already running", %{
      handler_id: handler_id
    } do
      {:ok, buffer} =
        Buffer.start_link(%{batch_size: 1, flush_interval_ms: 60_000, max_buffer_size: 10})

      assert {:ok, ^handler_id} = Handler.install(handler_id, %{batch_size: 2})
      assert GenServer.whereis(Buffer) == buffer
    end

    test "defaults/0 is what an omitted batching config resolves to" do
      # The function is public but nothing called it, so a change to the defaults
      # would not have been noticed by the "applies documented defaults" test
      # above, which hard-codes the same numbers.
      assert Handler.defaults() == Handler.validate(%{}) |> elem(1)
    end
  end

  describe "the :buffer option" do
    test "sends rows to a host's own buffer instead of the named one", %{
      handler_id: handler_id
    } do
      # A buffer under a name of the host's choosing. `install/2` still starts
      # the named one — it owns the buffer lifecycle regardless — but with
      # `:buffer` set nothing is ever routed to it, so it stays empty and the row
      # in `logs` can only have come through the configured pid.
      {:ok, host_buffer} =
        GenServer.start_link(Buffer, %{batch_size: 1, flush_interval_ms: 60_000, max_buffer_size: 10})

      on_exit(fn -> if Process.alive?(host_buffer), do: Buffer.stop(host_buffer) end)

      assert {:ok, ^handler_id} =
               Handler.install(handler_id, %{batch_size: 2, buffer: host_buffer})

      Logger.info("through the host buffer")
      :ok = Buffer.flush(host_buffer, 5_000)

      assert Buffer.stats(host_buffer).delivered == 1
      assert Buffer.stats(Buffer).accepted == 0
      assert stored_count() == "1"
    end
  end

  describe "ensure_buffer_started/1" do
    test "rejects an invalid config, naming the option" do
      # Called directly: `install/2` validates before it gets here, so this is
      # the only way the function's own validation is reached.
      assert {:error, {:batch_size, message}} = Handler.ensure_buffer_started(%{batch_size: 0})
      assert message =~ "batch_size must be a positive integer"
    end

    test "starts a buffer from a valid config" do
      assert Handler.ensure_buffer_started(%{batch_size: 1, flush_interval_ms: 60_000}) == :ok
      assert is_pid(GenServer.whereis(Buffer))
    end

    test "leaves a running buffer alone" do
      {:ok, buffer} =
        Buffer.start_link(%{batch_size: 1, flush_interval_ms: 60_000, max_buffer_size: 10})

      # Different sizes, and the running buffer keeps its own: reconfiguring a
      # buffer that already holds rows would strand them.
      assert Handler.ensure_buffer_started(%{batch_size: 99}) == :ok
      assert GenServer.whereis(Buffer) == buffer
    end
  end

  describe "configuration validation" do
    test "applies documented defaults when omitted", %{handler_id: handler_id} do
      assert {:ok, ^handler_id} = Handler.install(handler_id)

      assert {:ok, options} = Handler.validate(%{})

      assert options == %{
               batch_size: 500,
               flush_interval_ms: 1_000,
               max_buffer_size: 10_000
             }
    end

    test "accepts a keyword list as well as a map" do
      assert {:ok, %{batch_size: 7}} = Handler.validate(batch_size: 7)
    end

    test "keeps explicitly configured values" do
      assert {:ok, options} =
               Handler.validate(%{
                 batch_size: 1,
                 flush_interval_ms: 2,
                 max_buffer_size: 3
               })

      assert options == %{batch_size: 1, flush_interval_ms: 2, max_buffer_size: 3}
    end

    for {option, value} <- [
          batch_size: 0,
          batch_size: -1,
          batch_size: 1.5,
          batch_size: "many",
          batch_size: nil,
          flush_interval_ms: 0,
          flush_interval_ms: -5,
          max_buffer_size: 0,
          max_buffer_size: -2,
          max_buffer_size: :big
        ] do
      test "rejects #{option} #{inspect(value)} naming the option" do
        assert {:error, {:batch_size, _}} = Handler.validate(%{batch_size: unquote(value)})

        assert {:error, {:flush_interval_ms, _}} =
                 Handler.validate(%{flush_interval_ms: unquote(value)})

        assert {:error, {:max_buffer_size, _}} =
                 Handler.validate(%{max_buffer_size: unquote(value)})
      end
    end

    test "rejects a bad value at registration, not later during delivery", %{
      handler_id: handler_id
    } do
      assert {:error, {:batch_size, message}} = Handler.install(handler_id, %{batch_size: -1})
      assert message =~ "batch_size"

      # Nothing was left running by the rejected install.
      refute GenServer.whereis(Buffer)
      refute match?({:ok, _}, :logger.get_handler_config(handler_id))
    end

    test "accepts include_node as a boolean, by default and explicitly" do
      assert :ok = Handler.validate_include_node(%{})
      assert :ok = Handler.validate_include_node(%{include_node: true})
      assert :ok = Handler.validate_include_node(%{include_node: false})
      assert :ok = Handler.validate_include_node(include_node: false)
    end

    test "rejects a non-boolean include_node rather than coercing it", %{
      handler_id: handler_id
    } do
      # `include_node: "no"` reading as enabled would silently record the node on
      # a host that asked not to, so it fails at install with the option named.
      assert {:error, {:include_node, message}} =
               Handler.install(handler_id, %{include_node: "no"})

      assert message =~ "include_node"
      assert message =~ "boolean"

      # Same shape as the batching errors, so a host sees one failure format.
      refute GenServer.whereis(Buffer)
      refute match?({:ok, _}, :logger.get_handler_config(handler_id))
    end

    test "include_node is not a buffer option" do
      # It decides whether a row records a value; the buffer never sees it, so it
      # must not widen `Buffer.options()`.
      assert {:ok, options} = Handler.validate(%{include_node: false})
      refute Map.has_key?(options, :include_node)
      assert Map.keys(options) |> Enum.sort() == [
               :batch_size,
               :flush_interval_ms,
               :max_buffer_size
             ]
    end
  end

  describe "log/2 does not write synchronously" do
    test "returns before anything reaches ClickHouse", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      Logger.info("not yet written")

      # The cast has been sent but the buffer has not been scheduled, so nothing
      # is stored and nothing blocked.
      assert Buffer.stats().buffered <= 1
      assert stored_count() == "0"
    end

    test "writes once the buffer is flushed", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      Logger.info("written after flush")

      :ok = Buffer.flush()

      assert stored_count() == "1"

      assert ClickhouseExLogger.TestServer.query!("SELECT message FROM logs") =~
               "written after flush"
    end
  end

  describe "level filtering" do
    test "an event below the configured level never reaches the buffer", %{
      handler_id: handler_id
    } do
      {:ok, _} =
        Handler.install(handler_id, %{
          level: :warning,
          batch_size: 1_000,
          flush_interval_ms: 60_000
        })

      Logger.info("below the threshold")

      eventually(fn -> Buffer.stats().active? end)

      assert Buffer.stats().accepted == 0
      :ok = Buffer.flush()
      assert stored_count() == "0"
    end

    test "an event at or above the configured level is shipped", %{handler_id: handler_id} do
      {:ok, _} =
        Handler.install(handler_id, %{
          level: :warning,
          batch_size: 1_000,
          flush_interval_ms: 60_000
        })

      Logger.error("above the threshold")

      eventually(fn -> Buffer.stats().accepted == 1 end)
      :ok = Buffer.flush()

      assert stored_count() == "1"
    end
  end

  describe "internal event exclusion" do
    test "an event carrying the marker produces no row and no counter change", %{
      handler_id: handler_id
    } do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      Logger.error("a failure report", clickhouse_ex_logger_internal: true)

      # Give the handler a chance to see it.
      Process.sleep(50)

      assert Buffer.stats().accepted == 0

      :ok = Buffer.flush()
      assert stored_count() == "0"
    end

    test "an unmarked event is shipped", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      Logger.error("a real error")

      eventually(fn -> Buffer.stats().accepted == 1 end)
      :ok = Buffer.flush()

      assert stored_count() == "1"
    end
  end

  describe "uninstall/1" do
    test "drains buffered rows so accepted logs are not discarded", %{handler_id: handler_id} do
      {:ok, _} =
        Handler.install(handler_id, %{
          batch_size: 10_000,
          flush_interval_ms: 60_000,
          max_buffer_size: 100
        })

      Logger.info("buffered before removal")
      Logger.info("also buffered")

      eventually(fn -> Buffer.stats().buffered == 2 end)

      assert :ok = Handler.uninstall(handler_id)

      assert stored_count() == "2"
    end

    test "stops the buffer", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 2})

      assert :ok = Handler.uninstall(handler_id)
      refute GenServer.whereis(Buffer)
    end

    test "removes the handler", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 2})

      :ok = Handler.uninstall(handler_id)

      refute match?({:ok, _}, :logger.get_handler_config(handler_id))
    end

    test "is safe to call for a handler that was never installed" do
      assert :ok = Handler.uninstall(:never_installed_handler)
    end

    test "no longer accepts events after removal", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 2})
      :ok = Handler.uninstall(handler_id)

      Logger.info("after removal")

      Process.sleep(50)
      refute GenServer.whereis(Buffer)
    end
  end

  describe "a failure in log/2 cannot reach the caller" do
    test "returns :ok instead of raising for an event it cannot map", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      # `:logger` always hands over a map, so this cannot happen in practice —
      # the point is that the rescue holds if it ever does.
      assert Handler.log("not a map event", %{}) == :ok
    end

    test "a process that logs repeatedly survives and all its events are buffered", %{
      handler_id: handler_id
    } do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      task =
        Task.async(fn ->
          for index <- 1..25 do
            Logger.info("event #{index}")
          end

          Process.alive?(self())
        end)

      assert Task.await(task) == true

      eventually(fn -> Buffer.stats().accepted == 25 end)

      :ok = Buffer.flush()
      assert stored_count() == "25"
    end

    test "reports an unmappable event through Logger, marked internal", %{handler_id: handler_id} do
      {:ok, _} = Handler.install(handler_id, %{batch_size: 1_000, flush_interval_ms: 60_000})

      CaptureHandler.install(self())

      Handler.log("not a map event", %{})

      assert [event] = CaptureHandler.drain()
      assert event.level == :error
      assert event.meta.clickhouse_ex_logger_internal == true

      # And it did not become a row.
      eventually(fn -> Buffer.stats().accepted == 0 end)
      :ok = Buffer.flush()
      assert stored_count() == "0"
    end
  end

  # Polls `fun` until it returns true, so tests do not depend on a fixed sleep.
  defp eventually(fun, attempts \\ 300) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
