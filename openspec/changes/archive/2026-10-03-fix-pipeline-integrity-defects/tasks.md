# Tasks

## 1. Buffer write lifecycle: a dead write must not wedge the buffer

- [x] 1.1 Add a `Buffer` test that reproduces the wedge: start a buffer, force the
      spawned write to die without sending a result (a row missing `:timestamp`
      makes `Insert.normalize/1` raise inside the write process), then assert the
      batch is counted in `lost`, `failed` is incremented, and
      `accepted - delivered - discarded - lost == 0`. Verify the test fails against
      the current code with the reconciliation non-zero and `active?: true`.

- [x] 1.2 Add a `Buffer` test asserting liveness survives a dead write: after the
      crash, enqueue a well-formed row and assert it is delivered, and that
      `flush/1` returns rather than hanging. Verify it fails today with the row
      stuck in `buffered` and `flush/1` timing out.

- [x] 1.3 Route the `:DOWN` message for the in-flight write through the failed-flush
      accounting in `handle_info/2`: whole batch uncommitted, `lost += in_flight`,
      `failed += 1`, one `Logger.error` carrying
      `clickhouse_ex_logger_internal: true`, then clear `write_ref` and run the
      existing post-write path (`flush_now` → `schedule_flush` → `reply_when_drained`).
      Verify tasks 1.1 and 1.2 pass.

- [x] 1.4 Update the comment above the `:DOWN` clause, which currently claims the
      result message always arrives, and the `Buffer` moduledoc, to state that a
      write is accounted for whether it reports an outcome or dies. Verify the
      comments match the implemented behaviour.

## 2. Buffer accounting totality and shutdown write ordering

- [x] 2.1 Add a catch-all `tally/2` clause treating any result shape other than
      `{:ok, committed}` and `{:error, reason, committed}` as a failed flush with
      the whole batch uncommitted, and add a test that makes `bulk_create/1` return
      an unrecognised shape and asserts the buffer stays alive and the rows land in
      `lost`. Verify the test fails today with a `FunctionClauseError` crashing the
      buffer.

- [x] 2.2 Correct `Insert.insert/1`'s `@spec` and `@doc` to advertise only the
      shapes it actually returns (`{:ok, committed}` and
      `{:error, message, committed}`), since the advertised `{:error, message}`
      documents the buffer's crash trigger as legitimate. Verify with
      `mix compile --force --warnings-as-errors` and by reading the doc against
      `insert/1`'s `case` at the end of the function.

- [x] 2.3 Make `bounded_flush/1`'s receive ref-matched (`^ref` rather than
      `{_ref, _result}`) so it cannot be satisfied by an unrelated two-element
      message such as a concurrent `{:enqueue, row}` cast. Verify with a test that
      queues a matching decoy message before the buffer stops and asserts the
      flush still waits for its own write.

- [x] 2.4 Change `terminate/2` so that when a write is already in flight it bounds
      a wait for *that* write instead of spawning a second one, and writes any
      still-queued rows only once nothing is outstanding. Verify with a test that
      stops a buffer holding rows while a write is in flight and asserts only one
      insert is issued.

- [x] 2.5 Re-run the full buffer test module and confirm the moduledoc's "at most
      one write is in flight" invariant now holds in every state, including during
      shutdown.

## 3. `flush/1` and `stats/1` must not report success they did not achieve

- [x] 3.1 Narrow `stats/1`'s `catch` clause so it returns zeroed counters with
      `active?: false` only for a buffer that is genuinely not running, and not for
      a single call that timed out on a busy buffer. Add a test that queries
      statistics while a slow write is outstanding and assert the system does not
      report itself idle. Verify the test fails today.

- [x] 3.2 Correct `flush/2`'s `@doc` to state what it actually guarantees — that it
      returned, not that the buffer drained — and note that `terminate/2` is what
      performs the bounded final write. Verify the doc matches the implementation
      described in `design.md` decision "flush/2 and stats/1 stop conflating".

