# Changelog

All notable changes to `clickhouse_ex_logger` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the
major version is `0`, a breaking change increments the minor version.

## Unreleased

### Added

- `ClickhouseExLogger.Utils.migrate/1`, the migration entry point for a release:
  `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"`. It applies the same
  migrations as `mix clickhouse_ex_logger.migrate` and reads the same connection
  configuration, so a host without Mix can still create the schema. A live
  `ClickhouseExLogger.Repo` connection is reused rather than duplicated, and left
  running; one started by the call itself is cleaned up afterwards. Accepts
  `dry_run: true`, and reports through `Logger` since `Mix.shell/0` is unavailable
  in a release.

### Fixed

- The buffer no longer stops writing silently and permanently when a write dies
  without reporting an outcome. `spawn_monitor/1` was reporting that through the
  wrong reference — the monitor's, which the buffer discarded, rather than the
  correlation ref it kept — so the `:DOWN` never matched the write it belonged to,
  the in-flight reference was never cleared, and every later event parked in the
  buffer forever while `stats/1` kept reporting `active?: true`. Reachable in
  production: `clickhouse` 0.32.0 raises from inside a query for some responses,
  and those raises escape `AshClickhouse.Connection`'s rescue list. The abandoned
  batch is now counted as `lost`, the failure is reported once, and delivery
  continues.
- `accepted == delivered + discarded + lost` now holds for a batch lost to a
  crashed write. Those rows were previously counted nowhere.
- An unrecognised result from the insert path is now treated as a failed flush
  rather than crashing the buffer. `Buffer.tally/2` matched exactly two shapes, so
  anything else raised inside the only process that writes logs and discarded
  everything buffered behind it without counting a row.
- `ClickhouseExLogger.Handler.install/2` no longer leaves a running buffer behind
  when registration fails. A buffer it did not start is stopped again; one that was
  already running is left alone. Previously any registration failure — including one
  only `:logger` could detect — left a `start_link`ed buffer with no handler
  attached to it.
- A failed write is reported with the server's or the client's own message rather
  than an inspection of an internal error struct.
- A `:file` value that cannot be rendered — an invalid code point, a list that is
  not well-formed — is now rendered instead of raising, which `row/2` promises it
  will not do.
- User metadata is now read from an event on either shape, and the marker that
  stops the handler feeding itself into its own table is recognised on either
  shape. A flat event previously produced an empty metadata map.
- A source location with no module now records no value instead of the string
  `"nil"`, so `WHERE module IS NULL` finds those rows.
- Both migration entry points now report a database name the server would reject as
  a failure naming that option, rather than raising out of `setup/1`.
- The README now states the `ash_domains` configuration line that silences Ash's
  domain-inclusion warning. It has to be set in the host's own configuration: Mix
  evaluates only the current project's `config/`, so a dependency's is never read.

### Changed

- **Breaking:** `ClickhouseExLogger.Handler.ensure_buffer_started/1` now returns
  `{:ok, started?}` instead of `:ok`, where `started?` is `true` when *that call*
  started the buffer. `install/2` needs it to undo only its own effect if
  registration then fails, and cannot recover it afterwards from
  `GenServer.whereis/1` — by then a buffer it started is indistinguishable from one
  that was already running. A caller matching on `:ok` needs `{:ok, _}`. Per this
  project's versioning note, a breaking change at major `0` increments the minor
  version, so the next release is `0.2.0`.
- Shutdown no longer runs two inserts at once. `Buffer.terminate/2` used to write
  whatever was still queued even while a write was in flight, starting a second
  insert alongside it and breaking the ordering guarantee the rest of the buffer is
  built on. It now waits, within the same bounded budget, for the write already
  under way and writes nothing itself. **Trade-off:** rows still queued behind that
  write are no longer written at shutdown. They are lost rather than double-written,
  which is the trade the ordering invariant requires; every other shutdown path
  still makes its final bounded attempt.
- `ClickhouseExLogger.Insert.insert/1`'s `@spec` and `@doc` no longer advertise a
  two-element `{:error, message}` shape. It was never returned, and
  `ClickhouseExLogger.Buffer` tallies a result against exactly two shapes — a
  result it had no clause for would raise inside the only process that writes logs.
  `committed` is now documented as always present, including on failure.
