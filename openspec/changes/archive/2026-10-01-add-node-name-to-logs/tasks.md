# Tasks

## 1. Add the `node` attribute to the resource

- [x] 1.1 Add `attribute(:node, :string, public?: true)` to `ClickhouseExLogger.LogEntry` as the **last** attribute in the `attributes` block, with a comment noting that declaring it last keeps a freshly created table's column order identical to a migrated one, since `alter_table_cql/2` appends; verify it lands after `metadata`
- [x] 1.2 Add `:node` to the `accept/1` list on the `:create` action; verify the list is otherwise unchanged and still includes all nine existing columns
- [x] 1.3 Confirm the attribute resolves to `Nullable(String)` — `AshClickhouse.Migration.wrap_nullable/3` wraps any attribute with `allow_nil?: true`, and `module`/`file`/`function` already work this way; verify by generating the create-table CQL and checking the column type
- [x] 1.4 Update the `@moduledoc` column table in `log_entry.ex` to include `node` with its ClickHouse type and meaning; verify it documents why the value may be absent

## 2. Capture the node name when building a row

- [x] 2.1 Add a `node` field to the `ClickhouseExLogger.Event.row/0` typedoc map; verify the type reflects that the value is a string or absent
- [x] 2.2 Change `Event.row/1` to `Event.row/2` taking an options map, with the one-arity form defaulting to an empty map so existing callers and tests are unaffected; verify `Event.row(event)` still works
- [x] 2.3 Read `node/0` when capture is enabled and store it as a string; store no value when capture is disabled, and when the node is `:nonode@nohost`, so a placeholder is never written where a real host would be
- [x] 2.4 Pass the option as a plain boolean read with a default of enabled, so an absent option captures; verify the default is enabled and not inverted
- [x] 2.5 Do **not** add `:node` to `@event_keys`; verify a user metadata key named `node` still lands in the row's `metadata` map, unchanged from today
- [x] 2.6 Document in the `@moduledoc` that the node name comes from the running system rather than from event metadata, and why user metadata named `node` is left alone

## 3. Expose and validate the option

- [x] 3.1 Pass the handler's config into `Event.row/2` from `Handler.log/2`, so the option reaches row construction; verify the row is still built in the calling process and the `cast` to the buffer is unchanged
- [x] 3.2 Add `:include_node` validation to `Handler.install/2`, rejecting a non-boolean with the same `{:error, {option, message}}` shape `validate/1` already returns; verify `install/2` leaves nothing running when it rejects
- [x] 3.3 Keep `:include_node` **out** of `Handler.validate/1`'s return value and out of `Buffer.options()`; verify `validate/1` still returns only the three batching keys, so its existing contract and tests are untouched
- [x] 3.4 Document `:include_node` in the `@moduledoc` configuration list alongside `:level`, `:batch_size`, `:flush_interval_ms`, and `:max_buffer_size`, stating the default and that disabling it does not change the table's shape

## 4. Add the column-adding migration

- [x] 4.1 Create `priv/repo/migrations/<new-version>_add_node_to_logs.exs` with a version later than `20260101000000` and the same timestamp convention; verify the create-table migration `20260101000000_create_logs.exs` is left byte-identical, including its `@version` string, because the rename change's requirement depends on it
- [x] 4.2 Implement `repo/0` and `version/0` against the new module, matching the existing migration's shape
- [x] 4.3 Implement `change/0` as `AshClickhouse.Migration.alter_table_cql(LogEntry, LogEntry.repo())`; verify the derived statement is `ALTER TABLE logs ADD COLUMN IF NOT EXISTS node Nullable(String)` and that it is empty when the column already exists
- [x] 4.4 Verify `change/0` can reach `system.columns` through the repo connection that `Migration.setup/1` starts before applying migrations, including under `--dry-run`; verify a dry run reports the statement without applying it
- [x] 4.5 Implement `down/0` as an explicit `ALTER TABLE logs DROP COLUMN IF EXISTS node`, **not** via `AshClickhouse.Migration.reverse_statement/1`, with a comment naming that `reverse_statement/1` emits `DROP COLUMN IF NOT EXISTS`, which ClickHouse rejects with a syntax error; verify the statement executes against a real server
- [x] 4.6 Re-run `Migration.setup/1` against a database created by the previous schema and confirm the column is added, existing rows are retained, and no existing column's type changed

## 5. Update the tests that assert the exact shape

- [x] 5.1 Add `:node` to the sorted attribute list asserted in `resource_test.exs`; verify the list remains sorted and the other nine names are unchanged
- [x] 5.2 Add a test in `resource_test.exs` asserting `:node` is optional, alongside the existing source-location nullability test
- [x] 5.3 Add `node` to the documented column list in `readme_test.exs` so the README's table and the resource stay in agreement
- [x] 5.4 Add `node` to the `SELECT` in `integration_test.exs` and assert the stored value, proving the column survives the real insert path rather than only the resource definition
- [x] 5.5 Add an `event_test.exs` case asserting the node field is present by default, absent when the option disables capture, and absent for a non-distributed node; verify it needs no database
- [x] 5.6 Add a `handler_test.exs` case asserting `install/2` rejects a non-boolean `:include_node` with the option named in the error

## 6. Update documentation

- [x] 6.1 Add a `node` row to the `logs` table table in `README.md`, including that it is absent for a non-distributed system and for a host that disabled capture
- [x] 6.2 Add `:include_node` to the README's configuration key table with its default, alongside the four existing keys
- [x] 6.3 Add a note to the README's schema-creation step stating that an already-deployed host must re-run `mix clickhouse_ex_logger.migrate` after upgrading, before logging resumes, or its writes are rejected as naming an unknown column; verify this is stated in the setup section rather than only in a changelog
- [x] 6.4 Add the same upgrade note to the `mix clickhouse_ex_logger.migrate` task's `@moduledoc`, so an operator reading the migration output at deploy time sees it
- [x] 6.5 Document the `down/0` defect in `mix.exs`'s dependency comment or the task moduledoc only if that is where a reader would look; otherwise leave it in the migration file, and verify it is not stated in two places that could drift

## 7. Verify

- [x] 7.1 Run `mix format --check-formatted`; verify it exits clean
- [x] 7.2 Run `mix compile --warnings-as-errors` in both `:dev` and `:test`; verify both exit clean and no unused alias was left behind by the `Event.row/2` change
- [x] 7.3 Run the full containerised `mix test` against a real ClickHouse; verify every module passes, including `resource_test.exs`, `integration_test.exs`, `event_test.exs`, and `handler_test.exs`
- [x] 7.4 Confirm against a real server that the create-table migration is untouched: run `mix clickhouse_ex_logger.migrate` against a database already recording `20260101000000` and verify it reports that version as skipped, and that the create migration's `@version` still reads `20260101000000`
- [x] 7.5 Verify the new migration's `down/0` against a real server: apply it, confirm the column is dropped, re-apply and confirm it is restored, and confirm re-running the migration twice is a no-op
- [x] 7.6 Verify the upgrade hazard is real and handled: against a database without the column, confirm the write is rejected with a missing-column error naming the column, that the failure is counted as lost rather than raised, and that `accepted == delivered + discarded + lost` still reconciles
- [x] 7.7 Grep `lib/`, `test/`, `config/`, `priv/`, and `README.md` for `ClickhouseLogger` and `clickhouse_logger` and confirm there are no hits; verify `Insert` needed no change because it derives its column list from the resource, and say so explicitly in the summary if that assumption proved wrong