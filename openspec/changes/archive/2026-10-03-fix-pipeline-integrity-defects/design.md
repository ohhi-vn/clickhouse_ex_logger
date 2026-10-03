# Design

## Context

See `proposal.md` — Why, and the specs delta for the required behaviour. What
shapes the *approach* is that every defect here sits on one of four seams, and
each seam already has an owner in the code:

| Seam | Owner | Defects |
| ---- | ----- | ------- |
| Write lifecycle in `Buffer` | `start_write/1`, `handle_info/2`, `terminate/2`, `tally/2` | dead write wedges the buffer; no tally fallback; `terminate` double write |
| Truth of the public call | `flush/2`, `stats/1` `catch` clauses | timeout reported as drained; busy buffer reported as idle |
| Config acceptance | `Handler.validate/1`, `install/2` | no `:level` check; no batch/buffer relationship; no rollback |
| Input totality | `Event.row/2`'s field readers | metadata/internal marker miss the top-level shape; `string_or_nil/1` raises; `"nil"` module |

Two constraints bound the work:

- **The library may not lose a row silently.** That is the property every other
  requirement exists to serve, so a fix that trades one silent loss for another is
  not a fix.
- **Rows are counted at row granularity, and the counts must reconcile.** Any new
  recovery path has to place the rows it abandons into `lost` or it breaks the
  reconciliation the spec states twice.

A third constraint is about how these defects were allowed to survive 211 passing
tests: none of them is reachable from the existing suite, because the suite never
kills a write process, never fails a `:logger.add_handler`, never passes a
top-level-shaped event, and never hands `:file` an invalid code point. So each fix
needs its own test that constructs the failure directly. That is why the task list
leads with tests rather than with implementation.

## Goals / Non-Goals

**Goals:**

- A write that dies without reporting leaves the buffer live, counts its rows as
  lost, and never again blocks a batch trigger.
- Every row the system accepted lands in `delivered`, `discarded`, or `lost`.
- No public function reports success for something it did not do.
- Registration either leaves a working pipeline or leaves nothing it started.
- Every handler option is validated, and every validation failure names the option.
- Row mapping is total over the inputs `Event.row/2` accepts, on both event
  shapes.
- The library's documentation, `@spec`s, and code say the same thing.

**Non-Goals:**

- Not fixing the `clickhouse` client. Its undefined `ClickHouse.NetworkError`
  struct and its `nil`-returning error lookup are upstream defects. This change
  makes the library survive them; it does not make them go away.
- Not changing the table shape, adding a migration, or touching the wire format.
  No column is added, removed, or reordered.
- Not adding retry, back-off, or a dead-letter path. The spec says a failed batch
  is discarded, and drop-oldest plus discard is the documented policy. Recovery
  from a *crashed write* is different from retrying a *rejected write*: the former
  must restore liveness, the latter must stay absent.
- Not restructuring `Buffer`'s state or introducing a supervisor for it. The
  single-process design is sound; the defects are in its transitions.
- Not adding a CI workflow. There is none today, and the format-gate story below
  needs one, but standing up CI is its own change with its own decisions.

## Decisions

### A crashed write is a failed flush, not a mystery

`handle_info({:DOWN, ref, :process, _pid, reason}, %{write_ref: ref})` currently
discards the message on the reasoning that "the result message already told us
everything we need". That is only true when the write process reaches its `send`.
The monitor exists precisely to report the case where it does not, and today that
report is thrown away — so `write_ref` stays set, `maybe_start_write/1` never fires
again, `flush/1` never replies, and `stats/1` keeps reporting `active?: true`
while nothing is delivered.

The fix is to route the `:DOWN` through the same accounting the result message
would have produced, with the whole batch treated as uncommitted: `lost +=
in_flight`, `failed += 1`, one `Logger.error`, then clear `write_ref` and let the
normal post-write path run (`flush_now` → `schedule_flush` → `reply_when_drained`).

*Alternative considered:* wrap the write in `try/rescue` inside the spawned
function so the send always happens. Rejected — it would have to catch exits too,
and it puts the accounting for a crash in two places instead of one. The `:DOWN`
message is the single signal that covers every way a write can fail to report, so
handling it is both sufficient and the smaller change.

*Consequence for the spec:* "at most one write outstanding" now holds at every
moment including shutdown, because `terminate/2` stops being able to start a
second one (see decision D).

