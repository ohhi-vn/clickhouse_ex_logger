# Proposal

## Why

`mix clickhouse_ex_logger.migrate` is the only supported way to create the schema,
and a Mix task is unavailable in a release: a production host has no Mix, no
`mix.exs`, and no dependency tree to resolve against. Such a host can therefore
never satisfy the library's own documented first step, so its options are to
ship a build with Mix or to skip the step and silently log into nothing.

## What Changes

- Add `ClickhouseExLogger.Utils.migrate/1`, a Mix-free function that creates the
  database and applies pending migrations, callable from a release's `eval` or
  `rpc` before the new version starts logging.
- Document the release path in the README alongside the existing Mix task, in the
  setup step and in the upgrade note, and in the module documentation of the
  migration function and the Mix task so the two entry points are discoverable
  from either side.
- Verify, rather than change, that the migration files are present in the
  published package: the package manifest already ships `priv/repo/migrations`,
  confirmed by building the package and by `test/mix_project_test.exs`. This
  change adds no new requirement there, and extends that test only if the release
  path turns out to need a shipped file that is not yet covered.

No breaking change. `mix clickhouse_ex_logger.migrate` keeps its name, behaviour
and contract; the release entry point is additive and delegates to the same
`ClickhouseExLogger.Migration.setup/1`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `clickhouse-log-handler`: the ClickHouse table contract requirement states the
  migration command is the only supported way for a host to create the schema.
  That is currently satisfiable only with Mix, so the requirement gains a
  Mix-free entry point as an equally supported way to run the same operation,
  with the same idempotence and error reporting. The published-package-contents
  requirement already covers the shipped migration files; it is unchanged.

## Impact

- New module `ClickhouseExLogger.Utils` in `lib/clickhouse_ex_logger/utils.ex`,
  delegating to `ClickhouseExLogger.Migration.setup/1`.
- `README.md`, `lib/clickhouse_ex_logger/migration.ex`, and
  `lib/mix/tasks/clickhouse_ex_logger.migrate.ex` documentation.
- New tests in `test/clickhouse_ex_logger/` for the release entry point against
  the container-provisioned ClickHouse, following the existing migration tests.
- No new dependencies, no change to `mix.exs` packaging, no schema change.