- [x] 3.3 Confirm `Handler.uninstall/1` needs no timeout branch of its own, since
      `terminate/2` (task 2.4) now decides what happens to undelivered rows, and
      update its comment to point at that. Verify with the existing
      `handler_test.exs` removal tests plus a new test that removal against a
      stalled ClickHouse returns within the documented bound and accounts for the
      rows it could not write.

## 4. `Handler.install/2`: validate every option, roll back what it started

- [x] 4.1 Validate `:level` in `install/2` on the same terms as the other options,
      returning `{:error, {option, message}}`, and add a test asserting
      `install(:id, level: :not_a_level)` returns that shape. Verify the test fails
      today with `{:error, {:invalid_level, :not_a_level}}`.

- [x] 4.2 Have `ensure_buffer_started/1` report whether *it* started the buffer, and
      make `install/2` stop that buffer when `register/2` subsequently fails,
      leaving a buffer that was already running untouched. Verify with two tests:
      one asserting a failed install leaves `GenServer.whereis(Buffer)` as `nil`,
      one asserting a pre-existing buffer survives a failed install.

- [x] 4.3 Add a test asserting a rejected install is repeatable — a second attempt
      after fixing the config succeeds — covering the `{:error, {:already_started,
      pid}}` path that `ensure_buffer_started/1` currently has no clause for.

- [x] 4.4 Update the `install/2` moduledoc so its "leaves nothing running"
      guarantee describes the implemented rollback, and document `:level` among the
      validated options. Verify the doc matches the code in task 4.2.

## 5. Reject configurations that discard rows for no external reason

- [x] 5.1 Add a test asserting `Handler.validate(%{batch_size: 100,
      max_buffer_size: 3})` returns `{:error, {:batch_size, message}}` naming the
      offending option. Verify the test fails today with `{:ok, _}`.

- [x] 5.2 Add the cross-option check to `validate/1`, rejecting
      `batch_size > max_buffer_size`, and a test asserting
      `batch_size == max_buffer_size` is still accepted. Verify both tests pass and
      the default configuration (500 against 10 000) is unaffected.

- [x] 5.3 Document the relationship in the `Handler` moduledoc's `:batch_size` and
      `:max_buffer_size` entries, so the reason for the rejection is stated where a
      host reads it.

## 6. `Event` row mapping: total across both event shapes

- [x] 6.1 Add `Event` tests for a top-level-shaped event — user metadata keys at the
      top level — asserting the row's `metadata` carries them, and for a top-level
      `clickhouse_ex_logger_internal` marker, asserting `internal?/1` is `true`.
      Verify both fail today (metadata is `%{}`, `internal?/1` is `false`).

- [x] 6.2 Give `metadata/1` and the `internal?/1` lookup the same
      nested-then-top-level resolution `field/2` already has, expressed once rather
      than three times, with nested winning when both carry a key. Collapse the
      `{:ok, value} | :error` wrapper now that it has one caller. Verify tasks 6.1
      pass and the existing `event_test.exs` suite is unchanged.

- [x] 6.3 Add `Event` tests for the `string_or_nil/1` inputs that currently raise:
      a `:file` carrying a surrogate code point, a `:file` that is an improper
      list, and a `:file` that is an empty list. Assert a row is returned with the
      field in deterministic textual form, and that `[]` is not rendered `"[]"`.
      Verify all three fail today.

- [x] 6.4 Make the character-data predicate the same total, cons-cell-walking
      predicate `chardata?/1` already is, so it cannot crash on an improper list
      and cannot accept a code point `List.to_string/1` will reject; let
      `string_or_nil/1` fall through to inspection as the message path already
      does. Verify tasks 6.3 pass and the message-rendering tests are unchanged.

- [x] 6.5 Add a test for a `:mfa` whose module is `nil`, asserting the row's
      `module` is `nil` rather than the string `"nil"`, then route
      `source_location/1` through the existing `string_or_nil/1` helper that already
      excludes `nil`. Verify the test passes and `WHERE module IS NULL` would find
      the row.

- [x] 6.6 Correct the `Event` moduledoc's "Where event fields live" section so the
      promise that both shapes are handled matches the single shared reader, and
      note that the self-feeding marker is recognised on either shape.

## 7. Failure reasons a host can act on