### `tally/2` gets a fallback clause, and `Insert` stops advertising a shape it cannot produce

`tally/2` has exactly two clauses, and `Insert.insert/1`'s `@spec` and `@doc`
advertise a third shape (`{:error, message}`) that no code path returns — the
`reduce_while`/`case` pair in `insert/1` always rewrites a failure to the
three-tuple. That gap is doubly bad: the `@spec` documents as legitimate exactly
the result shape the buffer has no clause for, so a future change that *did* return
it would crash the buffer into decision A's wedge.

Two changes, deliberately separate: a catch-all `tally/2` clause that treats any
unrecognised result as a failed flush with the whole batch uncommitted, and a
corrected `@spec`/`@doc` on `Insert.insert/1` so the advertised union is the union
actually returned. The fallback is not redundant with the `:DOWN` handler — a
message that arrives but carries a shape nobody expected is not a dead process.

### `terminate/2` stops starting a write of its own

`terminate/2` calls `bounded_flush/1` whenever rows are queued, with no regard for
whether a write is already in flight. So shutdown can run two concurrent inserts:
the one `start_write/1` spawned and is still waiting on, and a new one. That
breaks the module's own "at most one write is in flight" invariant, and
`terminate/2` cannot learn the first one's outcome because it is about to stop.

The fix: when a write is already in flight, `terminate/2` bounds a wait for *that*
write rather than starting a second one. Concretely, `bounded_flush/1` becomes
"wait for the outstanding write, and only write queued rows itself once there is
nothing outstanding". The rows already handed to the in-flight insert are the
system's to account for; the ones still queued are still written by the bounded
path, so a shutdown flush still does not silently discard them.

This also fixes a second defect in the same function for free: `bounded_flush/1`'s
`receive` matches `{_ref, _result}` — any two-element tuple, not the ref it
created. A concurrent `{:enqueue, row}` cast sitting in the mailbox matches it
immediately, so `terminate/2` returns while its own write is still in flight and
the rows die with the process. The receive must be ref-matched.

### `flush/2` and `stats/1` stop conflating "gave up" with "done"

`flush/2`'s `catch :exit, _reason -> :ok` makes a call timeout indistinguishable
from a successful drain, and `Handler.uninstall/1` acts on that `:ok` by stopping
the buffer. `stats/1` has the mirror problem: `catch :exit, _ -> empty_stats()`
reports `active?: false` and all-zero counts for a buffer that is busy and
delivering.

The decision is to distinguish "the call did not complete" from "the call
completed". `flush/2` cannot keep returning a bare `:ok` and grow a second return
shape without widening its `@spec` in a way callers must now handle — so instead
the timeout is surfaced through the state the caller can already observe. Two
options:

1. Widen `flush/2` to return `{:ok, :drained} | {:error, :timeout}`. Explicit and
   greppable, but a breaking change to a public function for a case that currently
   hides itself.
2. Keep `:ok`, and have `terminate/2` — which is the thing that actually decides
   whether rows are discarded — be the single place that knows. `Handler.uninstall/1`
   then needs no timeout branch at all, because `terminate/2` already performs a
   bounded write and, under decision C, accounts for what it could not deliver.

Option 2 is chosen: it puts the decision at the point where the loss actually
happens, changes no public signature, and removes a branch from `uninstall/1`
rather than adding one. The trade-off is that `flush/2`'s `:ok` stays a weaker
promise than its doc currently claims, so the doc is corrected to say what it
actually guarantees. `stats/1` keeps returning zeroed counters for a *dead* buffer
(it cannot be asked a question) but must not claim `active?: false` merely because
one call timed out — so the catch clause narrows to the dead-server case.

*Alternative considered:* give `Buffer` a `drained?/0` call for `uninstall/1` to
check after the flush. Rejected: it is a second round trip whose answer can go
stale before it is acted on, and the information already exists in `terminate/2`.

### `install/2` validates everything, then starts nothing until it can finish

Two defects share one cause: `install/2` validates a *subset* of the config, then
runs effects in an order that cannot be undone.

`ensure_buffer_started/options` runs before `register/2`, so a registration
failure — `:logger` rejecting the level, say — leaves a running buffer that is
`start_link`ed to the caller. The moduledoc already promises the opposite.

