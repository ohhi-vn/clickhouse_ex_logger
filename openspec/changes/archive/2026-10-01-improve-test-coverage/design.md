# Design

## Context

See proposal.md for motivation. What shapes the approach:

- **The suite is already dense.** 169 tests, all passing, covering the paths that
  matter at runtime: batching, ordering, overload, stalled ClickHouse, failure
  accounting, container isolation. This change is not about building a suite;
  it is about finding which of the remaining branches are untested *and* making
  the measurement itself possible.
- **Line coverage is a blunt instrument here.** Several uncovered lines are
  defensive `catch`/`rescue` guards that no input can reach. Writing a test for
  one means either mocking a private call or asserting on a race that cannot be
  scheduled. That is worse than leaving the line uncovered.
- **Two modules are shared global state.** `ClickhouseExLogger.Buffer` is
  registered under its own name and `ClickhouseExLogger.Repo` under its own, so
  every module that installs, stops, or repoints either is `async: false`.
  `mix clickhouse_ex_logger.migrate` starts connections and writes
  `schema_migrations`, so its tests are no exception.
- **The build directory lives on a volume that adds AppleDouble sidecars.**
  `lib/clickhouse_ex_logger/._buffer.ex` exists today, next to `buffer.ex`.

## Goals / Non-Goals

**Goals:**

- `mix test --cover` runs to completion and exits zero, without a manual
  `find . -name '._*' -delete`.
- Line coverage of `lib/` at or above 90%, enforced by configuration rather
  than by whoever remembers to look.
- Every uncovered `lib/` line ends in one of three states: covered by a test,
  deleted as unreachable, or explicitly accepted and listed here.
- `ClickhouseExLogger.Event.row/2` honours its "never raises" promise, per the
  delta in `specs/clickhouse-log-handler/spec.md`.

**Non-Goals:**

- 100% coverage. Chasing the last lines of `Buffer` and `Handler` would mean
  testing process-registration races.
- Anything about `test/support`. See "Gate `lib/`, not the harness" below.
- New runtime features, new options, changed defaults, changed public types.
- A different container harness, a different ClickHouse version, or a faster
  suite.

## Decisions

### Fix `elixirc_paths/1` rather than cleaning up before the run

`elixirc_paths/1` currently returns `["lib"]` (plus `"test/support"` under
`:test`), which Mix expands with `Path.wildcard("lib/**/*.ex")` — and that
matches `lib/clickhouse_ex_logger/._buffer.ex`, because the sidecar's name ends
in `.ex`. Mix compiles it, and `:cover` later globs `ebin/*.beam`, finds
`._Elixir.ClickhouseExLogger.Buffer.beam`, and aborts. `.gitignore` already
names this as the cause of "corrupt file header" and "table name already
exists"; the coverage crash is the same bug wearing a different hat.

So `elixirc_paths/1` returns an explicit, filtered file list:

```elixir
defp elixirc_paths(:test), do: source_files(["lib", "test/support"])
defp elixirc_paths(_), do: source_files(["lib"])

defp source_files(dirs) do
  dirs
  |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
  |> Enum.reject(&(Path.basename(&1) |> String.starts_with?("._")))
end
```

Mix accepts file paths here — `Mix.Compilers.Elixir.compile/7` passes
`elixirc_paths` through `Mix.Utils.extract_files/2`, which returns a regular
file as-is and only wildcards a directory. `elixirc_paths` is part of
`cache_key`, so changing its shape costs one recompile and nothing else.

**Alternative: a `test` alias that deletes sidecars first.** Rejected. Mix
drops the command line's arguments when a function alias is followed by
another element — `Mix.Task.join_args/3` returns only the alias's own arguments
when there are remaining elements — so `mix test --cover` would silently stop
being a coverage run. Even if it worked, it cleans the symptom and leaves the
sidecars in `lib/` to break the next compile.

**Alternative: `find . -name '._*' -delete` in a `pre_test` hook.** Same
objection: the sidecars keep coming back on every write from the volume.

Stale `._*.beam` files already in `_build` survive until the manifest is
rebuilt, so the first run after this lands needs one `mix clean`. That is a
one-time consequence of the volume, not a recurring step.

### Gate `lib/`, not the harness

`test_coverage:` in `mix.exs`:

```elixir
test_coverage: [
  summary: [threshold: 90],
  ignore_modules: [
    ~r/^ClickhouseExLogger\.(Case|CaptureHandler|TestContainer|TestServer)$/
  ]
]
```

`ignore_modules` accepts regexes matched against `inspect(mod)`, and
`summary: [threshold: 90]` is Elixir 1.20's own default made explicit — so the
gate is a stated project decision rather than an inherited constant that a
future Elixir could move. `mix test --cover` exits non-zero below it.

