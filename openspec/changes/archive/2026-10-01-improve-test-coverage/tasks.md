# Tasks

Ordered so each group is verifiable before the next begins. Group 1 unblocks
everything: until `mix test --cover` runs at all, no coverage claim in the later
groups can be checked.

## 1. Make coverage measurable

- [x] 1.1 `mix clean`, then `mix test --cover` and record the baseline, confirming it now reaches the summary table and exits non-zero with the threshold message. This reproduces the defect in the proposal; if it still dies with `:not_a_beam_file`, the sidecars are being created somewhere other than `elixirc_paths` — stop and record what the message names before going on. **Baseline: 86.56% over `lib/`, threshold 90%, exit non-zero. The stop condition did fire — see 1.2.**
- [ ] 1.2 Change `elixirc_paths/1` in `mix.exs` to return an explicit, sidecar-filtered list of `.ex` files (see design.md, "Fix `elixirc_paths/1` rather than cleaning up before the run"). Verify `mix compile --force` succeeds, no `._*.beam` appears under `_build/*/*/ebin`, and `lib/clickhouse_ex_logger/._buffer.ex` is still on disk untouched. **Not implemented — the premise is wrong.** `Path.wildcard/2` defaults to `match_dot: false`, so Mix already excluded `._*.ex`; a filter here is a provable no-op. The sidecars are written by the exFAT volume *beside the beams Mix emits*, which `elixirc_paths/0` cannot reach. Fixed instead by `test/support/coverage_tool.ex`. Closing this task needs a decision.
- [x] 1.3 Add `test_coverage: [summary: [threshold: 90], ignore_modules: [~r/^ClickhouseExLogger\.(Case|CaptureHandler|TestContainer|TestServer)$/]]` to `mix.exs`. Verify `mix test --cover` prints a summary that no longer lists those four modules and still exits non-zero on the current total. **Done, plus `tool: ClickhouseExLogger.CoverageTool`, which 1.2's substitution required.**
- [x] 1.4 Run `mix test` (no `--cover`) and confirm it still passes at 169 tests, so 1.2 and 1.3 changed nothing about the build.

## 2. Fix `Event.render/1` and lock it down

- [x] 2.1 Widen the rescue in `ClickhouseExLogger.Event.render/1` to `UnicodeConversionError` and remove the unreachable `ArgumentError` clause (design.md, "`Event.render/1`: widen the rescue, drop the dead clause"). Verify `Event.row/2` returns a row for `%{msg: {:string, [<<0xFF>>]}}` instead of raising.
- [x] 2.2 Make `printable_chardata?/1` return a boolean for any list rather than raising on a malformed one, so the improper-list case in the delta spec is covered by the same fix. Verify `Event.row/2` returns a row for `%{msg: {:string, [1 | 2]}}`. **Implemented as a total `chardata?/1` over cons cells, which let `printable_chardata?/1` go away entirely rather than gain a dead fallback clause.**
- [x] 2.3 Add tests to `test/clickhouse_ex_logger/event_test.exs` for both scenarios in `specs/clickhouse-log-handler/spec.md`: non-Unicode chardata, and a message that is not well-formed chardata. Each asserts a returned row with an inspected message — never that the call raises.
- [x] 2.4 Fill the remaining `Event` gaps from the same file: `stringify/1` on a `%NaiveDateTime{}`, a `%DateTime{}` passed as the event's `:time` (asserted to be preserved, not replaced by `utc_now`), a bare non-tuple `:msg` term, and `{:string, []}`. Verify all four pass and that `ClickhouseExLogger.Event` reaches the threshold. **Event at 100%.**

## 3. Cover the Mix task

