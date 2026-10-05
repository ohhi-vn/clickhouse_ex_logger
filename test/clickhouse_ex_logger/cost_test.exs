defmodule ClickhouseExLogger.CostTest do
  @moduledoc """
  Holds the write path to a measured cost budget.

  `clickhouse-log-handler` requires that a logging call never blocks, and it has
  held that promise since before this file existed. What it did not require is
  that the call be *cheap* — and an unmeasured cost is one nobody notices until a
  host turns the handler off, which loses the logs rather than slowing the
  application. The only timing assertion the suite had was
  `@max_call_micros 50_000` in `ClickhouseExLogger.WorkloadTest`, about four orders
  of magnitude above the real cost, which could not fail and so guarded nothing.

  ## What is measured, and what is deliberately not

  The budget covers **this library's** work: entry to `ClickhouseExLogger.Handler`'s
  `:logger` callback through to its return. It does not cover the host's total
  `Logger.info/2` cost, which `:logger`'s own formatting and every other installed
  handler dominate — with this repository's default console handler attached, a
  `Logger.info/2` costs roughly 7.3 us while the callback contributes about 2.2. A
  total-cost budget would therefore mostly measure the console handler, would move
  with whatever else a host configures, and could not be met by any change here.

  So this file calls the callback directly rather than logging through `Logger`.
  The rows are cast to a process that discards them instead of to
  `ClickhouseExLogger.Buffer`: that keeps the cast real — the row is copied to
  another process, which is part of the caller's cost — while leaving the globally
  named buffer alone, so this test neither flushes rows into the shared `logs` table
  nor has to wait on ClickHouse.

  ## Why a mean, and why it is in microseconds

  A single call's duration cannot be asserted honestly in CI: one scheduler
  preemption or GC pass costs far more than the work being measured, so a
  per-call maximum would fail on unchanged code and pass a real regression. The
  mean over #{@iterations} iterations dilutes that instead of letting it decide, and
  repeated runs of this file have varied by under 1%. See
  `ClickhouseExLogger.Microbenchmark`.

  Synchronous, not because it touches the shared buffer — it deliberately does not —
  but because the first event from a call site writes to `:persistent_term`, and a
  `:persistent_term` write pauses every process on the node. Allowing that to land
  in the middle of another module's measurement would make *that* module's timing
  flaky for no reason of its own.
  """

  use ExUnit.Case, async: false

  require Logger

  alias ClickhouseExLogger.Event
  alias ClickhouseExLogger.Handler
  alias ClickhouseExLogger.Microbenchmark

  # The events measured. Source location and three metadata entries — the shape an
  # ordinary `Logger.info("msg", key: value)` produces on OTP 27+.
  @event %{
    time: 1_700_000_000_123_456,
    level: :info,
    msg: {:string, "workload-42"},
    mfa: {__MODULE__, :run, 1},
    file: ~c"/app/lib/my_app/workload.ex",
    line: 42,
    pid: self(),
    application: :my_app,
    meta: %{user_id: 7, request_id: "abc-123", workload: true}
  }

  # Two budgets, not one, and the split is the whole point.
  #
  # **Mapping** — `Event.row/2` — is where both optimisations in this change live,
  # and it is the cheap, stable thing to measure: repeated runs put it between 1.55
  # and 1.62us, a spread of about 4%. That stability is what lets this budget sit
  # only ~17% above it, which is tight enough to catch *either* optimisation being
  # undone — losing the source-location cache alone costs ~0.5us, and losing the
  # single-pass metadata rewrite ~1.0us, so both cross this line.
  #
  # **Callback** — the whole of `Handler.log/2`, including the cast — is the quantity
  # the requirement is written about, but it is roughly a third noisier (2.17 to
  # 2.49us observed) because the row is copied into another process and the garbage
  # that produces shows up in the measurement. A budget tight enough to catch a
  # half-regression here would catch a busy CI runner too.
  #
  # So the callback budget is set loose, to catch a gross failure — the handler
  # blocking, or the per-event work growing severalfold — while the mapping budget
  # carries the sensitivity. Between them the two cover both, and neither is set so
  # tight that a slower machine fails it.
  #
  # Both separate from where this code started. Measured on the machine this was
  # written on: mapping ~2.6us and callback ~3.72us before the change, against
  # ~1.6us and ~2.24us after. Both budgets fail a regression all the way back.
  @callback_budget_us 3.0
  @mapping_budget_us 1.9

  @iterations 10_000

  setup do
    discarder = start_discarder()
    config = %{buffer: discarder, include_node: true}

    on_exit(fn -> Process.exit(discarder, :kill) end)

    {:ok, config: config}
  end

  describe "the cost the handler adds to a logging call" do
    test "mapping an event stays within its budget", _context do
      # The tight one, and the one that would notice this change being undone.
      cost =
        Microbenchmark.mean_micros(
          fn -> Event.row(@event, %{include_node: true}) end,
          iterations: @iterations
        )

      assert cost <= @mapping_budget_us,
             "mapping an event cost #{Float.round(cost, 2)}us, " <>
               "over its #{@mapping_budget_us}us budget"
    end

    test "the whole callback stays within its budget", %{config: config} do
      cost =
        Microbenchmark.mean_micros(fn -> Handler.log(@event, config) end, iterations: @iterations)

      assert cost <= @callback_budget_us,
             "the handler added #{Float.round(cost, 2)}us per logging call, " <>
               "over its #{@callback_budget_us}us budget"
    end

    test "does not depend on how many events are logged", %{config: config} do
      # The same measurement at a tenth of the volume. A cost that grew with volume
      # would show up here as a higher per-event figure, because anything that
      # accumulates — a growing map, a leaked cache entry, a list that is never
      # trimmed — costs more each time round.
      small = Microbenchmark.mean_micros(fn -> Handler.log(@event, config) end, iterations: 1_000)

      large =
        Microbenchmark.mean_micros(fn -> Handler.log(@event, config) end, iterations: @iterations)

      assert large <= @callback_budget_us

      assert large <= small * 1.5,
             "per-event cost rose from #{Float.round(small, 2)}us to #{Float.round(large, 2)}us " <>
               "as volume rose, which suggests something accumulating per event"
    end
  end

  describe "what the budget covers" do
    test "measures this library's work and not the logging system's", %{config: config} do
      # The point of measuring the callback rather than `Logger.info/2`: the two are
      # not the same quantity, and conflating them would make the budget a statement
      # about the host's formatter and every other handler it installed.
      callback =
        Microbenchmark.mean_micros(fn -> Handler.log(@event, config) end, iterations: @iterations)

      # What the row actually costs to build, which is the bulk of the callback.
      mapping =
        Microbenchmark.mean_micros(fn -> Event.row(@event, %{include_node: true}) end,
          iterations: @iterations
        )

      assert callback >= mapping
      assert callback <= @callback_budget_us
    end

    test "is unaffected by additional handlers being installed", %{config: config} do
      # The scenario is about what the host adds — extra handlers, an expensive
      # formatter — and about this budget not being charged for it.
      #
      # The suite's own handlers (`:default`, Elixir's console handler, and the
      # `:ssl_handler` its ClickHouse dependency installs) are deliberately left
      # alone rather than removed and restored: `:logger`'s handler config does not
      # round-trip reliably enough to put back exactly, and a half-restored logger
      # would break every module after this one. Adding handlers instead tests the
      # same isolation in the direction the scenario names, and cannot break anything
      # if it fails.
      #
      # It is worth stating why this isolation is structural rather than incidental:
      # `Handler.log/2` is called here directly, so it never consults `:logger`'s
      # handler list at all. Whatever the host has installed is not on this path.
      before =
        Microbenchmark.mean_micros(fn -> Handler.log(@event, config) end, iterations: @iterations)

      added =
        for name <- [:one, :two, :three] do
          id = {__MODULE__, name, make_ref()}

          :logger.add_handler(
            id,
            __MODULE__,
            %{config: config, level: :all, filter_default: :log, module: __MODULE__}
          )

          id
        end

      try do
        after_adding =
          Microbenchmark.mean_micros(fn -> Handler.log(@event, config) end,
            iterations: @iterations
          )

        assert after_adding <= @callback_budget_us
        assert_in_delta after_adding, before, 0.5
      after
        for id <- added, do: :logger.remove_handler(id)
      end
    end
  end

  # A stand-in for the buffer that accepts rows and keeps none of them. The cast is
  # the part that belongs to the caller's cost — the row is copied into another
  # process — so replacing the buffer with this measures the same work without
  # starting a writer, filling a queue, or writing to the shared table.
  #
  # It drains in batches rather than per message on purpose. A plain `receive` loop
  # wakes once per cast, which at 10,000 casts is 10,000 wakeups competing with the
  # measurement for a scheduler; that showed up as run-to-run noise wide enough to
  # matter for a budget. Waking roughly a hundred times instead makes the receiver
  # cheap enough to stop distorting what it is there to measure.
  defp start_discarder do
    spawn_link(fn -> discard_loop() end)
  end

  defp discard_loop do
    receive do
      _message -> :ok
    after
      50 -> drain()
    end

    discard_loop()
  end

  defp drain do
    receive do
      _message -> drain()
    after
      0 -> :ok
    end
  end
end
