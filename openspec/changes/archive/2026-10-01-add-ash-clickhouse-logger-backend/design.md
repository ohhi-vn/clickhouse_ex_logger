# Design

## Context

The repo is an unmodified `mix new` scaffold: one `ClickhouseLogger.hello/0`
module, one doctest, no dependencies, no `config/`. There is no existing
convention to preserve, so this change establishes the layout.

Two facts from the installed-dependency documentation shape everything below
(Ash v3.33.11, AshClickhouse v0.7.3, Elixir ~> 1.20):

- `AshClickhouse.DataLayer` supports `:bulk_create` as a batched `INSERT`
  (default chunk size 1000). It does **not** support `:upsert`, `:transact`,
  or `:join`.
- `AshClickhouse.DataLayer.Types` maps Ash `:map` to ClickHouse
  `Map(String, String)` and `:utc_datetime_usec` to `DateTime64(6)`. There is no
  native JSON column type in the mapping, which is why metadata must be
  stringified rather than stored as a typed map.

See specs/clickhouse-log-handler/spec.md for the required behaviour.

## Goals / Non-Goals

**Goals:**

- Keep `Logger.info/1` cost proportional to formatting only — no network I/O, no
  blocking on buffer state.
- One insert per flush, so ClickHouse sees `INSERT` batches rather than
  per-row HTTP requests.
- Bound memory under sustained overload without ever applying backpressure to a
  process that is trying to log its way out of a problem.
- Keep the failure surface small and classified: a host that loses ClickHouse
  loses logs, not availability.

**Non-Goals:**

- No retries. A log pipeline that queues behind an unreachable database turns
  a downstream outage into an upstream memory leak.
- No query API, no dashboard, no read helpers. This library writes rows; hosts
  query them with their own `Ash.read` / plain SQL.
- No DDL at boot. The library ships the resource; the host owns the migration.
- No redaction of metadata. That is a `:logger` primary filter's job
  (`:logger.add_primary_filter/2`), and doing it here would mean owning a
  redaction policy we cannot guess.
- No per-host custom table name or schema. A second table shape is a second
  code path; if it is needed, the host can define its own resource and use it
  via configuration added later.

## Decisions

### 1. Expose a `:logger` handler, not a `Logger.Backends` backend

`ClickhouseLogger.Handler` implements `@behaviour :logger_handler` with
`log(event, config)`, and is registered through
`config :my_app, :logger, [{:handler, :clickhouse, ClickhouseLogger.Handler, %{...}}]`
followed by `Logger.add_handlers(:my_app)`.

*Why:* `Logger.add_backend/2` is marked deprecated in Elixir 1.20 and its own
docs redirect to the external `:logger_backends` project. Building new work on
an API scheduled for removal buys nothing, and the handler form is what the
Logger docs prescribe for custom handlers.

*Alternative:* `Logger.Backends` callbacks, matching the word "backend"
literally. Rejected — same behaviour, dying API.

*Consequence:* the handler's `log/2` runs **in the process that logged**. This
is why decision 2 is not optional, and why the handler must do no work beyond
formatting.

### 2. Hand events to a `GenServer` with `cast`, never call it

`log/2` normalises the event into a plain map and
`GenServer.cast(buffer, {:entry, row})`. The buffer owns the batch list, the
flush timer, and the counters.

*Why:* a `call` would apply backpressure to every logging process the moment
the buffer is busy — the exact failure this design exists to prevent. `cast`
is fire-and-forget into the buffer's mailbox; the logging process returns
immediately.

*Why not `:logger_backends`:* that project exists precisely because
`:logger_handler` has no built-in overload protection. We get equivalent
protection from `max_buffer_size` (below), which is simpler than routing through
a second gen_event layer.

### 3. Bound the mailbox, not just the batch

The buffer holds at most `max_buffer_size` rows. On overflow it drops the
**oldest** row to admit the newest.