- [x] 3.1 Add `test/clickhouse_ex_logger/migrate_task_test.exs` using `ClickhouseExLogger.Case` (`async: false`). Test the success path: `Mix.shell(Mix.Shell.Process)`, call `Mix.Tasks.ClickhouseExLogger.Migrate.run([])`, restore the shell in `on_exit`, and assert the "up to date" line arrives. Run it twice in the one test so the idempotent path is covered too.
- [x] 3.2 Add the `--dry-run` case to the same module: `run(["--dry-run"])` succeeds, reports the migration as already applied, and leaves the `logs` table intact. Verify the suite's `logs` table still has the columns `resource_test.exs` asserts on.
- [x] 3.3 Add the failure case: repoint `Application` env for `ClickhouseExLogger.Repo` at a dead URL, restart the connection (the shape `buffer_failure_test.exs` already uses), assert `Mix.Error` is raised carrying the "Could not create the ClickhouseExLogger schema" text, and restore in `on_exit`. Verify the failure covers `format_reason/1`'s non-binary clause.
- [x] 3.4 Verify `mix test --cover` reports `Mix.Tasks.ClickhouseExLogger.Migrate` at or above 90%, and that the whole suite still passes. **Migrate at 100%.** Two findings along the way: `Migration.setup/1` raises on a second call in one VM (arranged around in the test, `migration.ex`'s moduledoc corrected), and `WorkloadTest` had a pre-existing flake where the pre-stall write could land before the pause (`delivered == 0` raced it) — now waits for delivery first.

## 4. Cover `Insert`'s accounting and error rendering

- [x] 4.1 Add a unit test that `Insert.insert([])` returns `{:ok, 0}` with no connection touched. Verify it passes without a running buffer or repo connection.
- [x] 4.2 Add a test that a row whose `:timestamp` is already an ISO-8601 string is inserted unchanged, covering `normalize/1`'s non-`DateTime` passthrough. Read the row back and assert the stored timestamp.
- [x] 4.3 Add a test that a failed insert returns the server's message rather than `inspect(reason)`, covering `describe/1`'s `ClickhouseError` and binary clauses. Verify against the absent-database setup `buffer_failure_test.exs` uses. **Those two clauses turned out unreachable** — see 4.6. Covered the fallback clause instead, via a server-rejected UUID and via `UNKNOWN_DATABASE`.
- [x] 4.4 Add a chunking test: insert 2500 well-formed rows at the live ClickHouse and assert `{:ok, 2500}`, proving more than one 1000-row chunk is issued successfully. Verify the count back with a query.
- [x] 4.5 Add the partial-commit test from design.md: 2500 rows with one the server rejects at position 1001 or beyond, asserting `{:error, _message, 1000}`. Record on this task which column was rejected. **Rejected column: `id`.** An `id` that is not a UUID reaches the server as written and comes back `CANNOT_PARSE_UUID`, so 1000 rows commit and the second chunk is refused. The design's open question is resolved.
- [x] 4.6 Verify `ClickhouseExLogger.Insert` reaches the threshold and that `buffer_test.exs`' reconciliation assertions still pass unchanged. **Insert is at 88.89%, accepted.** The two uncovered lines are `describe/1`'s `AshClickhouse.Error.ClickhouseError` and `is_binary` clauses, unreachable through the real stack: an absent database, a server-rejected UUID and a stalled server all return a client error *struct* (the fallback clause), and the wrapped shape appears only when the client raises, which `clickhouse` 0.32 does not do for these failures. `AshClickhouse.Connection.insert_rows/4` documents that it wraps raised client errors, so the clause is defensive against a real upstream behaviour and stays. `Handler` has the same situation for its two accepted error passthroughs and reads 95.74%. Reconciliation assertions pass unchanged.

## 5. Cover `Handler` and `Migration`

- [x] 5.1 Add a test for the `:buffer` option: install the handler with `buffer: pid` pointing at a buffer started under another name, log, and assert the row lands there. This is documented behaviour with no test today.
- [x] 5.2 Add a test calling `Handler.ensure_buffer_started/1` directly with an invalid batching config, asserting the `{:error, {option, message}}` it returns rather than reaching `install/2`'s earlier validation.
- [x] 5.3 Add a test asserting `Handler.defaults/0` equals the options an omitted config produces, covering the public function nothing currently calls.
- [x] 5.4 Add a `--dry-run` case for `ClickhouseExLogger.Migration.setup/1` (distinct from the Mix task's, called directly) and a dead-URL case covering `ensure_database`'s error branch. **The error branch is unreachable** — `Identifier.validate_database!/1` raises rather than returning an error, so `ensure_database/1`'s `{:ok, _} =` assertion fires first. Covered `setup/1`'s dry run and its `priv_dir` path resolution instead, in a new `migration_test.exs`. **Migration at 100%.**
- [x] 5.5 Delete the four clauses listed under "Unreachable branches get deleted, not mocked" in design.md — `buffer.ex` `enqueue/2`'s `catch`, `handler.ex` `ensure_buffer_started/1`'s `{:error, {:already_started, _pid}}`, `handler.ex` `remove/1`'s `catch`, `migration.ex` `migrations_path`'s `{:error, _}` fallback — updating each surrounding comment to say why the guard is gone. Verify `mix test` still passes and that no spec requirement depended on them.
- [x] 5.6 Add a test for `Buffer.stop/1` against an absent buffer, and one that sends a matching `{:DOWN, ref, :process, pid, reason}` at a buffer with a write in flight to cover the monitor clause. Verify `ClickhouseExLogger.Buffer` and `ClickhouseExLogger.Handler` reach the threshold. **Buffer at 100%, Handler at 95.74% with its two accepted error passthroughs.**

## 6. Close out

- [x] 6.1 Fix the unused `stats` binding at `test/clickhouse_ex_logger/buffer_failure_test.exs:153`, then verify `mix compile --force --warnings-as-errors` is clean for both `:dev` and `:test`.
- [x] 6.2 Add one-line existence assertions for `ClickhouseExLogger.Domain` (e.g. `Ash.Domain.Info.resources/1` returns `[ClickhouseExLogger.LogEntry]`) and for `inspect(clickhouse_exLogger.LogEntry)`, covering the two 0% modules in `lib/`. Verify neither reports 0%. **Unsatisfiable as written, and the existing `ResourceTest` assertions were already there.** Both modules' only executable lines are their module bodies, which run at compile time, so `:cover` reports 0.00% for them no matter how they are exercised. Added them to `test_coverage`'s `:ignore_modules` instead, with the reason recorded there, so the report stops carrying two phantom rows.
- [x] 6.3 Run `mix test --cover` and confirm the command exits zero with `ClickhouseExLogger.Domain`, `Insert`, `Handler`, `Event`, `Migration`, `Mix.Tasks.ClickhouseExLogger.Migrate` and `Buffer` all at or above 90%, and the four `test/support` modules absent from the summary. Paste the summary table on this task. **Exits 0 from a clean build. `Insert` is the one exception at 88.89%, accepted under 4.6; `Domain` is absent by design under 6.2.**

```
| Percentage | Module                               |
|------------|--------------------------------------|
|     88.89% | ClickhouseExLogger.Insert            |
|     95.74% | ClickhouseExLogger.Handler           |
|    100.00% | ClickhouseExLogger                   |
|    100.00% | ClickhouseExLogger.Buffer            |
|    100.00% | ClickhouseExLogger.Event             |
|    100.00% | ClickhouseExLogger.LogEntry          |
|    100.00% | ClickhouseExLogger.Migration         |
|    100.00% | ClickhouseExLogger.Repo              |
|    100.00% | Mix.Tasks.ClickhouseExLogger.Migrate |
|------------|--------------------------------------|
|     98.37% | Total                                |
```

- [x] 6.4 Run `mix test` twice more and confirm a stable pass, so no new test depends on ordering or on a container left in a particular state. **Six consecutive runs plus two seeded runs, 197 passed each. The one flake found along the way — `WorkloadTest`'s `delivered == 0` racing the container pause — was fixed under 3.4 and has not recurred.**
- [x] 6.5 Re-read design.md's risk list and confirm each mitigation held. Anything that did not is recorded here rather than quietly dropped.

  | Risk | Held? |
  | --- | --- |
  | Deleted `catch` clauses remove an intended safety net | Yes. `GenServer.cast/2` not exiting and `:logger.remove_handler/1` not raising on an unknown id are both documented behaviour; the suite passes and the reconciliation assertions are unchanged. |
  | Migrate tests mutate the shared container | Yes. `async: false`, config restored in `on_exit`, and no test truncates or drops anything. The dry-run probe was dropped and verified removed. |
  | The 2500-row insert is slow | Barely. It is one test; the whole suite still finishes in ~18s. |
  | `ignore_modules` lets harness coverage rot | Yes, and it grew honestly: `CoverageTool` and the two compile-time-only modules were added rather than the threshold being lowered. |
  | A stale `_build` breaks the first coverage run | No longer true. `mix clean && mix test --cover` was run as the final verification, and it passes. |
  | Tests cement behaviour that turns out wrong | Two cases surfaced and were recorded rather than cemented: `Event.render/1`'s dead rescue (fixed under 2.1 with a delta spec) and `Migration.setup/1`'s one-call-per-VM limit (documented under 3.1, not worked around silently). |