The fix is two-part. First, `:level` is validated in `install/2` like every other
option, with the same `{:error, {option, message}}` shape, which removes the
reachable cause. Second, if registration still fails for a reason only `:logger`
knows, `install/2` stops a buffer *it* started — and only one it started, which is
why the "was already running" case has to be distinguished from the "I started it"
case. A buffer that existed before the attempt is left alone; `ensure_buffer_started/1`
already knows which case it is in, so the rollback is its to own rather than
`install/2`'s.

*Alternative considered:* register the handler first, start the buffer second, and
roll back the registration. Rejected — it inverts the safety property that matters
most: a handler attached to a buffer that failed to start would deliver into
nothing, whereas a buffer with no handler delivers into an empty queue that is
discarded harmlessly.

### Rejecting `batch_size > max_buffer_size`

`enforce_max_buffer/1` caps the queue one row at a time, so with
`batch_size > max_buffer_size` the queue never reaches `batch_size`,
`maybe_start_write/1` never fires, and every event past the cap is discarded for a
reason that has nothing to do with ClickHouse. In the recorded probe, 10 accepted
rows produced 7 discarded with a 60-second flush interval.

The decision is to reject the combination at registration with an error naming the
option, rather than to clamp, warn, or document. Clamping silently changes what
the host asked for; a warning goes where this library's config mistakes already go,
which is nowhere near the host. `batch_size == max_buffer_size` is accepted, so a
host that genuinely wants the smallest possible batch configures that.

This is the only place in the change where a configuration that works today will
start failing. It is called out in the proposal and the changelog entry because a
host on 0.1.0 could be running it.

### `Event` reads metadata the same way it reads every other field

`field/2` deliberately falls back from `:meta` to the top level because the OTP
version determines the shape. `metadata/1` and `fetch_meta/1` do not, so a
top-level event produces `metadata: %{}` — every user key silently dropped — and,
worse, `internal?/1` misses a top-level internal marker, which is the guard that
stops a ClickHouse outage feeding itself.

The fix is to give `metadata/1` and `fetch_meta/1` the same nested-then-top-level
lookup `field/2` already has, expressed once rather than three times. On the merge
precedence the moduledoc already states: nested wins.

`fetch_meta/1` returns `{:ok, value} | :error` solely so `internal?/1` can match
`{:ok, true}`; once the lookup is shared, that wrapper is an implementation detail
of one caller and can collapse into the shared reader.

`string_or_nil/1` is a separate defect with the same shape of fix. `chardata?/1`
already walks list cells directly and is total over improper lists; `charlist?/1`
uses `Enum.all?/2` and only range-checks, so it accepts a surrogate that
`List.to_string/1` then rejects, and it crashes on an improper list. The decision
is to make the character-data predicate the same total walk `chardata?/1` already
is, and to let `string_or_nil/1` fall through to inspection exactly as the message
path does — including for `[]`, which currently becomes `"[]"` because the
predicate short-circuits on the empty list.

`source_location/1` calls `inspect(module)` on a guard that accepts `nil`, while
`string_or_nil/1` has a clause that specifically excludes it. Routing through
`string_or_nil/1` gives the spec's "absent means absent" for free and removes the
inconsistency rather than adding a guard.

### Non-raising validation, real error text

`Migration.ensure_database/1` calls `AshClickhouse.Identifier.validate_database!/1`,
which raises `ArgumentError`. `setup/1`'s `@spec` promises `{:error, term()}`, and
both entry points have a documented, actionable failure message that a raise
bypasses entirely — the Mix task's checklist and `Utils.migrate/1`'s guidance about
which config key to fix.

The fix is to call the non-bang validator and map its failure into the same
`{:error, reason}` the rest of `setup/1` returns, so a database name like
`"app.production"` arrives at the host as a named failure instead of an exception.

`Insert.describe/1` is the same class of problem in the other direction: its
`AshClickhouse.Error.ClickhouseError` clause never matches, because
`AshClickhouse.Connection.insert_rows/4` only wraps *rescued* exceptions — a
client that *returns* `{:error, %ClickHouse.ConnectionError{}}` (the ordinary path
for connection and database errors) passes through unnormalised and falls to
`inspect/1`. Operators then read `%ClickHouse.DatabaseError{message: "…", code: 60}`
instead of the server's message. The decision is to describe the shapes the
dependency actually produces — a `:message` field on any client error struct — and
to delete the clause that cannot match, so the dead path does not read as coverage.

