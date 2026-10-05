# Design

## Context

See proposal.md — Why for the motivation and the measured baseline. What constrains
the approach:

**Two cost centres, both on the critical path, in different processes.**

The `:logger` handler callback runs **in the process that logged**
(`lib/clickhouse_ex_logger/handler.ex:147`). That process pays the whole of
`Event.row/2` on every event. The batch encoder runs on the buffer's own write
process, concurrently with logging, so its cost does not reach the caller but does
compete for CPU with the host under load.

**Mapping must stay in the caller.** Deferred by decision from the proposal's
author. This keeps the buffer holding rows rather than raw events, and keeps a
mapping failure rescued in the caller (`handler.ex:159`) rather than becoming a
buffer-level concern.

**The data layer owns the wire format, and that is deliberate.**
`AshClickhouse.DataLayer.Insert.build_insert_rows/2` is what
`ClickhouseExLogger.LogEntry` is for; `Insert`'s moduledoc states the resource is the
single source of truth for column names, order and encoding so the wire format cannot
drift from the table definition. Anything that stops calling it gives that up.

**`async_insert` is already enabled** (`log_entry.ex:82`), so server-side insert
batching is not available as a lever, and `wait_for_async_insert: 1` is what makes a
reported success mean the rows are queryable — which the buffer's failure accounting
depends on. Not to be touched.

**Two hypotheses were measured and refuted.** Recorded so they are not re-attempted:

| Hypothesis | Measured | Verdict |
| --- | --- | --- |
| `Atom.to_string(node())` per row is worth caching | **0.01 us** | No. Negligible; the node name is already an interned atom |
| `:maps.without/2` beats `Map.drop/2` with a 21-element list | 0.25 us vs 0.22 us | No. `Map.drop/2` is already the faster of the two |

The real wins are elsewhere, and the ranking below comes from measurement, not
inspection:

**Caller path, per event** (`Event.row/2` = 3.80 us with compound metadata, 2.53 us
with scalar-only):

| Work | us | Recoverable |
| --- | --- | --- |
| `stringify/1` over four metadata values | 0.93 | No — see below |
| `Ash.UUID.generate/0` | 0.56 | Only via a schema change — see decision 4 |
| module string + `function/arity` | 0.51 | **Yes** |
| `metadata/1` traversal (3 × `Map.drop` on a 21-element list, merge, rebuild) | 0.32 | **Yes** |
| `DateTime.from_unix!/2` | 0.14 | No |
| `List.to_string/1` on the file charlist | 0.10 | Marginal |
| node name | 0.01 | No |

