# Proposal

## Why

A host that installs this handler pays for it on every log call, in the process that
logged, and nothing in the library bounds that cost. Measured on the current code
(Elixir 1.20.4, one event with source location and four metadata entries),
`ClickhouseExLogger.Event.row/2` costs **3.80 us** with compound metadata and
**2.53 us** with scalar-only metadata — all of it in the caller, because the
`:logger` handler callback runs there.

That cost is largely repeated work rather than necessary work. The module and
function strings are re-derived for every event from the same small set of call
sites (0.51 us). `metadata/1` walks the event map three times against a 21-element
list and then rebuilds the result, where one pass would do (0.32 us recoverable).
`ClickhouseExLogger.Insert.normalize/1` rebuilds every row map and calls
`to_string/1` on all ten field names on every flush, and the data layer then
converts the same ten names twice more per row.

This is worth doing now rather than later for a specific reason: **nothing in the
spec or the test suite would catch a regression here.** The only timing assertion
in the repository is `@max_call_micros 50_000` in `workload_test.exs:41` — a 50 ms
ceiling, roughly four orders of magnitude above the real cost. The library's
strongest existing promises are that the logging call never blocks and never
raises, and both hold no matter how expensive the call becomes. A logger whose cost
is unbounded is one a host eventually turns off, which loses the logs rather than
slowing the application.

## What Changes

- **Bound the work the handler adds to a logging call.** Add a measured per-event
  budget to the spec and a test that fails when it is exceeded. The budget applies
  to the work *this library* adds — the handler callback — not to the host's total
  `Logger.info/2` cost, which other handlers and `:logger`'s own formatting
  dominate and which the library does not own.
- **Stop re-deriving per-event values that depend only on the source location.**
  `Event.row/2` renders the calling module with `inspect/1` and formats
  `function/arity` by interpolation on every event, for what is in practice a
  handful of distinct call sites.
- **Collapse `metadata/1` to a single pass** over each event shape, replacing three
  `Map.drop/2` calls against a 21-element list plus a merge and a rebuild.
- **Stop rebuilding every row's field names on every flush.** `Insert.insert/1`
  converts ten field names per row on the buffer process; the field names are fixed
  by the resource and can be converted once.
- **Do not** remove UUID generation from the caller, **do not** change
  `Event.row/2`'s public row shape, and **do not** change the `logs` schema. See
  design.md — the identifier is the largest single remaining cost in the caller and
  removing it is deliberately deferred, with the cost that would justify it
  recorded.

Two hypotheses this change started from were measured and **refuted**, and are
recorded in design.md so they are not re-attempted: caching the node name is worth
0.01 us and is not worth doing, and `:maps.without/2` is no faster than
`Map.drop/2` with a list.

## Capabilities

### New Capabilities

None. This change adds no new subsystem; it bounds the cost of the existing one.

### Modified Capabilities

- `clickhouse-log-handler`: adds a requirement bounding the cost the handler adds to
  a logging call and the cost of encoding a batch, and requiring that work whose
  result depends only on a source location not be repeated per event. Existing
  requirements (`Event-to-row mapping`, `Buffered batched delivery`, `Non-blocking
  behaviour under load`) keep their current behaviour and are **not** modified.

## Impact

**Code**

- `lib/clickhouse_ex_logger/event.ex` — `metadata/1` single pass; source-location
  string derivation reused across events sharing a call site.
- `lib/clickhouse_ex_logger/insert.ex` — `normalize/1` no longer calls `to_string/1`
  per field name per row.
- `lib/clickhouse_ex_logger/buffer.ex` — expected to be untouched; the batch path
  change is confined to `Insert`.

**Public surface** — none. `Event.row/2`'s return shape, `Buffer`'s API and
counters, the handler's options and their validation, and the `logs` schema are all
unchanged. `Event.row/2` is public and callers outside this library may hold onto
rows; keeping its output identical is what keeps this a non-breaking change.

**Dependencies** — none added. The data layer's `build_insert_rows/2` is kept as the
encoder precisely so that `ClickhouseExLogger.LogEntry` remains the single source of
truth for column names, order and encoding, a property `Insert`'s moduledoc
currently claims.

**Tests** — a new focused cost test for the handler's per-event work, and a tightened
threshold in `workload_test.exs`. The 50 ms ceiling there is replaced with a value
derived from measurement; see design.md for the flakiness constraint that shapes it.

**Measurement caveat.** All figures above come from one machine via ad-hoc
microbenchmarks against the compiled modules. They are used to rank costs and size
the opportunity, not as the asserted budget. The budget is set from a
post-implementation measurement, because a wall-clock threshold asserted in CI is
machine-dependent and a number carried over from a different machine would be
arbitrary.