### Documentation that contradicts the code is fixed where it is found

These need no design, only accuracy: `mix.exs` ships `config/` so the host's
`ash_domains` entry is present; `CHANGELOG.md`'s `capture_node: false` becomes
`:include_node` (the unknown key is silently ignored today, so a host following
the changelog believes capture is off while it is on); `LogEntry`'s moduledoc says
`ORDER BY (timestamp)` because that is what the DDL generates and what the README
already says; `Insert`'s moduledoc enumerates the two defects it works around
rather than claiming three; `LogEntry`'s duplicated `insert_opts` comment block is
removed once; `Handler`'s `:buffer` doc says what the code accepts.

`handler.ex` is not `mix format`-formatted and `mix format --check-formatted` did
not catch it. Worth recording why, because it will happen again: with no file
arguments, Mix skips any file whose mtime is older than the timestamp it wrote on
the last `mix format` run. On a checkout whose `_build` predates an edit, the gate
checks nothing. The fix is the formatting itself; the durable fix is a CI job,
which is out of scope here and named in Non-Goals.

## Risks / Trade-offs

- **A host running `batch_size > max_buffer_size` on 0.1.0 will now fail to start
  the handler** → it fails at registration with an error naming the option, and
  nothing it started is left running, so the failure is legible rather than
  mysterious. Called out in the changelog. A host that wants the behaviour it had
  sets the two equal.
- **Treating a dead write as a failed flush adds a `Logger.error` per crash**
  where there was none → that is the point: the existing spec already requires one
  report per failed flush, and a crash was previously reported zero times. The
  message carries the `clickhouse_ex_logger_internal` marker, so it does not
  re-enter the pipeline.
- **The `tally/2` fallback can mask a genuine programming error in `Insert`** →
  accepted deliberately: it counts the rows lost and reports the failure, which is
  the behaviour the library promises for a failed write. A wrong result shape is a
  bug in the writer, and the buffer's job is to survive the writer, not to audit
  it. The corrected `@spec` narrows the window for it to happen.
- **Making `terminate/2` wait for an in-flight write instead of starting its own
  can lengthen shutdown** → bounded by the same `@shutdown_flush_timeout` the
  function already used, so the bound is unchanged. It can also mean fewer rows
  land at shutdown than before, in the case where two concurrent writes previously
  both succeeded; that trade is the price of the ordering invariant, and the rows
  are counted rather than lost silently.
- **Changing the `:level` and `batch_size`/`max_buffer_size` validation makes
  `install/2` reject configs it previously accepted** → the same rollback path
  applies, so a rejected install leaves nothing running. This is the second
  reachable cause the rollback exists for, and the reason the rollback is not
  "validate harder" alone.
- **Making `metadata/1` read the top level can, in principle, pick up a top-level
  key that `:meta` does not carry** → on any event carrying both, nested still
  wins, which is the precedence the moduledoc already documents. On an event
  carrying only top-level keys there is nothing to lose.
- **Shipping `config/` in the Hex manifest adds a file to the package** → it is a
  static `config/config.exs` for the library's own OTP application, containing no
  host-specific values, and its absence is what produces the host's domain
  warning. `test/mix_project_test.exs` already asserts manifest contents, so the
  property is guarded there rather than by inspection.

## Migration Plan

No schema change, no migration, no data rewrite. The rollout is:

1. Land the behavioural fixes and their tests; run the full suite plus the
   format gate over the touched files with explicit paths (`mix format --check-formatted
   lib/...`), since the no-argument form is unreliable on a warm `_build`.
2. Bump the version and add a changelog entry naming the two newly rejected
   configurations — `batch_size` above `max_buffer_size`, and an unrecognised
   `:level` — so a host upgrading from 0.1.0 is told before it hits them.
3. Republish, with `config/` in the manifest and the migration files still present;
   the existing manifest test and the documented release procedure both check the
   file list.

Rollback is reverting the release. Nothing a host has already written is affected
by the code, and no host state needs migrating: the two new rejections are
configuration-time and fixed by editing one value in the host's own config.

## Open Questions

None. Every choice above is settled at the level the specs and tasks depend on.
The one deferred item — a CI workflow that makes the format gate and the test suite
run on a clean `_build` — is named in Non-Goals as its own change, and nothing in
this design depends on it being resolved first.