# Proposal

## Why

Every ClickHouse failure the suite can currently provoke is a *fast* failure.
`buffer_failure_test` points the repo at a database that does not exist, so each
flush dies on its first chunk, instantly. That exercises one path — the clean
error return — and proves nothing about the two conditions the library actually
promises to survive: a ClickHouse that has gone *slow*, and a burst of load that
outruns it.

Both of those turn out to be broken, and neither is reachable without a database
that can be stopped mid-flight on purpose. A container harness makes them
reachable; writing the tests then exposes the defects.

## What Changes

- **A suite-scoped ClickHouse container replaces the hand-started server.**
  `testcontainer_ex` provisions it once per suite against Podman, waits for
  readiness, and points `ClickhouseLogger.Repo` at its mapped port.
  `docker-compose.yml` and the "start one yourself" instructions are removed, so
  there is one way to get a real ClickHouse rather than two that drift.
- **The suite fails fast when no container engine is available**, instead of
  excluding `:clickhouse` tests. The silent skip is how the tests this change
  exists to add would end up never running while the suite still reported green.
- **A workload test** that drives sustained concurrent load and asserts the
  load invariants (buffer never exceeds `max_buffer_size`, the logging process
  never blocks, loss is bounded and countable), then pauses the container
  mid-flight and asserts the pipeline degrades safely and recovers on unpause.
- **The shutdown flush becomes bounded.** `Buffer.terminate/2` performs one last
  synchronous insert with no time limit. A flush takes everything buffered, so
  against a stalled ClickHouse a default `max_buffer_size` of 10,000 rows is ten
  chunks at roughly the client's 15s `recv_timeout` each — `Handler.uninstall/1`
  can hang shutdown for minutes. The final write is now capped, matching the
  bound `uninstall/1` already applies to its own flush.
- **Counters account for rows a partially-failed insert actually committed.**
  `Insert.insert/1` chunks at 1000 rows and halts on the first failed chunk, but
  earlier chunks are already committed in ClickHouse. The buffer tallies the whole
  flush as zero delivered, so `accepted - delivered - discarded` over-reports loss
  by exactly the rows that landed, and nothing can detect it while every failure
  dies on chunk one. `Insert` now reports rows committed, and the buffer gains an
  additive `lost` counter so `accepted == delivered + discarded + lost` holds
  exactly.
- **`ClickhouseLogger.Case` defaults to `async: false`.** Five modules share
  globally-named state — the named `ClickhouseLogger.Buffer` and the repo
  connection — and two of them stop the shared Buffer in teardown while others
  are mid-test. `buffer_failure_test` documents itself as `async: false` but
  never sets it, and rewrites the global repo config while other modules write.
- **`ClickhouseLogger.Migration.server_available?/0` is removed.** Its only caller
  was the harness pre-check, which the container's wait strategy replaces.

## Capabilities

### New Capabilities

None. The test harness is not a durable capability of the library; it is how the
existing capability gets verified.

### Modified Capabilities

- `clickhouse-log-handler`: *"Failure handling and observability"* gains the
  `lost` counter and the row-level reconciliation it enables; *"Handler
  registration and lifecycle"* gains the bound on the final flush performed
  during removal.

## Impact

**Public API.** `ClickhouseLogger.Insert.insert/1` changes its return contract
from `:ok | {:error, message}` to `:ok | {:ok, count} | {:error, message, count}`.
It has exactly one caller. `ClickhouseLogger.Buffer.stats/1` gains a `:lost` key;
this is additive, and `failed` keeps its documented meaning of "flushes".
`ClickhouseLogger.Migration.server_available?/0` is deleted.

**Dependencies.** Adds `{:testcontainer_ex, "~> 0.9.1", only: :test}`. The Hex
package ships only `lib`, so the published artifact is unaffected.

**Runtime.** The ClickHouse image is pinned to the `26.9` line rather than
`latest`, so the versions `ClickhouseLogger.Insert` documents itself as verified
against cannot drift out from under that claim.

**Test environment.** Requires a running Podman (or Docker) engine. `mix test`
now fails with a diagnostic instead of skipping when none is present.
