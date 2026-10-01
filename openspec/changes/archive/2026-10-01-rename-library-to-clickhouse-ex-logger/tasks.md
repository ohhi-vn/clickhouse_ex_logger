# Tasks

## 1. Rename the library source

- [x] 1.1 `git mv lib/clickhouse_logger lib/clickhouse_ex_logger` and `git mv lib/clickhouse_logger.ex lib/clickhouse_ex_logger.ex`; verify both old paths are gone and the new tree holds all nine modules
- [x] 1.2 Rename every `defmodule ClickhouseLogger…` to `ClickhouseExLogger…` across `lib/clickhouse_ex_logger.ex` and `lib/clickhouse_ex_logger/*.ex`, including bare `ClickhouseLogger` in the top-level module; verify `grep -rn "defmodule ClickhouseLogger" lib/` returns nothing
- [x] 1.3 Update `lib/clickhouse_ex_logger/repo.ex` so `use AshClickhouse.Repo, otp_app: :clickhouse_ex_logger` and the `@moduledoc` config example use the new application and module names; verify the `otp_app:` argument is `:clickhouse_ex_logger`
- [x] 1.4 Update `lib/clickhouse_ex_logger/migration.ex`: the `@bootstrap_name` module reference, and the `:code.priv_dir(:clickhouse_ex_logger)` lookup in `migrations_path/0`; verify no `:code.priv_dir(:clickhouse_logger)` remains, since the wrong atom silently falls back to a cwd-relative path
- [x] 1.5 Update all remaining intra-`lib` references — `handler.ex` (aliases, `@moduledoc` install/uninstall examples, the `ClickhouseLogger:` log prefixes), `buffer.ex`, `event.ex`, `insert.ex`, `domain.ex`, `log_entry.ex` — including every doc comment; verify `grep -rn "ClickhouseLogger" lib/` returns nothing
- [x] 1.6 Rename the internal marker metadata key `:clickhouse_logger_internal` to `:clickhouse_ex_logger_internal` in `handler.ex`, `buffer.ex`, and its reader in `event.ex` (`fetch_meta(event, :clickhouse_logger_internal)`); verify the writer and reader agree, so internal failure reports are still excluded from becoming rows

## 2. Rename the Mix task

- [x] 2.1 `git mv lib/mix/tasks/clickhouse_logger.migrate.ex lib/mix/tasks/clickhouse_ex_logger.migrate.ex` and rename its module to `Mix.Tasks.ClickhouseExLogger.Migrate`; verify the filename and module name agree, since Mix derives the task name from the path
- [x] 2.2 Update the task's `@moduledoc`, `@shortdoc`, and shell output — including the `mix clickhouse_ex_logger.migrate` invocations and the `config :clickhouse_ex_logger, ClickhouseExLogger.Repo` hint in the error message; verify `mix help clickhouse_ex_logger.migrate` resolves and `mix help clickhouse_logger.migrate` reports no such task

## 3. Rename the migration identity without touching its version

- [x] 3.1 Rename `ClickhouseLogger.Migrations.CreateLogsTable` to `ClickhouseExLogger.Migrations.CreateLogsTable` in `priv/repo/migrations/20260101000000_create_logs.exs`, leaving the migration **filename** unchanged; verify the filename still matches the version
- [x] 3.2 Confirm `@version "20260101000000"` is byte-identical to before the rename and that `repo/0` and `change/0` reference the renamed module; verify by asserting the version string literally — the container suite cannot catch a version bump, because its `schema_migrations` table starts empty
- [x] 3.3 Verify against a database that already has the table that the migration is skipped, not re-applied: create a scratch database, run `mix clickhouse_ex_logger.migrate` twice, and confirm the second run reports it up to date and issues no `CREATE TABLE`

## 4. Make a missing configuration a diagnosable failure

- [x] 4.1 Override `config/0` in `lib/clickhouse_ex_logger/repo.ex` to raise `AshClickhouse.Error.ConfigurationError` when `Application.get_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo)` is absent, naming both the application and the module; verify the message names `:clickhouse_ex_logger` and `ClickhouseExLogger.Repo`, since `AshClickhouse.Repo.config_to_conn_opts/1` would otherwise default to `http://localhost:8123` and write to an unintended database
- [x] 4.2 Add a test in `test/clickhouse_ex_logger/` using plain `ExUnit.Case` and no `ClickhouseExLogger.Case`, so it needs no database, deleting the env in `setup` and restoring it in `on_exit`. **Written as `async: false`, not `async: true` as originally planned:** `ClickhouseExLogger.TestServer.repo_config/0` reads the same key through `Application.fetch_env!/2`, which raises when it is absent, and `ClickhouseExLogger.TestServerTest` is `async: true` and calls it — so an async module deleting the key would race it. The engine-free goal is met by not using `ClickhouseExLogger.Case`, which is what raises without a database. Reason is recorded in the test's `@moduledoc`
- [x] 4.3 In the same test, assert that a value which is not a keyword list also raises, covering the renamed key configured with `nil` or a map; verify both cases raise with the configuration error

## 5. Rename application and test configuration