- [x] 7.1 Add an `Insert` test that inserts against an unreachable server and
      asserts the reported reason is the client's own message rather than an
      inspection of an error struct. Verify the test fails today with
      `%ClickHouse.ConnectionError{...}`.

- [x] 7.2 Replace `describe/1`'s unreachable `AshClickhouse.Error.ClickhouseError`
      clause with one covering the error structs the dependency actually returns,
      extracting the `:message` field. Verify task 7.1 passes and
      `mix compile --force --warnings-as-errors` is clean.

- [x] 7.3 Add a `Migration` test asserting `setup/1` returns `{:error, reason}`
      rather than raising when the configured database name is one the server
      would reject, such as `"app.production"`. Verify the test fails today with an
      `ArgumentError` escaping `setup/1`.

- [x] 7.4 Swap `validate_database!` for the non-raising validator in
      `ensure_database/1`, mapping its failure into the `{:error, reason}` the rest
      of `setup/1` returns, so both entry points reach their documented actionable
      message. Verify task 7.3 passes and the existing migration and Mix-task tests
      are unchanged.

## 8. Package contents and documentation that contradicts the code

- [x] 8.1 Corrected during implementation: the task as written ("add `config/` to
      the Hex manifest so the host's `ash_domains` entry reaches it") has a false
      premise — Mix evaluates only the *current* project's configuration, so a
      dependency's `config/` is never read by a host, and shipping it could not
      deliver the entry. Done instead: keep `config/` out of the manifest and
      assert that, and document the `ash_domains` line in the README where a host
      configures the repo, since that is the only place it can take effect. The
      spec delta's "Published package contents" requirement was amended to state
      this. Verify with `test/mix_project_test.exs` (the manifest contains no
      `config/` entry) and `test/clickhouse_ex_logger/readme_test.exs`.

- [x] 8.2 Fix the `CHANGELOG.md` entry that documents the node-capture option as
      `capture_node: false` to `:include_node`, which is the key
      `Handler.validate_include_node/1` and `Event` actually read, and add the
      `0.1.1` entry naming the two configurations now rejected at registration
      (`batch_size` above `max_buffer_size`, an unrecognised `:level`).

- [x] 8.3 Correct `LogEntry`'s moduledoc, which claims rows are ordered by
      `(timestamp, id)`, to state `ORDER BY (timestamp)` — the key the resource
      generates and the README already documents — and delete the verbatim
      duplicated `insert_opts` comment block inside `clickhouse do`.

- [x] 8.4 Correct `Insert`'s moduledoc, which says "Three separate defects" and
      "exactly the three points above" while enumerating two, so the count matches
      what is listed.

- [x] 8.5 Correct `Handler`'s `:buffer` documentation to state that the option
      accepts a pid, since an atom name is silently ignored by `buffer/1`.

- [x] 8.6 Run `mix format` over the changed files and verify with
      `mix format --check-formatted` on explicit paths — the no-argument form is
      silently defeated by Mix's `format_timestamp` cache on a warm `_build` — then
      verify `mix format --check-formatted <changed paths>` exits zero.

## 9. Whole-change verification

- [x] 9.1 Run `mix test` against the containerised ClickHouse and confirm the full
      suite passes, including the pre-existing 211 tests plus the new ones from
      tasks 1.1, 1.2, 2.1, 2.3, 2.4, 3.1, 3.3, 4.1–4.3, 5.1, 5.2, 6.1, 6.3, 6.5, 7.1,
      7.3, and 8.1.

- [x] 9.2 Run `mix test --cover` and confirm the 90% summary threshold in
      `mix.exs` still holds, since several fixes add branches that must themselves
      be exercised.

- [x] 9.3 Run `MIX_ENV=test mix compile --force --warnings-as-errors` and confirm a
      clean compile with no new warnings, in particular that removing
      `describe/1`'s dead clause leaves no unreachable-clause warning.

- [x] 9.4 Build the package and verify from the tarball's file list that it
      contains `lib/`, `priv/repo/migrations/`, and `config/`, and contains no test
      sources, coverage output, or AppleDouble sidecar — the manifest properties
      `test/mix_project_test.exs` guards.