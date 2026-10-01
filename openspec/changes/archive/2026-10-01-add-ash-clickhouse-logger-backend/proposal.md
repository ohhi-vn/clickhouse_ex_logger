# Proposal

## Why

Elixir applications that need queryable, high-volume log analytics outgrow
file-based logging, but the ecosystem's ClickHouse clients speak raw HTTP or SQL
and hand every caller a blocking connection. This library ships a `:logger`
handler that persists log events into ClickHouse through Ash + AshClickhouse, so
apps get a declarative resource API and a table they can actually `SELECT`
against, without every `Logger.info/1` call paying a network round trip.

## What Changes

- Add `ClickhouseLogger.Handler`, a module implementing the `:logger_handler`
  behaviour, and a supervised buffer process that batches events and writes each
  batch as one insert through `ClickhouseLogger.Insert`.
- Add `ClickhouseLogger.Insert`, which builds that insert from the data layer's
  own public API. This exists because `Ash.bulk_create/4` cannot work against
  `ash_clickhouse` 0.7.3 — see design.md, decision 10.
- Ship the Ash data layer the library owns: `ClickhouseLogger.Repo`,
  `ClickhouseLogger.Domain`, and `ClickhouseLogger.LogEntry` — an append-oriented
  `MergeTree` resource with a fixed `logs` table and columns for timestamp,
  level, message, source location, and string-valued metadata.
- Add connection configuration under `config :clickhouse_logger,
  ClickhouseLogger.Repo` (`url`, `username`, `password`, `database`) matching
  `AshClickhouse.Repo`.
- Add batching and overload configuration: `batch_size`, `flush_interval_ms`,
  and `max_buffer_size`.
- Guarantee the handler never raises into the calling process and never blocks:
  `log/2` formats and casts, the buffer drops oldest entries past
  `max_buffer_size`, and insert failures are reported once per flush without
  recursing back into the handler.
- Document setup in `README.md`: add the dependency, configure the repo, run
  `mix ash_clickhouse.setup` and `mix ash_clickhouse.migrate`, and register the
  handler through `config :my_app, :logger` plus `Logger.add_handlers/1`.
- Remove the scaffold `ClickhouseLogger.hello/0` and its doctest.

## Capabilities

### New Capabilities
- `clickhouse-log-handler`: Shipping Elixir `Logger` events into ClickHouse —
  handler registration and configuration, event-to-row mapping, buffered
  batched delivery, overload and failure behaviour, and the ClickHouse table
  contract the rows are written to.

### Modified Capabilities

None. This is the first capability in the project.

## Impact

- **Dependencies added:** `ash`, `ash_clickhouse`, and `clickhouse` (transitive
  via `ash_clickhouse`). All three are host applications' runtime
  dependencies now, which is the main cost of this change — Ash is a large
  dependency tree to adopt purely for logging.
- **New runtime processes:** `ClickhouseLogger.Repo` (must be in the host's
  supervision tree) and the buffer process (started by
  `ClickhouseLogger.Buffer`, started via `:logger.add_handler/4` or a child
  spec the host opts into).
- **Startup ordering:** the repo must start before the first flush, or early
  events are dropped. Ordering is documented, not enforced by us.
- **New table:** `logs` in the configured ClickHouse database, created by the
  host's `mix ash_clickhouse.migrate`. We do not own production DDL — a
  library must not create tables behind a host's back at boot.
- **No breaking public API:** the package is unreleased, so `hello/0`'s removal
  is not a breaking change for any consumer.
- **The write path bypasses `Ash.bulk_create/4`** because that function is
  broken upstream in 0.7.3. The resource remains the single source of truth for
  the table, columns and value encoding. See design.md, decision 10.
- **Migration discovery is unverified:** `mix ash_clickhouse.migrate` enumerates
  resources by scanning the *current* app's compiled modules, so it likely will
  not reach `ClickhouseLogger.LogEntry` from a host app. This is resolved
  during implementation — see design.md, Migration Plan.