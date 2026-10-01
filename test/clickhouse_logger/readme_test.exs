defmodule ClickhouseLogger.ReadmeTest do
  @moduledoc """
  Verifies the README's Elixir snippets are real code, not approximations.

  A setup document that does not compile is worse than no document, and a setup
  document that drifts from the library silently stops working. So every
  ```elixir fence is parsed, and the documented API surface is checked against the
  modules that actually exist.
  """

  use ExUnit.Case, async: true

  @readme Path.expand("../../README.md", __DIR__)

  setup_all do
    {:ok, %{contents: File.read!(@readme)}}
  end

  test "the README exists", %{contents: contents} do
    assert is_binary(contents)
  end

  test "every ```elixir snippet parses", %{contents: contents} do
    for snippet <- snippets(contents) do
      case Code.string_to_quoted(snippet) do
        {:ok, _ast} ->
          :ok

        {:error, error} ->
          flunk("""
          README snippet does not parse: #{inspect(error)}

          #{snippet}
          """)
      end
    end
  end

  test "every ```elixir snippet is parseable as a whole module or expression", %{
    contents: contents
  } do
    # `Code.string_to_quoted/1` is lenient about `defmodule`-less fragments; make
    # sure at least the full-file snippets round-trip through the compiler's
    # parser too.
    for snippet <- snippets(contents), String.starts_with?(snippet, "defmodule") do
      assert {:ok, _ast} = Code.string_to_quoted(snippet)
    end
  end

  describe "documented API exists" do
    test "the modules the README names are loadable" do
      for module <- [
            ClickhouseLogger,
            ClickhouseLogger.Repo,
            ClickhouseLogger.Domain,
            ClickhouseLogger.LogEntry,
            ClickhouseLogger.Handler,
            ClickhouseLogger.Buffer,
            ClickhouseLogger.Event,
            ClickhouseLogger.Insert,
            ClickhouseLogger.Migration
          ] do
        assert Code.ensure_loaded?(module),
               "README names #{inspect(module)}, which does not exist"
      end
    end

    test "the functions the README calls are exported" do
      for {module, function, arity} <- [
            {ClickhouseLogger.Handler, :install, 2},
            {ClickhouseLogger.Handler, :uninstall, 1},
            {ClickhouseLogger.Buffer, :stats, 1},
            {ClickhouseLogger.Event, :internal?, 1},
            {ClickhouseLogger.Insert, :insert, 1},
            {ClickhouseLogger.Migration, :setup, 1}
          ] do
        Code.ensure_loaded!(module)

        assert function_exported?(module, function, arity),
               "README calls #{inspect(module)}.#{function}/#{arity}, which is not exported"
      end
    end

    test "the Mix task the README tells users to run exists" do
      assert Code.ensure_loaded?(Mix.Tasks.ClickhouseLogger.Migrate)
      assert function_exported?(Mix.Tasks.ClickhouseLogger.Migrate, :run, 1)
    end
  end

  describe "documented defaults match the code" do
    test "batch_size, flush_interval_ms and max_buffer_size" do
      {:ok, options} = ClickhouseLogger.Handler.validate(%{})

      assert options[:batch_size] == 500
      assert options[:flush_interval_ms] == 1_000
      assert options[:max_buffer_size] == 10_000
    end

    test "the table is `logs` with a MergeTree engine ordered by timestamp" do
      alias AshClickhouse.DataLayer.Dsl

      assert Dsl.table(ClickhouseLogger.LogEntry) == "logs"
      assert Dsl.engine(ClickhouseLogger.LogEntry) == "MergeTree()"
      assert Dsl.order_by(ClickhouseLogger.LogEntry) == "timestamp"
    end

    test "the stats/1 keys the README documents are exactly what stats/1 returns" do
      keys = ClickhouseLogger.Buffer.stats(:not_running) |> Map.keys() |> Enum.sort()

      assert keys == [:accepted, :active?, :buffered, :delivered, :discarded, :failed]
    end

    test "the metadata term marker is `term:`" do
      assert ClickhouseLogger.Event.stringify([1, 2]) == "term:[1, 2]"
    end
  end

  describe "the documented column list matches the resource" do
    test "every column in the README table exists on the resource" do
      documented =
        ~w(id timestamp level message module file line function metadata)
        |> Enum.map(&String.to_atom/1)

      actual =
        ClickhouseLogger.LogEntry
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert Enum.sort(documented) == actual
    end
  end

  defp snippets(contents) do
    Regex.scan(~r/^```elixir\n(.*?)^```/ms, contents)
    |> Enum.map(fn [_match, body] -> body end)
    |> Enum.reject(&(&1 =~ "Example"))
  end
end