*Why:* for log data, the newest events are the ones that explain a live
incident; the oldest are the ones already superseded by the problem being
investigated. Drop-oldest keeps `discarded` visible and attributable.

*Cost, stated honestly:* `:queue` has no O(1) drop-front. Removing the oldest
entry is `out/1` plus `in/1`, i.e. O(n) in the buffer length. This runs only on
the buffer process, never on a logging caller, and n is bounded by
`max_buffer_size` — so the cost is bounded by configuration, not by load. A
ring buffer would make it amortised O(1) at the price of a custom data structure
that has to get `flush` ordering right by hand. Not worth it at this size.

*Ordering invariant:* rows are appended to a FIFO and flushed front-first, so a
flush always contains a contiguous prefix of the logged sequence, and successive
flushes are ordered. Combined with the `timestamp` `ORDER BY` key, a
`SELECT ... ORDER BY timestamp, id` reproduces the logged order.

### 4. One in-flight flush at a time, executed on a task

The buffer starts a flush only when no flush is in flight. The insert runs in a
`Task` under a supervisor; on completion the buffer updates counters and starts
the next flush if the buffer is non-empty.

*Why:* this preserves the ordering invariant (decision 3) and naturally caps
concurrency at one insert, so a slow ClickHouse does not cause the buffer to
spawn a growing pile of overlapping inserts. It also makes the drop-oldest
policy meaningful: while a flush is stuck, the buffer fills to
`max_buffer_size` and then discards — bounded, visible, and non-blocking.

### 5. `:map` metadata with deterministic scalar rendering

The `metadata` column is a ClickHouse `Map(String, String)` (the only map type
the installed data layer maps to). Values that are already binaries or numbers
pass through; atoms and other scalars render via `to_string/1`; compound terms
(pids, tuples, maps, lists, structs, functions) render via `inspect/1`. Compound
values are prefixed with a marker so a reader can tell an inspected term from a
genuine string.

*Why:* `inspect/1` is deterministic for a given term within a release, is
already the convention for reading Erlang terms, and round-trips through
`Code.eval_string/1` on the Elixir terms `inspect/1` produces. Dropping the
value or `inspect`-ing it without a marker would make `"nil"` and `"nil"` from
a real string indistinguishable.

*Alternative:* a `String` column holding `inspect(metadata)`. Rejected: it
defeats the point of storing logs in a columnar database, because every
metadata query becomes a substring match instead of a map lookup.

### 6. Fixed table, `MergeTree()`, `ORDER BY timestamp`

`ClickhouseLogger.LogEntry` declares `table "logs"`, `engine "MergeTree()"`,
`order_by "timestamp"`. No `partition_by`.

*Why:* the timestamp key is the access pattern for every real log query (a time
range, optionally narrowed by level), and ClickHouse's primary index is built
on the sorting key. `partition_by "toYYYYMM(timestamp)"` is the documented next
step for large tables, but it is a per-table tuning decision with a partition
count trade-off, and it is a one-line DSL change for operators with large
volumes. Guessing it now is speculative.

*Note on the primary key:* `uuid_primary_key` maps to a ClickHouse `UUID`
column, and ClickHouse deduplicates by sorting key, not by primary key in the
relational sense. The UUID is therefore an identifier for cross-referencing, not
a uniqueness constraint — stated in the moduledoc so nobody mistakes it for one.

### 7. Repository (`insert_opts`) owns insert tuning, not the handler

ClickHouse-native insert tuning (`async_insert`, `wait_for_async_insert`,
compression) is declared once on the resource via
`clickhouse do insert_opts [...] end` and applied by `AshClickhouse.DataLayer.Insert`
to every bulk insert.

*Why:* the alternative — threading insert options through `Ash.bulk_create/3`
opts from the handler — puts a ClickHouse concern into a component whose job is
formatting and buffering, and would give the handler a knob for something the
data layer already owns per-resource.

### 8. The handler excludes itself by metadata marker, not by removing itself