The four excluded modules are compiled into the test build only, never shipped
in the hex package (`package/0` lists `lib` alone), and 41 of
`TestContainer`'s 76 executable lines are diagnostics for conditions the suite
itself refuses to run under: no container engine, an unreachable socket, an
engine CLI that fails. Reaching them means uninstalling Podman and Docker, or
injecting faults into `TestcontainerEx`. The result would be tests asserting on
error message text, which is the failure mode coverage work is supposed to
reduce.

`ClickhouseExLogger.TestServer`'s two uncovered lines are `raise` clauses for a
failed query. Reaching one means a test that fails on purpose.

### Unreachable branches get deleted, not mocked

The rule for every uncovered line: reach it with a real input, delete it as
unreachable with a note saying why, or list it in this document as accepted.
Never mock a private function to tick a line.

Applying it to what the baseline measurement turned up:

| Line | Disposition | Why |
| --- | --- | --- |
| `buffer.ex:95` — `enqueue/2`'s `catch :exit` | **delete** | `GenServer.cast/2` returns `:ok` for an absent or dead server and never exits. Verified. The clause guards nothing. |
| `handler.ex:246` — `{:error, {:already_started, _pid}}` from `Buffer.start_link` | **delete** | `ensure_buffer_started/1` checks `GenServer.whereis(Buffer)` immediately before, so this can only fire in a race between the check and the start. The clause is a race, and losing that race is harmless. |
| `migration.ex:123` — `migrations_path`'s `{:error, _}` fallback | **delete** | `:code.priv_dir/1` on a loaded application always returns a path. The `"priv/repo/migrations"` fallback is the relative default `AshClickhouse.MigrationRunner` would compute anyway — and resolving against the caller's cwd is the bug the surrounding comment exists to avoid, so keeping it re-introduces the bug it documents. |
| `handler.ex:287` — `remove/1`'s `catch :exit` | **delete** | `:logger.remove_handler/1` returns `:ok` for an unknown id and does not exit. `uninstall/1` documents that it is safe to call unconditionally, which `:ok` already guarantees. |
| `migration.ex:101` — `ensure_database`'s `{:error, reason}` | **cover** | Point the repo at a dead URL; the `CREATE DATABASE` over the bootstrap connection fails and returns. |
| `buffer.ex:137` — `stop/1`'s `catch :exit` | **cover** | `GenServer.stop/1` on an absent name exits `:noproc`. There is already a test for the same guard on `flush/1` (`buffer_test.exs:299`) and none for `stop/1`. |
| `buffer.ex:208` — the `:DOWN` clause | **cover** | Send a matching `{:DOWN, ref, :process, pid, reason}` at the buffer while a write is in flight. It documents the monitor contract the surrounding comment describes, and Erlang does not order a message against a signal, so the clause is reachable in principle. |
| `handler.ex:280` — `add_handler`'s `{:error, reason}` | **accept** | `:logger.add_handler/2` has no failure mode reachable from `install/2`, whose argument is guarded `is_atom/1`. It stays as the passthrough that keeps `install/2`'s `{:error, term()}` in its spec honest. |
| `handler.ex:247` — `{:error, reason}` from `Buffer.start_link` | **accept** | Same reasoning; `Buffer.start_link/1` fails only on an argument or supervisor fault that `validate/1` has already excluded. |

Deleting these is behaviour-neutral: each clause is either unreachable or
already duplicated by the clause beneath it. None of it needs a delta spec.

### `Event.render/1`: widen the rescue, drop the dead clause

```elixir
rescue
  UnicodeConversionError -> inspect(chardata)
```

Elixir 1.20's `IO.chardata_to_string/1` is `List.to_string/1`, which raises
`UnicodeConversionError` — verified for an invalid byte, an out-of-range
codepoint, and a surrogate — and `UnicodeConversionError` does not inherit from
`ArgumentError`. The existing `rescue ArgumentError` therefore cannot fire: it
is unreachable for a list that passed `printable_chardata?/1`.

The improper-list case (`{:string, [1 | 2]}`) escapes differently — it breaks
`printable_chardata?/1` itself with a `FunctionClauseError`, before the rescue
is even in scope. Widening the rescue does not catch that. The delta spec
covers both cases, so `printable_chardata?/1` gets the same treatment: it must
return a boolean for any list, not raise.

How exposed this is in production, honestly: barely. `Handler.register/2` always
sets a formatter unless a host passes `formatter: nil`, and Elixir's own
`Logger.Formatter` crashes on invalid UTF-8 *first*, replacing the event with a
`{:report, %{formatter_crashed: ..., log_event: ...}}` that `render/1` inspects
without complaint. Verified against a real `:logger` handler. So the practical
path is a direct call to the public `Event.row/2`, which is documented never to
raise and is a public function. The fix is one rescue clause wide; the reason to
do it now rather than later is that the test suite is the only thing that will
ever notice a regression here, and the delta spec is what makes it stick.

