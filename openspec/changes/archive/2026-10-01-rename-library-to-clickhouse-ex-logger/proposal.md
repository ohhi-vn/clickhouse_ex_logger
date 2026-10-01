# Proposal

## Why

The library is published as `clickhouse_logger`, but the Elixir ecosystem already
has a well-known `Logger` package by that name, so the hex package name reads as
generic and invites confusion with unrelated tooling. Renaming to
`clickhouse_ex_logger` names the library after what it actually is — an Elixir
`Logger` backend — and matches the `*_ex` convention used by other Elixir-native
libraries.

The library is at `0.1.0` and has not been released, so the rename can be a clean
break. There is no installed base to keep working, and no compatibility shims are
worth their permanent maintenance cost.

## What Changes

- **BREAKING** — Rename the OTP application from `:clickhouse_logger` to
  `:clickhouse_ex_logger`. This changes the dependency name hosts declare, the
  `config :clickhouse_ex_logger, ClickhouseExLogger.Repo` key, and the
  `:code.priv_dir/1` lookup used to locate shipped migrations.
- **BREAKING** — Rename the top-level module namespace from `ClickhouseLogger` to
  `ClickhouseExLogger`, covering `ClickhouseLogger`, `.Handler`, `.Buffer`,
  `.Event`, `.Insert`, `.LogEntry`, `.Repo`, `.Domain`, `.Migration`, and the test
  support modules `.Case`, `.TestContainer`, `.TestServer`, `.CaptureHandler`.
- **BREAKING** — Rename the Mix task from `mix clickhouse_logger.migrate` to
  `mix clickhouse_ex_logger.migrate` (`Mix.Tasks.ClickhouseExLogger.Migrate`).
- **BREAKING** — Rename the internal log-marker metadata key from
  `:clickhouse_logger_internal` to `:clickhouse_ex_logger_internal`, so the
  handler's own failure reports are still excluded from becoming rows.
- Rename the project directory to `clickhouse_ex_logger`, so the package name
  matches the directory name. **Dropped during apply** — the published package
  name comes from `app:` in `mix.exs`, not the folder, and live editor tooling
  holds the old absolute path. Deferred to the user, who may move it later with
  the editor closed; nothing in this change depends on it.
- Rename the dev and test ClickHouse databases from `clickhouse_logger_dev` and
  `clickhouse_logger_test` to `clickhouse_ex_logger_dev` and
  `clickhouse_ex_logger_test`.
- Update `README.md`, `mix.exs`, `.gitignore`, and every in-source doc reference.

Behaviour is unchanged. No requirement in `clickhouse-log-handler` changes what
the system does; only the names a host writes in its config and calls at its
terminal change. The delta therefore records the new identity as a requirement
rather than restating the existing ones.

One identity detail is load-bearing and is called out explicitly: the migration
module is renamed, but its `@version` string stays `20260101000000`.
`AshClickhouse.MigrationRunner` tracks applied migrations by version in
ClickHouse's `schema_migrations` table, not by module name, so an existing
database reports the migration as already applied and the renamed module does not
re-run `CREATE TABLE`.

## Capabilities

### New Capabilities

None. The library's capability surface is unchanged; this change renames it.

### Modified Capabilities

- `clickhouse-log-handler`: Add a requirement fixing the library's published
  identity — OTP application name, module namespace, configuration key, Mix task
  name, and migration-version stability — so a future accidental rename, a
  host's stale configuration, or a re-run migration against an existing database
  is a detectable deviation rather than a silent one.

## Impact

**Code.** Every module in `lib/` and `test/` (9 library modules, 4 test support
modules, 12 test modules), plus `lib/clickhouse_logger.ex` and the
`lib/clickhouse_logger/` directory tree.

**Paths.** `lib/clickhouse_logger/` → `lib/clickhouse_ex_logger/`,
`lib/clickhouse_logger.ex` → `lib/clickhouse_ex_logger.ex`,
`lib/mix/tasks/clickhouse_logger.migrate.ex` →
`lib/mix/tasks/clickhouse_ex_logger.migrate.ex`,
`test/clickhouse_logger/` → `test/clickhouse_ex_logger/`.

**Host-facing surface.** `config :clickhouse_ex_logger, ClickhouseExLogger.Repo`,
`ClickhouseExLogger.Repo` and `ClickhouseExLogger.Handler` in a supervision tree,
`mix clickhouse_ex_logger.migrate`, and `ClickhouseExLogger.Buffer.stats/1`.

**Data.** No schema change. The `logs` table, its columns, its engine, and the
`schema_migrations` version `20260101000000` are all preserved. The dev and test
database names change, so an existing local `clickhouse_logger_dev` database is
orphaned rather than migrated — it holds no data worth keeping.

**Not affected.** Dependencies (`ash`, `ash_clickhouse`, `clickhouse`,
`testcontainer_ex`), the handler's batching and failure behaviour, the `logs` row
shape, and the counter reconciliation invariant.

**Tests.** The suite is the primary verification mechanism here: it references
the old names in roughly 40 places across test modules and support code, so the
rename is only complete when the full suite compiles and passes against a real
ClickHouse container.