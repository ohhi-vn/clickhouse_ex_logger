# Tasks

## 1. Baseline

- [x] 1.1 Add a microbenchmark helper under `test/support/` that times a callable over N
      iterations after a warm-up and returns mean microseconds per iteration; verify it
      returns a finite non-zero number for a known-cost callable and that `mix test` still
      passes with it added but unused.
- [x] 1.2 Measure and record the current caller-path cost (`Event.row/2` on an event with
      source location and both scalar-only and compound metadata) and the current
      `Insert.normalize/1` cost per row, on the implementation machine; verify the numbers
      are recorded in the change directory alongside design.md so the final budget can be
      derived from a same-machine before/after pair rather than the proposal's
      different-machine figures.

## 2. Caller path — source location reuse

- [x] 2.1 Derive the module string and the `function/arity` string through a
      `:persistent_term`-backed read-through cache keyed on the event's source location,
      per design.md decision 5; verify repeated events from one call site record identical
      values and that a second call site records its own, not the first's.
- [x] 2.2 Verify the cache cannot report a stale value by construction — key it on the
      source location rather than the module alone — and add a test that two locations in
      the same module at different lines or arities each record their own values; verify
      the test fails if the cache is keyed on the module alone.
- [x] 2.3 Confirm no `:persistent_term` write occurs on the per-event path after warm-up
      (a write per event would cost more than the ~0.51us saved); verify by measuring the
      caller path again and checking the result improved rather than regressed.

## 3. Caller path — single-pass metadata

- [x] 3.1 Rewrite `Event.metadata/1` to walk the nested and top-level maps once each,
      rejecting reserved keys by lookup in a compile-time map, per design.md decision 6;
      verify the existing `Event` test suite passes **unchanged** — it is the guard that
      the stored shape is identical.
- [x] 3.2 Verify the three shape rules the rewrite could plausibly break are each still
      covered and passing: nested wins per key over top level, `:msg`/`:level` are excluded
      only from the top-level read, and a compound value is rendered rather than dropped
      (round-tripping to an equivalent Elixir term).
- [x] 3.3 Verify a `:meta` that is present but not a map is still ignored rather than
      raising, and that an event carrying both shapes keeps the keys only one of them has.

## 4. Batch path — field names converted once per batch

- [x] 4.1 Replace `Insert.normalize/1`'s per-row `Map.new` + `to_string/1` over field names
      with a single pass that builds each row's string-keyed map from a precomputed
      `{atom, string}` pairing, per design.md decision 3; verify `Insert` tests pass
      unchanged and a mixed batch of rows with differing metadata all encode.
- [x] 4.2 Verify the precomputed pairing is read from the resource rather than restated, so
      renaming or reordering a resource attribute changes the wire form; verify by
      confirming the pairing derives from the resource's attribute list.
- [x] 4.3 Confirm `build_insert_rows/2` is still called and still owns value encoding
      (including UUID and map encoding); verify no hand-built encoded row list replaced it.
- [x] 4.4 Verify `Batch size reached` behaviour is intact: a 500-row flush still writes
      every row, chunking at 1000 still applies, and the returned committed count still
      matches rows actually written.

## 5. Budget assertion

- [x] 5.1 Add a test measuring the handler callback's mean cost per event over at least
      10,000 events and assert it against the budget derived in task 1.2 plus ~20%
      headroom; verify it fails against the pre-change code and passes after.
- [x] 5.2 Replace `@max_call_micros 50_000` in `workload_test.exs` with a value derived
      from the same measurement, keeping the existing stall scenario meaningful; verify the
      workload suite still passes against a healthy and a paused container.
- [x] 5.3 Confirm the budget test measures the handler callback only, not total
      `Logger.info/2` cost, and that it is unaffected by removing the console handler;
      verify by running it with and without other handlers installed.
- [x] 5.4 Run the full suite three times and confirm the budget assertion is stable across
      runs; if it flakes, loosen the headroom rather than deleting the assertion, and record
      why in the task's commit.

## 6. Verification and documentation

- [x] 6.1 Run the complete test suite, including the container-backed integration and
      workload modules; verify all pass and that `Event`/`Insert` tests were not modified
      by this change.
- [x] 6.2 Measure the caller path and batch path again on the same machine as task 1.2 and
      record before/after numbers; verify the caller path improved by roughly the ~0.83us
      the recoverable items account for, and report honestly if it did not.
- [x] 6.3 Add a CHANGELOG entry stating this reduces cost per logged event, not throughput
      into ClickHouse, and record the measured before/after per-event cost.
- [x] 6.4 Confirm no schema, public API, or row-shape change crept in: `Event.row/2`'s
      output, `Buffer`'s API and counters, handler options and validation, and the `logs`
      schema are all unchanged; verify by diffing the public functions and by confirming
      `mix clickhouse_ex_logger.migrate` is a no-op against an existing table.