On a failed flush the buffer emits `Logger.error("ClickhouseLogger: batch insert
failed: ...", clickhouse_logger_internal: true)`. `log/2` returns immediately
for any event carrying `clickhouse_logger_internal: true`.

*Why:* the obvious alternative — `:logger.remove_handler/1` around the error
report, or `Logger.put_process_level/2` on the buffer process — mutates global
handler state, and re-registration races with a host that adds or removes
handlers concurrently. A metadata check is local, cheap, and cannot race. It
also satisfies the requirement that the failure counter does not increase as a
result of the backend's own report.

### 9. Statistics live on the buffer, read via `GenServer.call`

`ClickhouseLogger.Buffer.stats/1` returns
`%{accepted:, delivered:, discarded:, failed:, buffered:, active:}`.

*Why:* the buffer already owns these numbers; duplicating them into `:telemetry`
or `:persistent_term` adds a second source of truth for state that changes on
every event. Telemetry is a genuine later need (an operator graphing drop rate
over time), and adding it later is additive — emitting an event next to the
counter increment. It is not built now because nothing consumes it yet.

### 10. Writes go through `ClickhouseLogger.Insert`, not `Ash.bulk_create/4`

`ClickhouseLogger.Insert` builds each batch's insert from the data layer's own
public API — `AshClickhouse.DataLayer.qualified_table/1`,
`AshClickhouse.DataLayer.Insert.build_insert_rows/2`,
`AshClickhouse.DataLayer.Insert.insert_statement/2`, and
`AshClickhouse.Repo.insert_rows/3` — and passes only the resource's
`insert_opts`.

*Why:* the design originally specified `Ash.bulk_create!/3`, on the strength of
the documented `:bulk_create` feature. That path does not work against the
installed versions. Two independent upstream defects, both verified:

1. **`Ash.bulk_create/4` always fails.** `DataLayer.bulk_create/4` computes its
   client options with `Insert.insert_opts(resource, opts)`, which
   `Keyword.merge`s Ash's *internal* bulk options (`select:`, `upsert?:`,
   `return_records?:`, `tenant:`, …) into the keyword list handed to
   `ClickHouse.query/4`. That function validates the list and rejects anything
   it does not know, so every bulk create fails with
   `Invalid keyword given … upsert?: ["is not a valid key"]`. The rejection is
   client-side, so no ClickHouse server version avoids it, and no resource-level
   `insert_opts` avoids it either.
2. **`DateTime64(6)` encoding overflows.** `Insert.encode_datetime/2` converts a
   `DateTime` to an integer count of *microseconds*; the JSON input path reads
   that as *seconds*, giving
   `Numeric value is out of range for DateTime64`. Worked around by pre-encoding
   the timestamp as an ISO-8601 UTC string, which ClickHouse parses at full
   microsecond precision.

*Alternative:* hand-rolled `INSERT` SQL. Rejected — it would put the column list
and value encoding in this library instead of the resource, which is the thing
the dependency is for.

*What this keeps:* the resource is still the single source of truth. The
qualified table name, the column list and its order, UUID encoding, map encoding
and the `INSERT … FORMAT JSONCompactEachRow` statement are all generated by the
data layer from `ClickhouseLogger.LogEntry`.

*What this gives up:* Ash's changeset machinery, which is inert for these rows —
`ClickhouseLogger.Event` produces every column from a `:logger` event, the row
shape is fixed, and there is nothing to coerce, validate or merge.

*Reversibility:* the whole workaround is one module. When upstream fixes
`insert_opts/2` and the datetime encoding, `ClickhouseLogger.Insert` collapses
to `Ash.bulk_create/4` with no behavioural change. That is why it is isolated
rather than inlined into `ClickhouseLogger.Buffer`.

## Risks / Trade-offs