- [x] 5.1 Update `config/config.exs`: `config :clickhouse_ex_logger, ClickhouseExLogger.Repo`, the `ash_domains` key, and the development database name `clickhouse_logger_dev` → `clickhouse_ex_logger_dev`; verify no `config :clickhouse_logger` remains
- [x] 5.2 Update `config/test.exs` the same way for the test database name and every comment referencing the renamed modules; verify the `CONTAINER_ENGINE_HOST` discovery block is untouched and still runs before `:testcontainer_ex` boots

## 6. Rename the test suite

- [x] 6.1 Rename the test support modules — `Case`, `TestContainer`, `TestServer`, `CaptureHandler` — to the `ClickhouseExLogger` namespace, including the `String.to_atom("clickhouse_logger_capture_…")` handler-id prefix; verify no support module keeps the old namespace, since `use ClickhouseExLogger.Case` is what tags `:clickhouse`
- [x] 6.2 Update `test/support/test_container.ex`: the `@database` attribute to `clickhouse_ex_logger_test` and the doc references; verify the container image and version pins are unchanged
- [x] 6.3 Update `test/test_helper.exs`: the `Application.put_env` call and the `ClickhouseLogger.Migration.setup()` call to the renamed application and module; verify the suite still provisions the schema through the same path a host uses
- [x] 6.4 `git mv test/clickhouse_logger test/clickhouse_ex_logger` and `git mv test/clickhouse_logger_test.exs test/clickhouse_ex_logger_test.exs`; verify both old paths are gone
- [x] 6.5 Rename every test module and reference inside `test/` to the new namespace; verify `grep -rn "ClickhouseLogger\|clickhouse_logger" test/` returns nothing
- [x] 6.6 Update `test/clickhouse_ex_logger/readme_test.exs` to assert against the renamed modules, the renamed Mix task, and the renamed defaults, including the documented-API-existence and documented-column-list checks; verify it still covers the README's snippets

## 7. Update package metadata and documentation

- [x] 7.1 Update `mix.exs`: `app: :clickhouse_ex_logger`, the package description, and confirm `files:` still covers the renamed paths; verify `mix compile` produces `clickhouse_ex_logger.app`
- [x] 7.2 Rewrite `README.md` for the new name — dependency declaration, the `config :clickhouse_ex_logger, ClickhouseExLogger.Repo` example, the supervision-tree example, `mix clickhouse_ex_logger.migrate` (including the `--dry-run` and "use this, not `mix ash_clickhouse.migrate`" notes), the declarative-registration example, the `ClickhouseLogger.Buffer.stats()` output block, the `ash_clickhouse` workaround section, and the test-container commands; verify no `clickhouse_logger` remains in the file
- [x] 7.3 Update `.gitignore`'s `clickhouse_logger-*.tar` entry to `clickhouse_ex_logger-*.tar`; verify the pattern matches the renamed package's tarball

## 8. Verify

- [x] 8.1 Run `mix format --check-formatted` and fix any formatting drift introduced by the rename; verify it exits clean
- [x] 8.2 Run `mix compile --warnings-as-errors` in both `:dev` and `:test` and fix every warning, including unused aliases left behind by the rename; verify both exit clean. Note that one pre-existing warning remains in the test tree — an unused `stats` binding at `buffer_failure_test.exs:153`, present in the working tree before this change and out of scope per the design's non-goals
- [x] 8.3 Run the full containerised `mix test` against a real ClickHouse; verify all modules pass, in particular `integration_test.exs`, `resource_test.exs`, `workload_test.exs`, `no_schema_at_boot_test.exs`, and the four database-free modules
- [x] 8.4 Run `mix test test/clickhouse_ex_logger/repo_config_test.exs` and verify the configuration check is covered without a database: the test touches only the application environment, with no `ClickhouseExLogger.Case`, no `TestServer`, no `Repo.query/3` and no `insert_rows/3`. **Note:** the literal reading — running with no container *engine* — is not satisfiable and was not attempted. `test/test_helper.exs` calls `ClickhouseExLogger.TestContainer.start/0` unconditionally, so no test in this suite runs without an engine. That is pre-existing, introduced by the uncommitted containerized-tests work, not by this change
- [x] 8.5 Run `grep -rn "clickhouse_logger\|ClickhouseLogger" .` excluding `deps/`, `_build/`, `.git/`, and `erl_crash.dump`; verify the only remaining hits are the historical references in `openspec/changes/archive/` and this change's own artifacts
- [x] 8.6 Smoke-test the host path end to end: verify `mix clickhouse_ex_logger.migrate --dry-run` reports without changing anything, and that a fresh `iex -S mix` can load every `ClickhouseExLogger` module named in the README

## 9. Rename the project directory — DROPPED, not done

**Dropped by user decision during apply.** The package is published as
`clickhouse_ex_logger` regardless: the hex name comes from `app:` in `mix.exs`
(task 7.1), not from the folder, and `package.files` is `~w(lib .formatter.exs
mix.exs README.md LICENSE)`, which names no directory.

The rename was dropped because live tooling holds the old absolute path — the
editor's `dexter` formatter daemon is running with
`/…/clickhouse_logger` and `/…/clickhouse_logger/.formatter.exs` in its argv, and
the `.expert` indexer holds `.expert/expert.log` open. Moving the directory would
have broken `mix format` from the editor until it was restarted.

To do it later, when the editor is closed:

```sh
cd .. && mv clickhouse_logger clickhouse_ex_logger
cd clickhouse_ex_logger && mix test
```