# Tasks

## 1. Dependencies and project setup

- [x] 1.1 Add `{:ash, "~> 3.33"}`, `{:ash_clickhouse, "~> 0.7"}` and `{:clickhouse, "~> 0.32"}` to `mix.exs`, create `config/config.exs` and `config/test.exs`, and verify `mix deps.get` resolves and `mix compile` succeeds
- [x] 1.2 Remove `ClickhouseLogger.hello/0` and its doctest from `lib/clickhouse_logger.ex`, and verify `mix test` still passes with the existing `test/clickhouse_logger_test.exs` updated to no longer reference it
- [x] 1.3 Set up a ClickHouse test instance for the suite — add a `test/support` helper that starts `ClickhouseLogger.Repo` against `CLICKHOUSE_URL`/`CLICKHOUSE_TEST_DATABASE` from the environment and is skipped with a clear message when they are absent, and verify a test tagged `:clickhouse` is excluded cleanly when no server is reachable
- [x] 1.4 Add `docker-compose.yml` (or document the equivalent command) for a local ClickHouse and verify `mix ash_clickhouse.setup` creates the configured database from the test config

## 2. The Ash resource, domain, and repo

- [x] 2.1 Add `ClickhouseLogger.Repo` via `use AshClickhouse.Repo, otp_app: :clickhouse_logger`, and verify a unit test asserting `AshClickhouse.Repo.config()` reflects the `config :clickhouse_logger, ClickhouseLogger.Repo` values from `config/test.exs`
- [x] 2.2 Add `ClickhouseLogger.Domain` declaring `resource ClickhouseLogger.LogEntry`, and verify `Ash.Domain.resource(ClickhouseLogger.Domain, ClickhouseLogger.LogEntry)` resolves without raising
- [x] 2.3 Add `ClickhouseLogger.LogEntry` with `table "logs"`, `engine "MergeTree()"`, `order_by "timestamp"`, and attributes `id` (`uuid_primary_key`), `timestamp` (`:utc_datetime_usec`), `level` (`:atom`), `message` (`:string`), `module`/`file`/`function` (`:string`), `line` (`:integer`), `metadata` (`:map`) — verify the resource compiles and that a test asserts each configured DSL key resolves through `AshClickhouse.DataLayer.Dsl.*/1`
- [x] 2.4 Decide the resource's `insert_opts` (or leave empty) and verify a test asserts the chosen `insert_opts` are what the data layer will apply
- [x] 2.5 Verify the migration discovery question from design.md: run the AshClickhouse migration path against a host-like project that depends on this library and observe whether `logs` is created; record the finding in a comment on this task so task 6 can be built against the answer
      - **FINDING: discovery does NOT cross the dependency boundary.** Built a host project at a temp path depending on this library via `:path`, configured `ClickhouseLogger.Repo` against a fresh `host_app_probe` database, and ran all three task paths:
        - `mix ash_clickhouse.setup` → `No AshClickhouse.Repo modules found.`
        - `mix ash_clickhouse.migrate` → no output, nothing migrated
        - `mix ash.migrate` (the `Spark.Dsl.Extension` path) → `Running migration for AshClickhouse...` then nothing
        - `SHOW DATABASES` afterwards → `host_app_probe` was never created; no `logs` table anywhere.
      - Root cause, confirmed in `deps/ash_clickhouse`: `Mix.Tasks.AshClickhouse.Helpers.modules/0` resolves modules via `Application.spec(Mix.Project.config()[:app], :modules)`, i.e. the *current project only*. Both `find_repos/0` and `find_resources/0` filter on that list.
      - **Consequence for task 6.1:** the second branch of design.md's Migration Plan is the one to build. This library ships `priv/repo/migrations/*.exs` and its own `mix clickhouse_logger.migrate`, calling `AshClickhouse.Release.migrate/3`, whose `default_migration_path/1` resolves through `repo.otp_app()` → `:code.priv_dir(:clickhouse_logger)/repo/migrations` (verified in `deps/ash_clickhouse/lib/ash_clickhouse/release.ex`), so it does read the dep's migrations. DDL still comes from `AshClickhouse.Migration.create_table_cql/1`, never hand-written.

## 3. Event-to-row mapping