- **[Host app crashes on boot because `ClickhouseLogger.Repo` is not supervised]** → Document the required child order (`ClickhouseLogger.Repo` before anything that logs). A failed flush is already handled as a normal failure; an unstarted repo just makes every early flush fail, and the `failed` counter says so.

- **`mix ash_clickhouse.migrate` in a host app does not create `logs`]** → `Mix.Tasks.AshClickhouse.Helpers.find_resources/0` enumerates modules of the *current* Mix project, so a resource owned by a dependency is not in that set. Plan for this in the Migration Plan below: ship a migration file under this library's `priv/` and have the host run it. Do not paper over it by creating the table at boot.

- **ClickHouse is down and `discarded` climbs silently** → `stats/1` exposes the counters, and each failed flush logs one error (rate-limited to one per flush, not one per row) so the drop is visible in whatever console/file handler the host still has.

- **Ordering across two hosts writing to the same table** → Rows are ordered by `(timestamp, id)`, not by a global sequence. Two nodes' events interleave by wall-clock timestamp. The spec's ordering guarantee is per-process-of-origin, which is what any clock-based system can honestly promise.

- **The `Ash.bulk_create/4` workaround has to be revisited when the dependency is upgraded** → Pinned to `ash_clickhouse ~> 0.7`. The workaround is isolated in `ClickhouseLogger.Insert` and its module doc names both defects, so an upgrade is a single-place review. Task 7.1 documents this for users too.

- **Ash dependency weight** → Adopting `ash` + `ash_clickhouse` + `clickhouse` for logging is a large dependency tree. Accepted deliberately: the user asked for an Ash-backed logger, and the alternative is hand-rolled ClickHouse SQL that gives up the declarative resource API the request was for.

- **`:utc_datetime_usec` decoding round-trip** → `DateTime64(6)` is microsecond precision while `:utc_datetime_usec` is microsecond precision, so no precision is lost. Microsecond collisions between two events in the same microsecond are possible; the `id` tiebreaker in the ordering key handles them.

## Migration Plan

The host application runs the migration; the library never does, and never at
boot.

Expected host setup:

```elixir
# mix.exs
{:clickhouse_logger, "~> 0.1.0"}

# config/runtime.exs
config :clickhouse_logger, ClickhouseLogger.Repo,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  username: System.get_env("CLICKHOUSE_USER", "default"),
  password: System.get_env("CLICKHOUSE_PASSWORD", ""),
  database: "my_app"

config :my_app, :logger, [
  {:handler, :clickhouse, ClickhouseLogger.Handler,
   %{batch_size: 500, flush_interval_ms: 1_000, max_buffer_size: 10_000}}
]
```

Then, in the host's supervision tree: `ClickhouseLogger.Repo`, then
`Logger.add_handlers(:my_app)`.

**Rollout order matters:** run the migration *before* adding the handler. The
handler is safe to install before the table exists (flushes fail and are
counted), but the failure log is noise an operator has to learn to ignore.

**Table creation.** Because resource discovery is scoped to the current Mix
project, `mix ash_clickhouse.migrate` will probably not reach
`ClickhouseLogger.LogEntry` from a host app. The implementation will:

1. Verify discovery empirically before choosing (first task).
2. If it is not discovered, this library ships its own migration file under its
   `priv/` and a `mix clickhouse_logger.migrate` task that calls
   `AshClickhouse.MigrationRunner.migrate/2` with that path and
   `ClickhouseLogger.Repo`. The DDL itself is still generated by
   `AshClickhouse.Migration.create_table_cql/1` from the resource, so the
   library never hand-writes schema.

Either way the host's upgrade path is one command, and rollback is
`DROP TABLE logs` — ClickHouse has no transactional migration semantics to
reconcile.

## Open Questions

- Whether `:logger`'s `filter_default` should be `:log` or `:ignore` for this
  handler by default. `:log` is the correct default (it forwards events to the
  handler rather than consuming them), and is almost certainly what we want,
  but it is worth confirming against a real handler configuration before
  considering it settled.