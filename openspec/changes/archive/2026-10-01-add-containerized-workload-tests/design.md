# Design

## Context

See `proposal.md` — Why, for motivation. What constrains the approach:

**The failure paths we need are not reachable with the current harness.**
`ClickhouseLogger.BufferFailureTest` provokes failure by pointing the repo at a
database that does not exist. ClickHouse stays reachable and answers instantly,
so every flush fails on its first chunk. There is no way to make a *hung* server,
which is the condition the batching design actually claims to survive.

**The relevant timeouts are fixed and finite.** `Insert.insert/1` passes only
`Dsl.insert_opts(resource)` — `[async_insert: 1, wait_for_async_insert: 1]`, no
timeout keys — so `ClickHouse.Interface.HTTP.Client` falls back to its
`@opts_schema` defaults: `checkout_timeout` 8s, `connect_timeout` 8s,
`recv_timeout` 15s. A stalled server therefore fails a chunk after ~15s rather
than hanging forever, and the failure is recoverable.

**But a flush takes everything buffered, and `Insert` chunks at 1000 rows.**
`Buffer.start_write/1` moves the whole queue into a single write, so a default
`max_buffer_size` of 10,000 is ten sequential chunks. Against a stalled server
that is roughly 150s for one flush, and the two call sites that drain on shutdown
are not equally careful about it.

**Five test modules share two globally-named things.** `ClickhouseLogger.Buffer`
is registered under its module name, and `ClickhouseLogger.Repo` is a single
AshClickhouse connection. `handler_test` and `integration_test` each call
`Handler.install/2` (which starts that named Buffer) and each tear down with
`Handler.uninstall/1` (which calls `Buffer.stop/1` on it). `buffer_failure_test`
rewrites the global repo config and restarts the connection from `setup`. All
three run `async: true`, because `ClickhouseLogger.Case` never passes `async:`
— even though `buffer_failure_test`'s moduledoc states it is `async: false`.

**Podman is the target engine, and the image is already local.**
`podman machine` is running and its forwarded socket is present; the
`clickhouse/clickhouse-server` image is in the local store.

## Goals / Non-Goals

**Goals:**

- Make a *stalled* ClickHouse reachable from a test, deterministically.
- Prove the load invariants against a real server, and make the proof fail loudly
  if the invariants break.
- Reconcile the event counters exactly, so an operator can answer "how many logs
  did I lose" without inference.
- Keep `mix test` runnable on a machine with Podman or Docker and no manual setup.

**Non-Goals:**

- **Throughput characterisation.** No events/sec, no latency percentiles, no
  tuning of `batch_size` / `max_buffer_size`. Those are benchmark outputs, not
  assertions, and belong in a separate harness if wanted.
- **Ordering under concurrent producers.** The library's spec claims
  `ORDER BY timestamp, id` reproduces logged order. A random v4 `id` cannot do
  that, and measurement confirms it: 5000 events from one process produce 5000
  distinct timestamps (the tiebreaker never fires), while 1000 events from 20
  processes produce 924 distinct (76 collisions, no recoverable order). That
  claim is wrong and is a separate change — the workload test asserts ordering
  per producer, or not at all.
- **Fault injection finer than pause.** `TestcontainerEx.ToxiproxyContainer`
  exists and would allow latency and per-error shaping. Overkill here: `pause`
  already produces the ~15s stalled-server condition, and that is the condition
  under investigation.

## Decisions

**1. One container for the suite, started in `test_helper.exs`.**

`TestcontainerEx.ExUnit.container/3` with `shared: true` gives one container per
test *module*. Five modules use `ClickhouseLogger.Case`, so that is five ClickHouse
boots per run. Starting a single container in `test_helper.exs` and pointing the
suite at it costs one boot and requires no change to any existing test — they
already share a database and truncate per test.

The URL must reach `ClickhouseLogger.Repo` before `Migration.setup()` runs.
`AshClickhouse.Repo.config_to_conn_opts/1` reads application env at call time, so
`Application.put_env/3` from `test_helper.exs` overrides `config/test.exs` with
no rebuild.

Teardown uses `ExUnit.after_suite/2`.

**2. `reuse: true`, and the container is deliberately left running after the suite.**

ClickHouse takes a few seconds to become ready, which is most of the current
suite's wall time. Reuse skips that on every run after the first. The container
holds nothing the suite depends on — `Migration.setup/1` is idempotent and every
test truncates — so a reused container with stale rows is harmless. Stopping it in
`after_suite` would defeat the reuse; cleanup is the user's explicit
`podman rm`.

**3. Image pinned to `26.9`, not `latest`.**

`ClickhouseLogger.Insert`'s moduledoc states it is verified against
`ash_clickhouse` 0.7.3, `clickhouse` 0.32.0 and ClickHouse 26.9, and its whole
reason for existing is a set of version-specific defects. `latest` lets that
claim rot silently — a new server version could break an insert path with no test
failing. Both `26.9` and `26.9-alpine` exist upstream; `26.9` matches what is
already verified.

