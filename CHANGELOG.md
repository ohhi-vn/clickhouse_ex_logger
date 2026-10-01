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

### Changed

- `ClickhouseExLogger.Migration.setup/1` reuses an already-running
  `ClickhouseExLogger.Repo` connection instead of starting a second one. Previously
  it started one unconditionally, which raised `ArgumentError: table name already
  exists` when the connection was already up — the state every release is in when
  the host supervises the repo.

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
  `capture_node: false` at registration turns the capture off without a schema
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