Of that, 0.75 us is `inspect(value, limit: :infinity)` on a **one-key map**. That is
not incidental overhead: the spec requires a compound metadata value to round-trip to
an equivalent Elixir term (`spec.md` scenario "Metadata value is not a simple
scalar"), and `inspect/1` is what implements that. Optimising it away would change
required behaviour, so it is out of scope and is the floor under any budget claimed
for this path.

**Batch path, per row** (`Insert.insert/1`):

`normalize/1` costs 1.06 us/row — roughly 530 us per 500-row flush — of which about
0.7 us is ten `to_string/1` calls on field names. The data layer then converts the
same ten names **twice more per row** internally
(`deps/ash_clickhouse/lib/ash_clickhouse/data_layer/insert.ex:31-38`: one
`to_string(name)` for `Map.fetch/2` and one for `Map.fetch!/2`, per field). So the
field-name stringification this change removes is one third of the total, and the
other two thirds belong to the dependency.

## Goals / Non-Goals

**Goals**

- Cut the caller-path cost by the recoverable ~0.83 us of 3.80 us (~22%) without
  changing a single row's contents.
- Cut the batch path's per-row field-name stringification to zero.
- Leave behind a test that fails if the caller-path cost regresses.

**Non-Goals**

- Removing UUID generation from the caller (decision 4).
- Changing the `logs` schema, `Event.row/2`'s row shape, or any public API.
- Bypassing `build_insert_rows/2` (decision 3).
- Parallelising a flush's chunks. It would complicate the `committed` accounting the
  buffer's `delivered`/`lost` reconciliation depends on, and the
  "at most one write outstanding" ordering guarantee covers writes, not chunks —
  a distinction worth more than the throughput.
- Optimising `stringify/1`'s `inspect/1` call, which is required behaviour.

## Decisions

### 1. The budget covers this library's work, not the host's total `Logger.info/2` cost

The requirement measures entry to the handler callback through its return, not the
wall time of `Logger.info/2`.

**Why:** the host's total logging cost is dominated by `:logger`'s own message
formatting and by every other handler installed. In this repository, with the default
console handler attached, a `Logger.info/2` costs ~7.3 us while the handler callback
contributes ~2.5 us — so a total-cost budget would mostly measure the console handler,
would vary with whatever else the host configures, and could not be met by any change
to this library.

**Alternative rejected:** budget the total `Logger.info/2` cost. Unactionable and
host-dependent.

### 2. The budget is an average over ≥10,000 events, not a per-call ceiling

**Why:** the only timing assertion in the repository today is
`@max_call_micros 50_000` (`workload_test.exs:41`) — a 50 ms ceiling, about four
orders of magnitude above the real ~2.5 us. That number is so loose it cannot fail,
which is the same as having no assertion. A tight per-call maximum would be the
opposite failure: a single scheduler preemption on a shared CI runner would fail it
while the code is unchanged. Averaging over a long run is stable — repeated
measurements of the same code varied by about 5% — so a budget with ~20% headroom
over the measured post-change value is reliable in both directions.

**Consequence for the number:** the budget is set from a post-implementation
measurement on the implementation machine, not from the figures in the proposal,
which came from ad-hoc microbenchmarks on a different run. A budget carried over
from a different machine would be arbitrary. What the proposal's figures establish is
the *ranking* of costs and therefore which optimisations are worth doing — not the
threshold.

**Alternative rejected:** assert on a maximum. Flaky. **Also rejected:** commit a
baseline number and assert a ratio against it. More machinery, and it fails for the
wrong reason when the machine changes.

### 3. Keep `build_insert_rows/2`; remove only our own field-name conversion

`normalize/1` becomes a single pass that builds each row's string-keyed map from a
precomputed `{atom, string}` pairing of the resource's field names, so `to_string/1`
is not called per row per flush.

**Why:** this removes the 0.7 us we own without giving up the property `Insert`'s
moduledoc claims. The dependency's own two conversions per field per row remain — they
are the dependency's cost, on the buffer process, and touching them means restating
the column list and the value encoding independently of the resource, which is
exactly the drift the current design exists to prevent.

**Alternative rejected:** hand-build the encoded rows, skipping the data layer. Saves
the dependency's ~1.4 us/row too, at the cost of a second, independently maintained
copy of the table's shape. That is a correctness regression traded for buffer-side
microseconds; it is recorded here as the change to make if the batch path ever becomes
the measured bottleneck.

### 4. UUID generation stays in the caller

`Ash.UUID.generate/0` is 0.56 us — 15% of the caller path, and the second largest
single item. It is also the only remaining item that could be removed outright, by
giving the `id` column a server-side `DEFAULT generateUUIDv4()` and dropping it from
the insert.

**Why not now:** it costs a schema migration for every existing host
(`ALTER TABLE ... MODIFY COLUMN id UUID DEFAULT generateUUIDv4()`), a breaking change
to `Event.row/2`'s documented row shape and its `row()` type, and updates to every
test asserting an `id` — for a caller-path item smaller than the one it would sit
behind. `id` is also the field `LogEntry`'s moduledoc tells hosts to use for
cross-referencing a specific row, so it should stay predictable and client-side.

**What would change this:** the specification already declines to guarantee ordering
between two events sharing a microsecond — `WorkloadTest`'s moduledoc says so
explicitly, because `id` is a random UUID — so nothing depends on the id being
generated before the write. If a future measurement shows identifier generation
dominating the caller path, that is the change to make, and the migration is the
price.

### 5. Source-location strings are cached per distinct call site

The module string and `function/arity` string are derived once per distinct value and
reused.

**Why:** the set of call sites that log is small and fixed in a running system; the
number of events is not. This is the largest recoverable item in the caller path
(0.51 us) and the one with the clearest justification, because the derivation is a
pure function of a value that repeats.

**Cache:** read through `:persistent_term`, keyed by the source location. Chosen over
`:ets` because the hit rate is effectively 100% after warm-up — there is no eviction
policy to tune, no writer process to own, and reads are lock-free. The cardinality
risk is bounded by the number of distinct call sites, which the host's own code
determines and which cannot grow at runtime the way a cache keyed on arbitrary user
input could.

**Why the reuse cannot go stale:** the cached key *is* the source location, so a
different location is a different key and cannot read another location's value. The
requirement's "Reuse does not outlive a change of value" scenario is satisfied by
construction rather than by invalidation logic — there is nothing to invalidate. This
is why the cache is keyed on the location and not on the module alone.

**Alternative rejected:** pass the derived strings through the handler config,
computed once at `install/2`. Cheaper, but it caches one call site's values for all
of them, which is the conflation the "Distinct call sites are not conflated" scenario
forbids.

### 6. `metadata/1` becomes a single pass with O(1) reserved-key rejection

Today it drops the reserved event keys from the nested map, drops them from the top
level, drops `:meta`/`:msg`/`:level` from that result, merges the two, and rebuilds
the whole thing with `to_string/1` on every key. The replacement walks each map once,
rejecting reserved keys by lookup in a compile-time map rather than by membership in a
21-element list, and writes the string key directly.

**Why:** the shape must not change. Nested still wins per key over top level,
`:msg`/`:level` are still excluded only from the top-level read, and a compound value
is still rendered rather than dropped — the "Metadata value is not a simple scalar"
and "Metadata is carried at the top level of the event" scenarios depend on all three.
This is a rewrite of *how* the map is built, not of *what* it contains, and the
existing `Event` tests are the check that it is unchanged.

## Risks / Trade-offs

**[A wall-clock assertion in CI is machine-dependent]** → the budget is measured as
an average over ≥10,000 events with ~20% headroom, and asserted against the handler
callback only, not total `Logger.info/2`. Repeated measurements of unchanged code
varied ~5%. If the assertion proves flaky on CI it is to be loosened, not deleted —
deleting it returns the repository to having no cost assertion at all, which is the
condition this change exists to fix.

**A metadata rewrite that silently changes what is stored** → `metadata/1` feeds the
row's `metadata` column and the compound-value round-trip requirement. The existing
`Event` test suite is the guard; it must pass unchanged. If it cannot be made to pass
without altering behaviour, the single-pass rewrite is dropped rather than the tests
relaxed.

**`:persistent_term` writes are globally expensive** → the cache is written once per
*distinct* call site, never per event, which is what makes it viable at all. A write
per event would be far more costly than the 0.51 us saved. A host with an unusual
number of call sites pays a bounded one-off cost at first log per site.

**Unbounded cache growth if keyed on something unbounded** → the key is the source
location, whose cardinality is the host's static call sites. It cannot be driven by
log *content*. This is the reason for decision 5's key choice and must not be
"simplified" to key on, say, the message.

**The dependency's remaining 2/3 of field-name stringification is untouched** →
accepted deliberately (decision 3). Recorded so that a future profile showing
`build_insert_rows/2` dominating the batch path is recognised as the known next step
rather than rediscovered.

**Reducing the budget is not the same as reaching a throughput target** → this change
makes the library cheaper per event; it does not make ClickHouse faster. A host whose
problem is rows-per-second rather than cost-per-call will not see the improvement it
expects, and the CHANGELOG entry should say which of the two this is.

## Migration Plan

None. No schema change, no configuration change, no public API change. Existing hosts
upgrade and their rows are byte-identical.

**Rollback:** revert the commit. No host state is involved at any point.

**Verification before merge:** the full existing suite passes unchanged (in
particular `Event` and `Insert` tests, which pin the row contents this change must not
alter), plus the new cost test. Measure the caller path before and after on the same
machine in the same run and record both numbers in the CHANGELOG entry.

## Open Questions

None. The deferred identifier question is decision 4, which is resolved — including
the measurement that would reopen it — rather than left open.