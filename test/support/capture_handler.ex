defmodule ClickhouseLogger.CaptureHandler do
  @moduledoc """
  A `:logger` handler that forwards events to a pid, for tests.

  Captures the event map `:logger` actually delivers, so a test can assert on
  `msg` and `meta` directly instead of on the rendered console text. Compiled
  into the test build only.
  """

  @behaviour :logger_handler

  import ExUnit.Assertions, only: [flunk: 1]

  @doc """
  Installs the handler and returns its id.

  The handler is removed when the calling test exits.
  """
  @spec install(pid()) :: atom()
  def install(pid) do
    handler_id =
      String.to_atom("clickhouse_logger_capture_#{System.unique_integer([:positive])}")

    :ok =
      :logger.add_handler(
        handler_id,
        __MODULE__,
        %{
          config: %{capture_to: pid},
          level: :all,
          filter_default: :log,
          formatter: Logger.Formatter.new(colors: [enabled: false])
        }
      )

    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(handler_id) end)
    handler_id
  end

  @doc """
  Awaits the next captured event.
  """
  @spec next!(timeout()) :: map()
  def next!(timeout \\ 1_000) do
    receive do
      {:captured, event} -> event
    after
      timeout -> flunk("no event reached #{inspect(__MODULE__)}")
    end
  end

  @doc """
  Drains every captured event captured so far, oldest first.
  """
  @spec drain(timeout()) :: [map()]
  def drain(timeout \\ 50) do
    drain(timeout, [])
  end

  @impl true
  def log(event, %{config: %{capture_to: pid}}), do: send(pid, {:captured, event})
  def log(_event, _config), do: :ok

  defp drain(timeout, acc) do
    receive do
      {:captured, event} -> drain(timeout, [event | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