**4. Fail fast rather than skip when no engine is available.**

Today `test_helper.exs` excludes `:clickhouse` and the suite reports green. For
the four pure modules that is a reasonable convenience; for the workload test it
is the exact failure mode this change exists to prevent — the one test that proves
the pipeline survives a real stall, silently never running. Only
`event_test`, `resource_test`, `readme_test` and `clickhouse_logger_test` need no
database, so failing fast costs four files on an engine-less machine and buys an
honest signal everywhere else.

**5. `ClickhouseLogger.Case` defaults to `async: false`.**

The pause-based test freezes the shared container for every other module, so it
must have exclusive use. ExUnit runs all `async: true` modules first, then sync
modules one at a time, so a sync module is safe by construction rather than by
timing. Making that the template default is what makes it true — today two
modules stop the shared Buffer out from under each other, and `buffer_failure_test`
believes it is sync when it is not. A module that genuinely needs concurrency opts
in with `use ClickhouseLogger.Case, async: true`.

Serialising does cost wall time, which is why the opt-in exists.

**6. D1: bound the shutdown flush at a constant, don't remove it.**

`Handler.uninstall/1` already spends 5s on `Buffer.flush/2` and then calls
`Buffer.stop/1`, whose `GenServer.stop` defaults to `:infinity`, whose `terminate/2`
then performs a synchronous `bulk_create/1` over everything buffered.

Removing that write would regress a stated requirement — the spec says removal
flushes buffered events — so the fix is a bound, not a deletion. The write moves
onto a monitored spawned process and `terminate/2` waits for it with a `receive`
and `after`, the same `spawn_monitor` shape `start_write/1` already uses. On
timeout the rows are simply not written; they were already accepted and are
already counted, so the loss shows up in `lost` rather than vanishing.

The bound is a module constant rather than a new batching option. One number,
already spent by `uninstall/1`, in two places — not a knob for a value with one
sane setting.

**7. D2: report rows committed; add `lost`; leave `failed` alone.**

`Insert.insert/1` reduces over chunks and halts on the first error. The cleanest
expression is to accumulate the committed count alongside the result, returning
`{:ok, committed}` or `{:error, message, committed}`. The buffer then credits
`delivered` with what ClickHouse accepted and charges the remainder to `lost`.

`failed` keeps counting flushes. It is documented that way, and
`buffer_failure_test` asserts it. Redefining it to mean rows would be a smaller
diff and a worse API — an operator who reads `failed: 3` should be able to say
"three flushes did not land" without knowing how big they were.

The invariant this buys:

```
accepted == delivered + discarded + lost
```

It closes exactly, because `accepted` increments on every `put_row` — including a
row `enforce_max_buffer/1` drops immediately — and rows in flight are counted
nowhere else. That is what makes `accepted - delivered - discarded`, previously
the only available loss estimate, correct as a fallback for anyone reading only
the old keys.

**8. Keep `Migration.setup/1` as the only schema path.**

The container is provisioned with no database, and `Migration.setup/1` creates it
and applies `priv/repo/migrations`. The suite deliberately exercises the same code
a host application runs, so this stays rather than being replaced by the
container's `with_database/2`. That also keeps `server_available?/0` redundant:
the wait strategy already guarantees the server answers before any test runs, so
the pre-flight ping is removed with its only caller.

## Risks / Trade-offs

- **A container engine becomes a hard prerequisite for `mix test`** → Accepted.
  Four pure modules still run without one; the rest never ran meaningfully anyway.
  The failure message names the detected engine and its status.

- **Serialising integration modules lengthens the suite** → Mitigated by
  `async: true` remaining available per module, and by `reuse: true` removing boot
  time from all runs after the first.

- **The 5s shutdown bound drops rows on a slow-but-healthy server** → Accepted.
  It is bounded, counted, and matches the bound `uninstall/1` already applies.
  Against a healthy ClickHouse a 10,000-row flush is ten small inserts and
  comfortably inside 5s.

- **Hackney keeps pooled sockets to a paused container** → After unpause, a reused
  socket may be dead. `ClickHouse.Interface.HTTP.Client` retries `{:error,
  :closed}` up to three times, and the workload test asserts recovery rather than
  assuming it.

- **Pinning to `26.9` stops automatic coverage of new server versions** → Accepted
  deliberately; automatic coverage is what makes the `Insert` workaround's
  "verified against" claim meaningless.

- **`reuse: true` leaves a container running after the suite** → Documented as an
  explicit `podman rm`, which is standard testcontainers practice.

## Migration Plan

No deployment steps: the runtime behaviour changes are additive except for the
`Migration.server_available?/0` removal, which had a single test-only caller.

For contributors, `mix test` now requires a running Podman or Docker engine
instead of an optional server. Rollback is reverting the change; the previous
`docker-compose.yml`-plus-`CLICKHOUSE_URL` flow is self-contained in git history.

## Open Questions

None. The ordering overclaim is explicitly a non-goal here and does not affect
the specs, approach, or task breakdown of this change.