- [x] 3.1 Implement the event normaliser that turns a `:logger` event map into the row map, and verify a test asserts `timestamp`, `level`, and `message` are populated for a `Logger.info/1` call
- [x] 3.2 Implement source-location extraction from `:mfa`, `:file`, and `:line` metadata, and verify tests cover an event with full source location and an event with none, asserting the absent fields become `nil` rather than failing
- [x] 3.3 Implement metadata stringification with the compound-value marker from design decision 5, and verify tests assert binaries/numbers pass through unchanged, atoms render via `to_string/1`, and a map/list/pid value renders as a marked, `Code.eval_string/1`-round-trippable term
- [x] 3.4 Verify the level column accepts all eight Erlang levels and that `Logger`-level aliases map to the stored value, via a table-driven test

## 4. The buffer process

- [x] 4.1 Implement `ClickhouseLogger.Buffer` as a `GenServer` with state for the FIFO row list, the flush timer, and the accepted/delivered/discarded/failed counters; verify a test casts an entry and reads the counters via `stats/1`
- [x] 4.2 Implement batch-size-triggered flush and verify a test that casts `batch_size` entries observes exactly one `Ash.bulk_create!/3` call containing all of them
- [x] 4.3 Implement interval-triggered flush and verify a test that casts fewer than `batch_size` entries and advances fake time observes one flush on the timer
- [x] 4.4 Implement drop-oldest overflow and verify a test that casts `max_buffer_size + n` entries observes `n` in `discarded`, a buffer never exceeding `max_buffer_size`, and the oldest entries being the ones discarded
- [x] 4.5 Implement single-in-flight-flush with the insert run on a supervised `Task`, and verify a test holding a flush open while new entries arrive observes no second concurrent `bulk_create` and correct ordering of the eventual flushes
- [x] 4.6 Implement failure handling — increment `failed`, discard the batch, log one error carrying `clickhouse_logger_internal: true`, and never raise — verified by a test with a stubbed failing insert asserting the error is logged exactly once and `failed` increases by one

## 5. The `:logger` handler

- [x] 5.1 Implement `ClickhouseLogger.Handler` with `@behaviour :logger_handler` and a `log/2` that casts the normalised row to the buffer, and verify it returns without contacting ClickHouse by asserting no bulk insert occurs synchronously
- [x] 5.2 Implement config validation and defaults for `batch_size`, `flush_interval_ms`, and `max_buffer_size`, and verify tests assert the documented defaults are applied when omitted and that a negative or non-integer value causes handler registration to return an error naming the option
- [x] 5.3 Implement the self-exclusion check for `clickhouse_logger_internal` metadata, and verify a test logging an event carrying that key produces no row and does not change the counters
- [x] 5.4 Implement `flush/1` support so handler removal drains buffered events, and verify a test that fills the buffer, removes the handler, and asserts the buffered rows were delivered
- [x] 5.5 Verify a crash inside `log/2` cannot propagate to the caller, with a test that makes normalisation raise and asserts the logging process survives and still receives a later successful log

## 6. Table creation path

- [x] 6.1 Based on the finding from task 2.5, implement the host-facing way to create the `logs` table — either documentation for `mix ash_clickhouse.migrate` plus a `ClickhouseLogger.LogEntry` reachable from the host's app, or a `mix clickhouse_logger.migrate` task delegating to `AshClickhouse.MigrationRunner.migrate/2` with DDL from `AshClickhouse.Migration.create_table_cql/1` — and verify against a real ClickHouse that the `logs` table exists with the documented columns and engine afterwards
- [x] 6.2 Verify from a test or a clean run that starting the application does not create or alter any ClickHouse schema, by asserting no `CREATE`/`ALTER` statement runs during boot

## 7. Documentation and end-to-end verification

- [x] 7.1 Write the `README.md` setup section — dependency, `config :clickhouse_logger, ClickhouseLogger.Repo`, the `config :my_app, :logger` handler entry, supervision order (`ClickhouseLogger.Repo` before `Logger.add_handlers/1`), and the migration command from task 6.1 — and verify every snippet compiles as written
- [x] 7.2 Document the observable behaviour an operator relies on: the `stats/1` map, the meaning of each counter, the drop-oldest policy, and that `failed` counts flushes rather than rows
- [x] 7.3 Add an end-to-end test that logs at several levels through a real handler + buffer + ClickHouse and asserts the rows are readable back with the expected columns, values, and ordering by `(timestamp, id)`
- [x] 7.4 Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, and the full `mix test` suite, and verify all three pass