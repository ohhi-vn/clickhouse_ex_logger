# Tasks

## 1. Reuse a running repo connection in `Migration.setup/1`

- [x] 1.1 In `ClickhouseExLogger.Migration.start_repo_connection/0`, return `:ok` when `AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo)` returns a connection whose `pid` is alive, and start the connection as today otherwise. Verify `mix test test/clickhouse_ex_logger/migration_test.exs test/clickhouse_ex_logger/migrate_task_test.exs` still passes — those tests stop the shared connection first, so they must keep taking the start path.
- [x] 1.2 Add a case to `test/clickhouse_ex_logger/migration_test.exs` that calls `Migration.setup/1` while the repo connection is already running, and assert it returns `{:ok, summary}` rather than raising `ArgumentError: table name already exists`, and that `schema_migrations` is unchanged on a second run.

## 2. `ClickhouseExLogger.Utils.migrate/1`

- [x] 2.1 Create `lib/clickhouse_ex_logger/utils.ex` with a `@moduledoc` showing `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"`, and `migrate/1` taking `keyword()` (forwarding `:dry_run`) that calls `Code.ensure_loaded!(ClickhouseExLogger.Repo)`, delegates to `ClickhouseExLogger.Migration.setup/1`, logs the applied/skipped summary through `Logger.info/1` on success and the failure reason through `Logger.error/1` on `{:error, reason}`, and returns `{:ok, summary}` or `{:error, reason}` unchanged. Verify it compiles with no warnings and touches no `Mix` API.
- [x] 2.2 Make `migrate/1` stop the repo connection in an `after` block only when no connection was registered before the call, so a host-supervised `ClickhouseExLogger.Repo` is left running. Verify with a test that starts the connection, calls `migrate/1`, and asserts `AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo)` is still alive afterwards.
- [x] 2.3 Add `test/clickhouse_ex_logger/utils_test.exs` (following `ClickhouseExLogger.Case`, synchronous as `migration_test.exs` is) asserting: `migrate()` against the container-provisioned ClickHouse returns `{:ok, summary}` with the `logs` table present, reports nothing applied on a second call, and `migrate(dry_run: true)` leaves `schema_migrations` unchanged. Verify `mix test test/clickhouse_ex_logger/utils_test.exs` passes.

## 3. Documentation

- [x] 3.1 Update README setup step 2: keep `mix clickhouse_ex_logger.migrate` primary, add the `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"` alternative with a one-line note on when to use which, and add a note that it must run before the new version starts logging. Verify by re-reading the section for the two `> **Upgrading...**` callouts and confirming the release command appears in the upgrade one too.
- [x] 3.2 Add a paragraph to `Mix.Tasks.ClickhouseExLogger.Migrate`'s moduledoc pointing at the release path, and update `ClickhouseExLogger.Migration`'s "One call per VM" and "Nothing here runs at application boot" sections to state that `setup/1` now reuses a running connection and that the host-facing entry point is `ClickhouseExLogger.Utils.migrate/1`. Verify `mix docs` builds with no warnings.

## 4. Verification

- [x] 4.1 Run `mix format --check-formatted` and `mix test --cover`, and confirm `lib/` still meets the 90% line-coverage gate with `ClickhouseExLogger.Utils` included in the report rather than in `ignore_modules`.
- [x] 4.2 Run `mix hex.build` and confirm both `priv/repo/migrations/*.exs` files are in the printed manifest, so the release path resolves the same files the Mix task does. No change to `mix.exs` is expected; if either file is missing, add it and note why in the change's tasks before proceeding.
- [x] 4.3 Add a `CHANGELOG.md` entry under the unreleased section recording the new release entry point and the README update.