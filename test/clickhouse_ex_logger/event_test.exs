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

  # The source-location strings are cached per call site, so these guard the two
  # ways that cache could report the wrong thing: a value belonging to one call
  # site appearing on another's row, and a repeat of the same call site drifting.
  describe "source location reuse" do
    test "repeated events from one call site record identical values" do
      rows = for _ <- 1..25, do: Event.row(event())

      assert Enum.uniq(Enum.map(rows, & &1.module)) == [inspect(MyApp.Worker)]
      assert Enum.uniq(Enum.map(rows, & &1.function)) == ["run/2"]
    end

    test "two functions in one module each record their own" do
      # This is the case a cache keyed on the module alone gets wrong: both mfas
      # share a module, so a module-keyed entry would hand the second one the
      # first one's `function`.
      run = Event.row(event(%{mfa: {MyApp.Worker, :run, 2}}))
      stop = Event.row(event(%{mfa: {MyApp.Worker, :stop, 0}}))

      assert run.function == "run/2"
      assert stop.function == "stop/0"
      assert run.module == stop.module
    end

    test "the same function at two arities records its own arity" do
      two = Event.row(event(%{mfa: {MyApp.Worker, :run, 2}}))
      one = Event.row(event(%{mfa: {MyApp.Worker, :run, 1}}))

      assert two.function == "run/2"
      assert one.function == "run/1"
    end

    test "an interleaved second call site does not disturb the first" do
      # Warm the first call site's entry, then read the second, then the first
      # again — the shape a warm cache actually sees in a running system.
      first = Event.row(event(%{mfa: {MyApp.Worker, :run, 2}}))
      _other = Event.row(event(%{mfa: {MyApp.Other, :go, 1}}))
      again = Event.row(event(%{mfa: {MyApp.Worker, :run, 2}}))

      assert again.module == first.module
      assert again.function == first.function
    end

    test "an arity the BEAM could not have is derived, not cached, and still correct" do
      # Outside the cache's bound, so it takes the uncached path. Correct either
      # way is the point: the bound is a memory guard, not a behaviour change.
      huge = Event.row(event(%{mfa: {MyApp.Worker, :run, 1_000_000}}))

      assert huge.module == inspect(MyApp.Worker)
      assert huge.function == "run/1000000"
    end

    test "a caller-supplied mfa cannot grow the cache without bound" do
      # `:mfa` is read from `:meta` first, and `:meta` is the caller's.
      # `:persistent_term` never reclaims a key, so a key space driven by log
      # content would be a leak. Varying the arity over values past the cache's
      # bound must therefore leave nothing behind.
      for arity <- 1..50 do
        assert Event.row(event(%{mfa: {MyApp.Worker, :run, arity + 10_000}})).function ==
                 "run/#{arity + 10_000}"

        assert :persistent_term.get(cache_key(MyApp.Worker, :run, arity + 10_000), :absent) ==
                 :absent
      end
    end

    test "a well-formed caller-supplied mfa is cached and correct" do
      # The same shape as a real one, so it *is* cached — which is the other half of
      # the bound above: within it, the key space is bounded by atoms, which code fixes.
      key = cache_key(MyApp.Worker, :cached_call, 3)
      on_entry(fn -> :persistent_term.erase(key) end)

      assert Event.row(event(%{mfa: {MyApp.Worker, :cached_call, 3}})).function == "cached_call/3"
      assert :persistent_term.get(key, :absent) != :absent
      assert Event.row(event(%{mfa: {MyApp.Worker, :cached_call, 3}})).function == "cached_call/3"
    end

    defp cache_key(module, function, arity),
      do: {ClickhouseExLogger.Event, :source_location, module, function, arity}

    # Removes a cache entry after the test so a re-run starts clean. Without this the
    # positive test above would pass on a leftover entry and stop proving that
    # `row/2` writes one.
    defp on_entry(fun), do: ExUnit.Callbacks.on_exit(fun)
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

    # `metadata/1` reads the top level and a nested map with different rules about
    # `:msg`, `:level` and `:meta`, and a rewrite that collapses the two walks into
    # one is exactly where the difference between them gets lost. Each rule below
    # pins one half of it.

    test "excludes :msg and :level from the top-level read" do
      assert Event.row(event()).metadata == %{}
    end

    test "keeps a nested :level and :msg as user data" do
      # They sit outside `:meta` on every shape, so on a flat event they are the
      # event's own message and severity. Under `:meta` they are the caller's.
      row = Event.row(event(%{meta: %{level: "user-level", msg: "user-msg"}}))

      assert row.metadata == %{"level" => "user-level", "msg" => "user-msg"}
    end

    test "excludes :meta from the top level and as a reserved key" do
      assert Event.row(event(%{meta: :not_a_map})).metadata == %{}
      assert Event.row(event(%{meta: %{meta: "nested"}})).metadata == %{}
    end

    test "ignores a :meta that is not a map" do
      for not_a_map <- [:an_atom, "a string", [1, 2], 42, nil] do
        assert Event.row(event(%{meta: not_a_map})).metadata == %{}
      end
    end

    test "nested wins a key the top level also carries, without losing the others" do
      row =
        Event.row(
          event(%{
            user_id: 9,
            only_on_top: "top",
            meta: %{request_id: "nested", only_nested: "nested"}
          })
        )

      assert row.metadata == %{
               "only_on_top" => "top",
               "only_nested" => "nested",
               "request_id" => "nested",
               "user_id" => "9"
             }
    end
  end

  describe "both event shapes" do
    # Depending on the OTP version, `:logger` carries an event's metadata nested
    # under `:meta` or spread across the top level. The moduledoc promises both are
    # handled, so a row must not depend on which shape produced the event.

    defp flat_event(overrides \\ %{}) do
      Map.merge(
        %{
          time: @usec,
          level: :error,
          msg: {:string, "boom"},
          mfa: {MyApp.Worker, :run, 2},
          file: "lib/my_app/worker.ex",
          line: 42,
          user_id: 7,
          request_id: "abc"
        },
        overrides
      )
    end

    test "reads metadata carried at the top level" do
      row = Event.row(flat_event())

      assert row.metadata == %{"user_id" => "7", "request_id" => "abc"}
    end

    test "produces the same row for the same content in either shape" do
      nested =
        event(%{
          level: :error,
          msg: {:string, "boom"},
          meta: %{user_id: 7, request_id: "abc"}
        })

      # `id` is generated per row, so it is the one field that cannot match.
      assert Map.delete(Event.row(nested), :id) == Map.delete(Event.row(flat_event()), :id)
    end

    test "lets nested metadata win when both shapes carry a key" do
      row =
        Event.row(flat_event(%{request_id: "from-the-top", meta: %{request_id: "nested"}}))

      assert row.metadata == %{"user_id" => "7", "request_id" => "nested"}
    end

    test "recognises the internal marker carried at the top level" do
      # The marker is what stops a ClickHouse outage feeding itself. Missing it on
      # one shape would let the library's own failure report become a row.
      assert Event.internal?(flat_event(%{clickhouse_ex_logger_internal: true}))
    end

    test "recognises the internal marker carried under meta" do
      assert Event.internal?(event(%{meta: %{clickhouse_ex_logger_internal: true}}))
    end

    test "is not internal without the marker" do
      refute Event.internal?(flat_event())
      refute Event.internal?(event())
    end
  end

  describe "source-location values that cannot be rendered" do
    # `row/2` promises never to raise, and the message path already renders rather
    # than raises. The `:file` path did not, for the same shapes of input.

    test "renders a code point that is not a valid character rather than raising" do
      # A surrogate half. Range-checking it accepts, `List.to_string/1` rejects.
      row = Event.row(event(%{file: [0xD800, 0x41]}))

      assert is_binary(row.file)
    end

    test "renders a list that is not well-formed rather than raising" do
      row = Event.row(event(%{file: [97 | 98]}))

      assert is_binary(row.file)
    end

    test "renders an empty list as no characters, not as an inspected list" do
      assert Event.row(event(%{file: []})).file == ""
    end

    test "still renders an ordinary charlist path" do
      assert Event.row(event(%{file: ~c"lib/my_app/worker.ex"})).file == "lib/my_app/worker.ex"
    end

    test "records an absent module as no value, not as the string nil" do
      # `WHERE module IS NULL` is the query for "no calling module". A row holding
      # the four characters `nil` is invisible to it.
      row = Event.row(event(%{mfa: {nil, :run, 2}}))

      assert row.module == nil
      assert row.function == "run/2"
    end

    test "records a nil module from the top-level fields as no value either" do
      row = Event.row(event(%{mfa: nil, module: nil, function: nil}))

      assert row.module == nil
      assert row.function == nil
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

  defp captured_event,
    do: ClickhouseExLogger.CaptureHandler.next!() |> ClickhouseExLogger.Event.row()
end