- `ClickhouseExLogger.Migration.setup/1` reuses an already-running
  `ClickhouseExLogger.Repo` connection instead of starting a second one. Previously
  it started one unconditionally, which raised `ArgumentError: table name already
  exists` when the connection was already up — the state every release is in when
  the host supervises the repo.
- `ClickhouseExLogger.Event.row/2` renders an absent module as no value rather than
  a string. Rows written by 0.1.0 with a `nil` module contain `"nil"` and are not
  matched by `WHERE module IS NULL`; re-writing those rows is the only way to
  correct them.
- **Registration now rejects two configurations it previously accepted.** Both fail
  at `install/2` with an error naming the option, which is where every other
  invalid option already failed:
  - `:batch_size` greater than `:max_buffer_size`. The buffer is capped at
    `:max_buffer_size`, so the batch trigger could never fire and rows past the cap
    were discarded for a reason unrelated to ClickHouse — indistinguishable, in the
    `discarded` count, from the database being too slow. Set the two equal for the
    smallest batch the buffer can write.
  - A `:level` that is not one of `:all`, `:debug`, `:info`, `:notice`, `:warning`,
    `:error`, `:critical`, `:alert`, `:emergency`.

- `ClickhouseExLogger.Buffer.stats/1` reports `active?: true` with zeroed counters
  for a buffer that exists but did not answer in time, rather than `active?: false`.
  Zeroed counters marked inactive were indistinguishable from a system that never
  started.
- `ClickhouseExLogger.Handler`'s `:buffer` option is documented as accepting a pid.
  It has only ever matched a pid — a registered name was silently ignored — but the
  documentation previously implied a name worked.
- `ClickhouseExLogger.LogEntry`'s documentation now states the table's sorting key
  as `timestamp`, which is what `order_by` generates, rather than `(timestamp, id)`.
  `id` is not part of the sorting key; use `(timestamp, id)` when you want the order
  the buffer guarantees delivery in.

## 0.1.0

First release.

### Added

- `ClickhouseExLogger.Handler`, a `:logger` handler that delivers log events to
  ClickHouse in buffered batches. Registration is explicit and returns after
  validating its options, so the process that attaches it performs no network work.
- Batching configuration: minimum level, batch size, flush interval, and maximum
  buffer size, each with a documented default. An option that is present but not a
  positive integer fails registration with an error naming that option, rather than
  failing later during delivery.
- Every accepted event is recorded with its timestamp, level, message, source
  location, node name, and metadata. Metadata values that are not strings are
  rendered rather than dropped, and a message that is not renderable is stored in
  its inspected form instead of raising.
- The `node` column, recording the full node name including the host part.
  `include_node: false` at registration turns the capture off without a schema
  change. Reading the node name adds no wait to the logging call and cannot fail it.
- Backpressure under load: the buffer is bounded by the configured maximum, and at
  capacity the oldest event is discarded rather than blocking the caller or growing
  without bound.
- `ClickhouseExLogger.Buffer.stats/0`, reporting accepted, delivered, discarded,
  lost, and failed counts plus whether the handler is active. The counts reconcile
  exactly: every accepted event lands in exactly one of delivered, discarded, or
  lost.
- Failure handling: a failed flush reports once through the standard logger and is
  never retried indefinitely. The handler does not feed its own error reports back
  into itself.
- `mix clickhouse_ex_logger.migrate`, which creates the database and the `logs`
  table. It targets this library's own Ash resource explicitly, because
  `mix ash_clickhouse.migrate` discovers resources by listing the current project's
  modules and therefore never sees a resource owned by a dependency. Re-run it on
  every deploy: a column added by a later version cannot come from a migration that
  has already been recorded as applied.
- The `logs` table, an append-only time-series table ordered by timestamp so
  time-range queries prune parts efficiently.
- `ClickhouseExLogger.Repo`, configured under the `:clickhouse_ex_logger`
  application environment, so `config :clickhouse_ex_logger,
  ClickhouseExLogger.Repo` is the single place a host states its connection.

### Notes

- Pins `ash_clickhouse ~> 0.7`. In 0.7.3, `Ash.bulk_create/4` cannot write to
  ClickHouse — it leaks Ash's internal bulk options into the client option list,
  which the client rejects, and its `DateTime64` encoding overflows.
  `ClickhouseExLogger.Insert` works around both using the data layer's own public
  building blocks, so the resource stays the single source of truth for the table
  and its encoding.
