# Tasks

## 1. Silence the Ash domain-inclusion warning in the library's own definitions

- [x] 1.1 Add `validate_config_inclusion?: false` to `use Ash.Domain` in `lib/clickhouse_ex_logger/domain.ex` and `validate_domain_inclusion?: false` to `use Ash.Resource` in `lib/clickhouse_ex_logger/log_entry.ex`. Verify `mix compile --warnings-as-errors` is clean and that no `ash_domains` line is needed in `config/config.exs` to keep it clean
- [x] 1.2 Confirm the suppression is scoped to this library's modules: verify the check still runs for the host by asserting in a test that a throwaway resource defined without a registered domain still emits the inclusion report (assert on `IO.warn` capture, not on absence of a warning elsewhere)
- [x] 1.3 Update `ClickhouseExLogger.Domain`'s moduledoc to stop instructing hosts to add `ash_domains`, and verify the module still compiles with no unused references to the removed advice

## 2. Add the three-way readiness check to `ClickhouseExLogger.Migration`

- [x] 2.1 Add a public function to `ClickhouseExLogger.Migration` that answers `:present`, `:absent`, or `:unreachable` for the `logs` table, reusing the existing unbound `ClickhouseExLogger.Repo.CreateDatabase` connection and releasing it in an `after`. It must read `system.tables` rather than querying the bound connection, because a connection bound to a missing database cannot report its own absence. Verify a database that does not exist answers `:absent`, not `:unreachable`
- [x] 2.2 Bound the query with an explicit timeout comfortably under the Installer's shutdown budget, and verify by timing a call against the test container that it returns well inside that budget
- [x] 2.3 Cover all three answers in `test/clickhouse_ex_logger/migration_test.exs` — verify `:present` against the migrated test database, `:absent` against a dropped `logs` table, and `:unreachable` against a closed connection, restoring the fixture in each case
- [x] 2.4 Verify the check issues no DDL: extend `test/clickhouse_ex_logger/no_schema_at_boot_test.exs` so that running the check against a database that does not exist leaves `system.databases` showing no such database

## 3. Build the application supervision tree and the handler installer

- [x] 3.1 Add `lib/clickhouse_ex_logger/application.ex` with a `start/2` that honours `config :clickhouse_ex_logger, auto_start: false` by starting an empty tree, and otherwise validates the `:handler` configuration with `Handler.validate/1` and `Handler.validate_include_node/1` before building children `[ClickhouseExLogger.Repo, {ClickhouseExLogger.Buffer, options}, Installer]`. Verify an invalid option fails the start with an error naming it and leaves no process running
- [x] 3.2 Add the installer child: a `GenServer` whose `init/1` returns `{:continue, :attach}` so the host's start-up is not blocked, which asks `Migration` for the readiness answer, and on `:present` or `:unreachable` calls `Handler.install/2` with the configured options, and on `:absent` logs one error naming the migration entry point and attaches nothing. Verify each of the three branches with the three answers from section 2
- [x] 3.3 Give the installer a `terminate/1` that removes the `:logger` handler and traps exits. Verify the shutdown sequence by stopping the supervised tree with rows buffered and asserting the handler is gone before the buffer drains, and that the drain stays inside its bound with undelivered rows counted as lost
- [x] 3.4 Verify `Handler.install/2` called by a host while the automatic start has already attached does not produce a second handler or a second buffer — assert one entry in `:logger`'s handler list and one `Buffer` process
- [x] 3.5 Verify a host with no connection configuration gets the existing `AshClickhouse.Error.ConfigurationError` naming the missing key, and that nothing falls back to a default destination

## 4. Wire the application into the build and keep the suite in control

- [x] 4.1 Add `mod: {ClickhouseExLogger.Application, []}` to `application/0` in `mix.exs` and bump `@version` to `0.3.0`. Verify `mix compile --warnings-as-errors` is clean
- [x] 4.2 Add `config :clickhouse_ex_logger, auto_start: false` to `config/test.exs`, with a comment explaining that Mix loads config before it starts any application while `test/test_helper.exs` replaces the repo configuration afterwards. Verify `mix test` starts no connection before the harness provisions the container's
- [x] 4.3 Cover the automatic start in the suite by starting the Application's children under `start_supervised!/1` in a new test module. Verify every assertion from section 3 still passes through that path rather than only through a directly constructed tree
- [x] 4.4 Confirm the package manifest is unaffected: verify `mix hex.build` lists `lib/clickhouse_ex_logger/application.ex` and that `test/mix_project_test.exs` still passes without a `files/0` change

## 5. Rewrite the host-facing documentation

- [x] {t} Rewrite the README's Setup section to three steps — declare the dependency, configure the connection, run the migration — and remove the supervision-tree example and the `ash_domains` section. Verify `test/clickhouse_ex_logger/readme_test.exs` passes: every `elixir` fence parses, and every module the README names is loadable
- [x] {t} Add an upgrade section stating that a host already supervising `ClickhouseExLogger.Repo` must set `auto_start: false` before upgrading, naming `ArgumentError: table name already exists` as the error it will otherwise meet, and giving the recovery as a configuration line rather than a code change
- [x] {t} Document `:handler` and `:auto_start` in the configuration table alongside the existing handler options, and update `ClickhouseExLogger.Repo` and `ClickhouseExLogger.Handler` moduledocs to present automatic start as the default path while keeping the explicit operations documented
- [x] {t} Verify `mix docs` builds with no warnings, since Hex rebuilds the documentation on publish

## 6. Full verification

- [x] {t} Run `mix format --check-formatted` and fix any formatting the new modules introduce
- [x] {t} Run `mix test --cover` and confirm the suite passes and `lib/` stays at or above the 90% line-coverage threshold in `mix.exs`, adding tests for any uncovered new function
- [x] {t} Read the CHANGELOG entry for this version against the upgrade note in 5.2, and confirm both tell the same story about the one breaking case