### The Mix task is tested through `Mix.Task.run/2`, not by shelling out

`Mix.Tasks.ClickhouseExLogger.Migrate.run/1` calls
`Mix.Task.run("app.config", ["--no-start"])` internally. Under `mix test` that
returns `:noop` because the task has already run — harmless, since
`ClickhouseExLogger.Migration` reads `Application.fetch_env` at call time
through `AshClickhouse.Repo.config/0`, not through a cached config.

Three cases, all `async: false`:

1. **Success.** `Mix.shell(Mix.Shell.Process)`, run `run([])`, assert the
   `up to date` line arrives and that `logs` still exists. Running it a second
   time is the idempotency the spec already requires, so this covers the
   already-applied path for free.
2. **`--dry-run`.** `run(["--dry-run"])`, assert it succeeds and reports the
   migration as already applied, and that the table is unchanged.
3. **Failure.** Repoint the repo config at a dead URL, restart the connection,
   assert `Mix.Error` is raised and its message carries the `Could not create
   the ClickhouseExLogger schema` text, then restore. This is the same
   repoint-and-restore shape `buffer_failure_test.exs` already uses, and the
   reason `mix.raise/1`'s `format_reason/1` has two clauses worth covering.

This is called directly rather than through `System.cmd("mix", ...)` because the
suite already owns a live connection to the same database and a subprocess
would race it on `schema_migrations`.

### Reaching `Insert.insert/1`'s partial-commit contract for real

`insert/1` chunks at 1000 rows and halts on the first failure, reporting
`{:error, message, committed}`. `Buffer`'s `lost` counter is derived from
`committed`, and the spec requires `accepted == delivered + discarded + lost`
to hold exactly — yet no test has ever had a chunk succeed and a later one fail.
Every failure the suite provokes dies on chunk one with `committed == 0`.

Two tests close this:

1. **Chunking works.** Insert 2500 well-formed rows at a live ClickHouse and
   assert `{:ok, 2500}` — proof that more than one chunk was issued and that the
   chunk boundary is not an error.
2. **A later chunk fails.** The same 2500 rows, with one row the server will
   reject placed at position 1001 or beyond — an `id` that is not a UUID for a
   `UUID` column is the obvious candidate. Chunk 1 commits, chunk 2 is
   refused, and the return is `{:error, message, 1000}`.

If no row shape turns out to provoke a server-side refusal (the encoder may
normalise more than expected), the fallback is a `Buffer`-level test using the
same trick, and this is called out in tasks.md as a task that must not be closed
by asserting `committed == 0` again.

### Warning-clean is part of done

`test/clickhouse_ex_logger/buffer_failure_test.exs:153` binds `stats` twice and
never uses the first. Fixed, so `mix compile --warnings-as-errors` is clean —
otherwise a future warning is indistinguishable from today's.

## Risks / Trade-offs

- **[A deleted `catch` clause removes a safety net someone intended]** → Each
  deletion is one the table above justifies with a verified fact, not a guess.
  `GenServer.cast/2` not exiting is documented OTP behaviour; `:logger` not
  raising on an unknown handler id is likewise. The diff shows no behaviour
  change, and the reconciliation assertions in `buffer_test.exs` still pass.
- **[The new Migrate tests mutate the shared container]** → `async: false`,
  restore the repo config in `on_exit`, and truncate nothing — the migration
  tests only read.
- **[The 2500-row insert is slower than anything else in the suite]** → It is a
  single test. `async_insert` with `wait_for_async_insert: 1` keeps it to one
  server-side batch per chunk.
- **[`ignore_modules` lets test-support coverage rot silently]** → Accepted.
  Those modules are not shipped, and the alternative is a gate that only
  passes if the harness's failure diagnostics are unit-tested against a mocked
  container engine.
- **[A stale `_build` still breaks the first coverage run]** → `mix clean` is
  task 1, and `test_coverage`'s own failure mode is loud and self-explaining
  (it names the offending `.beam`).
- **[Tests written against current behaviour can cement behaviour that turns out
  to be wrong]** → Each new test targets a branch the spec or a moduledoc
  already describes. Where neither describes it, that is a finding, and the
  finding goes in this document rather than into a test.

## Migration Plan

None. No schema change, no config a host must adopt, no release step. The
behaviour change is confined to an error path in `Event.render/1` that no
reachable production input exercises. Rolling back is reverting the commit.

## Open Questions

- Whether the data layer's encoder lets an invalid `id` reach the server as
  written. If not, the second `Insert` test needs a different rejected column;
  the design holds either way, only the fixture changes. Resolved during
  implementation, in the task that writes the test.