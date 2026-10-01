defmodule ClickhouseExLogger.EventTest do
  @moduledoc """
  Verifies the `:logger` event to `ClickhouseExLogger.LogEntry` row mapping.
  """

  use ExUnit.Case, async: true

  require Logger

  alias ClickhouseExLogger.Event

  @usec 1_700_000_000_000_000

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        time: @usec,
        level: :info,
        msg: {:string, ["hello"]},
        mfa: {MyApp.Worker, :run, 2},
        file: "lib/my_app/worker.ex",
        line: 42,
        meta: %{}
      },
      overrides
    )
  end

  describe "row/1 core fields" do
    test "populates timestamp, level and message" do
      row = Event.row(event())

      assert row.timestamp == DateTime.from_unix!(@usec, :microsecond)
      assert row.level == :info
      assert row.message == "hello"
    end

    test "gives every row a distinct UUID" do
      ids = for _ <- 1..100, do: Event.row(event()).id

      assert length(Enum.uniq(ids)) == 100

      assert Enum.all?(
               ids,
               &(&1 =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
             )
    end

    test "renders a pre-formatted binary message as-is" do
      assert Event.row(event(%{msg: {:string, "already rendered"}})).message ==
               "already rendered"
    end

    test "renders a chardata message" do
      assert Event.row(event(%{msg: {:string, ["a", [?b], "c"]}})).message == "abc"
    end

    test "renders a chardata message containing non-iodata terms by inspection" do
      # A keyword list is a list, but not chardata.
      assert Event.row(event(%{msg: {:string, [a: 1]}})).message == "[a: 1]"
    end

    test "renders a keyword-list report by inspection" do
      assert Event.row(event(%{msg: {:report, [user_id: 7]}})).message ==
               "[user_id: 7]"
    end

    test "renders a map report by inspection" do
      assert Event.row(event(%{msg: {:report, %{a: 1}}})).message == "%{a: 1}"
    end

    test "renders a bare term message by inspection" do
      # Not a `{:kind, term}` tuple at all, so it reaches the last clause rather
      # than the report clause.
      assert Event.row(event(%{msg: :a_bare_atom})).message == ":a_bare_atom"
    end

    test "renders empty chardata as an empty message" do
      assert %{message: ""} = Event.row(event(%{msg: {:string, []}}))
    end

    test "renders chardata that is not valid Unicode by inspection rather than raising" do
      # `IO.chardata_to_string/1` raises `UnicodeConversionError` here, which is
      # not an `ArgumentError` — the clause this used to rescue could not fire.
      assert %{message: "[<<255>>]"} = Event.row(event(%{msg: {:string, [<<0xFF>>]}}))
    end

    test "renders a message that is not well-formed chardata by inspection rather than raising" do
      # An improper list breaks the chardata check itself, so it never reaches
      # `IO.chardata_to_string/1`.
      assert %{message: "[1 | 2]"} = Event.row(event(%{msg: {:string, [1 | 2]}}))
    end

    test "survives an event with no message" do
      assert %{message: ""} = Event.row(event(%{msg: nil}))
    end

    test "survives an event with no timestamp" do
      row = Event.row(Map.delete(event(), :time))

      assert %DateTime{} = row.timestamp
    end

    test "keeps a DateTime the event already carries instead of replacing it" do
      # `:logger` supplies microseconds, but a translated event may hand over a
      # `DateTime`. It is the event's own moment, so it is kept verbatim.
      at = ~U[2026-01-02 03:04:05.000006Z]

      assert Event.row(event(%{time: at})).timestamp == at
    end

    test "defaults a missing level rather than failing" do
      assert Event.row(Map.delete(event(), :level)).level == :info
    end
  end

  describe "levels" do
    @levels ~w(emergency alert critical error warning notice info debug)a

    test "accepts every Erlang syslog level" do
      for level <- @levels do
        assert Event.row(event(%{level: level})).level == level
      end
    end

    test "keeps the full Elixir Logger level set working" do
      # Logger.warn/2 is deprecated but still emits :warning, and
      # Logger.notice/2 emits :notice; both must round-trip.
      for level <- @levels do
        assert Event.row(event(%{level: level})).level == level
      end
    end
  end

  describe "source location" do
    test "records module, file, line and function when present" do
      row = Event.row(event())

      assert row.module == inspect(MyApp.Worker)
      assert row.file == "lib/my_app/worker.ex"
      assert row.line == 42
      assert row.function == "run/2"
    end

    test "records nil for every field when there is no location at all" do
      row =
        event()
        |> Map.drop([:mfa, :file, :line])
        |> Event.row()

      assert row.module == nil
      assert row.file == nil
      assert row.line == nil
      assert row.function == nil
    end

    test "does not crash on a partial mfa" do
      row = Event.row(event(%{mfa: {MyApp.Worker, :run, :bad_arity}}))

      assert row.module == inspect(MyApp.Worker)
      assert row.function == nil
    end

    test "falls back to explicit :module and :function metadata" do
      row =
        event()
        |> Map.drop([:mfa, :file, :line])
        |> Map.merge(%{module: SomeMod, function: "go/1"})
        |> Event.row()

      assert row.module == "SomeMod"
      assert row.function == "go/1"
    end

    test "ignores a non-integer line" do
      assert Event.row(event(%{line: "not a line"})).line == nil
    end
  end

  describe "node name" do
    # This module runs as `:nonode@nohost`, so the "distributed" branch cannot be
    # exercised here — it is covered in `ClickhouseExLogger.IntegrationTest` and by
    # the real insert path. What is testable here is the option's handling and the
    # guarantee that it never turns into a placeholder.
    test "is absent on a system that is not distributed" do
      assert node() == :nonode@nohost, "this suite is expected to run undistributed"
      assert Event.row(event()).node == nil
    end

    test "capture is on by default, with no option passed" do
      # Asserted through the type rather than a value, since this VM has no node
      # name to report: the key must be present so a distributed host fills it.
      assert Map.has_key?(Event.row(event()), :node)
    end

    test "is absent when capture is disabled" do
      assert Event.row(event(), %{include_node: false}).node == nil
    end

    test "accepts the option as a keyword list too" do
      assert Event.row(event(), include_node: false).node == nil
    end

    test "does not consume a user metadata key named node" do
      row = Event.row(event(%{meta: %{node: "eu-west"}}))

      # The column comes from `node/0`, never from the event, so this metadata key
      # stays user data exactly as it was before the column existed. Reserving it
      # would silently change what `Logger.info("hi", node: "eu-west")` does.
      assert row.metadata["node"] == "eu-west"
      assert :node not in Event.reserved_keys()
    end

    test "an unknown option is ignored rather than treated as disabling capture" do
      # `Event.row/2` is public and can be called without `Handler.install/2`'s
      # validation in front of it, so only an explicit `false` disables.
      assert Event.row(event(), %{include_node: "no"}).node == nil
    end
  end

  describe "metadata" do
    test "records user metadata as string key/value pairs" do
      row = Event.row(event(%{meta: %{user_id: 7, request_id: "abc"}}))

      assert row.metadata == %{"user_id" => "7", "request_id" => "abc"}
    end

    test "is empty when there is no metadata" do
      assert Event.row(event()).metadata == %{}
    end

    test "omits Erlang's own event keys so they are not duplicated" do
      row =
        Event.row(
          event(%{
            meta: %{
              pid: self(),
              time: @usec,
              mfa: {MyApp.Worker, :run, 2},
              file: "a.ex",
              line: 1,
              report_level: :all,
              application: :my_app,
              domain: [:elixir],
              user_id: 7
            }
          })
        )

      assert row.metadata == %{"user_id" => "7"}
    end

    test "lists its own reserved keys" do
      assert :mfa in Event.reserved_keys()
      assert :file in Event.reserved_keys()
      assert :domain in Event.reserved_keys()
      assert :clickhouse_ex_logger_internal not in Event.reserved_keys()
    end
  end

  describe "stringify/1" do
    test "passes binaries through unchanged" do
      assert Event.stringify("already text") == "already text"
    end

    test "renders integers and floats" do
      assert Event.stringify(42) == "42"
      assert Event.stringify(-1) == "-1"
      assert Event.stringify(1.5) == "1.5"
    end

    test "renders atoms with to_string" do
      assert Event.stringify(:admin) == "admin"
      assert Event.stringify(nil) == ""
      assert Event.stringify(true) == "true"
    end

    test "renders dates and times" do
      assert Event.stringify(~U[2026-01-02 03:04:05Z]) == "2026-01-02T03:04:05Z"
      assert Event.stringify(~D[2026-01-02]) == "2026-01-02"
      assert Event.stringify(~T[03:04:05]) == "03:04:05"
      assert Event.stringify(~N[2026-01-02 03:04:05]) == "2026-01-02T03:04:05"
    end

    test "marks and inspects compound terms" do
      assert Event.stringify([1, 2]) == "term:[1, 2]"
      assert Event.stringify(%{a: 1}) == "term:%{a: 1}"
      assert Event.stringify({:a, :b}) == "term:{:a, :b}"
    end

    test "marks a pid rather than pretending it is a string" do
      rendered = Event.stringify(self())

      assert String.starts_with?(rendered, "term:#PID")
    end

    test "marks a struct" do
      assert Event.stringify(~D[2026-01-02]) == "2026-01-02"
      assert Event.stringify(%URI{host: "example.com"}) =~ "term:%URI{"
    end

    test "a marked value round-trips through Code.eval_string/1" do
      for value <- [[1, 2], %{a: 1, b: [2, 3]}, {:ok, "x"}, %URI{host: "h"}] do
        restored =
          value
          |> Event.stringify()
          |> String.replace_prefix("term:", "")
          |> Code.eval_string()
          |> elem(0)

        assert restored == value
      end
    end

    test "a marker distinguishes an inspected term from a real string" do
      assert Event.stringify("[1, 2]") == "[1, 2]"
      assert Event.stringify([1, 2]) == "term:[1, 2]"
    end

    test "does not truncate a large term" do
      long = Enum.to_list(1..5_000)

      assert Event.stringify(long) =~ "5000"
    end
  end

  describe "internal?/1" do
    test "recognises the backend's own marker" do
      assert Event.internal?(event(%{meta: %{clickhouse_ex_logger_internal: true}}))
    end

    test "ignores an unmarked event" do
      refute Event.internal?(event())
    end

    test "ignores a false marker" do
      refute Event.internal?(event(%{meta: %{clickhouse_ex_logger_internal: false}}))
    end
  end

  describe "real Logger calls" do
    test "an event captured from Logger.info/1 maps cleanly" do
      ClickhouseExLogger.CaptureHandler.install(self())

      Logger.info("from the real logger", user_id: 99)

      row = captured_event()

      assert row.level == :info
      assert row.message == "from the real logger"
      assert row.metadata["user_id"] == "99"
      assert row.module == inspect(__MODULE__)
      assert row.function =~ "an event captured from Logger.info/1"
    end

    test "a real OTP report does not crash the mapping" do
      ClickhouseExLogger.CaptureHandler.install(self())

      :logger.error("plain erlang message", %{user_id: 5})

      row = captured_event()

      assert row.level == :error
      assert row.metadata["user_id"] == "5"
    end
  end

  defp captured_event, do: ClickhouseExLogger.CaptureHandler.next!() |> ClickhouseExLogger.Event.row()
end
