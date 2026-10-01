# Proposal

## Why

The suite is broad — 169 tests, all passing — but coverage of the code that
ships has never actually been measured, because `mix test --cover` cannot run
and, when forced to, fails.

Two independent problems, in order of severity:

1. **Coverage does not run.** This checkout lives on an external volume that
   writes AppleDouble sidecars (`._Elixir.ClickhouseExLogger.Handler.beam`) next
   to every build artifact. `:cover` globs `ebin/*.beam`, chokes on them, and
   aborts the run:

   ```
   ** (exit) an exception was raised:
       ** (CaseClauseError) no case clause matching:
       {:error, :beam_lib,
        {:not_a_beam_file, ".../ebin/._Elixir.ClickhouseExLogger.Handler.beam"}}
   ```

   `.gitignore` documents the hazard and the manual remedy
   (`find . -name '._*' -delete`), but nothing prevents it. Nothing in the repo
   tells a contributor that coverage is broken, because nothing runs it.

2. **Coverage fails when it runs.** Elixir 1.20 enforces a default 90% line
   threshold, and `mix test --cover` exits non-zero. Measured on this branch:
   **78.18%** overall; **~86% (212/246 executable lines)** across `lib/` once
   the test harness is excluded.

The uncovered lines are not all equal, and the split is what makes this worth a
change:

| Area | Now | Uncovered | Why it matters |
| --- | --- | --- | --- |
| `Mix.Tasks.ClickhouseExLogger.Migrate` | **0%** | 9 lines | The one command a host must run. `--dry-run`, the success message, and the failure diagnostic have never run in a test. |
| `ClickhouseExLogger.Insert` | 77.78% | `insert([])`, both `describe/1` clauses, the non-`DateTime` timestamp passthrough | The 1000-row chunking and partial-commit contract that `Buffer`'s `lost` counter depends on is asserted only through a failure that dies on chunk one. |
| `ClickhouseExLogger.Handler` | 86.00% | `ensure_buffer_started/1`'s three outcomes, the `:buffer` pid override, `add_handler`'s error passthrough, `remove/1`'s exit guard | `:buffer` is documented in a comment as a host override and has zero tests. |
| `ClickhouseExLogger.Migration` | 88.00% | `dry_run?`, `ensure_database`'s error branch, the `priv_dir` fallback | `--dry-run` is advertised in the task's own moduledoc and never exercised. |
| `ClickhouseExLogger.Event` | 91.67% | `NaiveDateTime` stringify, a `%DateTime{}` timestamp passthrough, the `ArgumentError` rescue, the bare-term render fallback, empty chardata | Rendering paths that decide whether a row is dropped or mangled. |
| `ClickhouseExLogger.Buffer` | 96.30% | two `catch :exit` guards, the `:DOWN` clause | See design.md — some may be unreachable rather than untested. |
| `ClickhouseExLogger.Domain`, `Inspect.ClickhouseExLogger.LogEntry` | 0% | 3 lines | Derived module shells; one assertion each. |
| `test/support/ClickhouseExLogger.TestContainer` | 46.05% | 41 lines | Engine-selection and failure diagnostics. **Out of scope** — see below. |

## What Changes

- **`mix test --cover` becomes runnable and green.** The root cause is that
  `elixirc_paths/1` globs `**/*.ex`, which matches the `._*.ex` sidecars sitting
  beside every source file, so Mix compiles them and `:cover` later trips over
  the resulting `._*.beam`. `elixirc_paths/1` returns an explicit file list with
  sidecars filtered out, so they never reach the compiler. This also retires the
  "corrupt file header" / "table name already exists" failures `.gitignore`
  already warns about.
- **A 90% line-coverage gate over `lib/`, and only `lib/`.** Set through
  `test_coverage:` in `mix.exs` — `summary: [threshold: 90]` plus an
  `ignore_modules` regex for the four `test/support` modules. They are compiled
  into the test build only, never shipped, and 41 of `TestContainer`'s 76
  executable lines are diagnostics that only fire when no container engine
  exists — reachable only by uninstalling Podman and Docker. Gating on them
  would buy assertions about error message text, not about behaviour.
- **Tests for the untested public surface**, prioritised by what a host or an
  operator actually touches: the Mix task, then `Insert`'s accounting and error
  rendering, then `Handler`'s install/override paths, then `Migration`'s dry run,
  then `Event`'s remaining render branches.
- **`ClickhouseExLogger.Event.row/2` is fixed to keep its "never raises" promise.**
  Its `rescue ArgumentError` cannot fire: on Elixir 1.20,
  `IO.chardata_to_string/1` raises `UnicodeConversionError`, which is not an
  `ArgumentError`. Chardata that is not valid Unicode therefore escapes the
  mapper, `Handler.log/2`'s outer rescue swallows it, and the row is lost
  without being counted anywhere. The rescue is widened and the dead
  `ArgumentError` clause removed; see design.md for how narrow the real-world
  exposure is.
- **A `--warnings-as-errors` clean test build.** The suite currently compiles
  with a warning (`stats` unused, `test/clickhouse_ex_logger/buffer_failure_test.exs:153`).

Explicitly **not** in scope: new runtime features, new library options, and any
change to how the library behaves.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `clickhouse-log-handler`: *"Event-to-row mapping"* gains the guarantee that
  mapping an event to a row does not raise whatever the message field contains,
  with scenarios for non-Unicode chardata and for a message that is not
  well-formed chardata. That is the only requirement text this change moves.

Everything else here adds evidence for requirements `clickhouse-log-handler`
already states — the migration command, partial-commit accounting, the batching
triggers, counter reconciliation — plus the tooling to measure it.

**Escape hatch.** If a test written later in this change exposes a further
defect whose fix changes observable behaviour, a delta spec is written *before*
the fix lands. Fixes that delete provably unreachable defensive code, or add a
test for already-documented behaviour, stay inside this change without one.

## Impact

**Runtime and public API.** One behaviour change, in
`ClickhouseExLogger.Event.render/1`: message chardata that cannot be converted
to text is inspected instead of raising. `Event.row/2`'s signature and return
shape are unchanged; only the previously-raising path changes. Plus
`elixirc_paths/1` in `mix.exs`, which is build configuration.

**Test build.** Two new test modules, plus additions to the existing ones. The
Migrate task's tests run against the suite's container, so they are
`async: false` like every other module that touches ClickHouse — `mix
clickhouse_ex_logger.migrate` mutates the shared database and
`schema_migrations` table.

**Dependencies.** None.

**Developer workflow.** `mix test --cover` becomes the coverage command of
record. A developer with a pre-existing stale build still needs one `mix clean`
(removing `._*.beam` files already written) before the first run after this
lands; that is a one-time artefact of the volume, not a recurring step.