# Tasks

## 1. Dependency floor

- [x] 1.1 Point `mix.exs` at the `ash_clickhouse` release carrying the `DateTime64` JSON-encoding fix and the `:debug` failure log (0.7.5) — a path dep to `../ash_clickhouse` while unreleased — and confirm `mix deps.get` resolves it. (Original floor of `~> 0.7.4` was insufficient: 0.7.4 still encodes `DateTime64(6)` as integer microseconds and overflows.)

## 2. Collapse `ClickhouseExLogger.Insert`

- [x] 2.1 Rewrite `lib/clickhouse_ex_logger/insert.ex` so `insert/1` keeps its `Enum.chunk_every(1_000)` loop but calls `Ash.bulk_create/4` per chunk with `batch_size: 1_000`, `return_records?: false`, `return_errors?: true`; remove `normalize/1`, `string_keys/1`, `wire_name/1`, `row_field_names/1`, and the `DataLayer`/`DataLayerInsert`/`Dsl` aliases and building-block calls. Verify with `mix compile --warnings-as-errors`.
- [x] 2.2 Keep `insert([]) == {:ok, 0}` and the `{:ok, committed} | {:error, message, committed}` contract; map `%Ash.BulkResult{status: :success}` to a committed chunk and any other status to a halted `{:error, message, committed}`. Verify the contract with the chunk-boundary cases in `test/clickhouse_ex_logger/insert_test.exs`.
- [x] 2.3 Update `describe/1` to extract a readable reason from `Ash.BulkResult.errors` (`Exception.message/1` per exception-shaped error, joined, with an `inspect/1` fallback) instead of matching client error structs. Verify the unknown-database and unreachable-server tests still assert the server's or client's own text and not an inspected struct.
- [x] 2.4 Rewrite the moduledoc: the module is no longer a workaround for 0.7.3; state that it calls `Ash.bulk_create/4` per chunk because `:bulk_create_with_partial_success` is unsupported and the chunk loop is what preserves the committed-row count.

## 3. Update tests

- [x] 3.1 In `test/clickhouse_ex_logger/insert_test.exs`, replace the ISO-8601 timestamp test with one that passes a raw `DateTime` and asserts full microsecond precision; assert the non-UUID `id` case reports the resource's validation reason (`"is invalid"`) rather than ClickHouse's `"Cannot parse UUID"`.
- [x] 3.2 Add a test that a chunk containing a valid row plus a row the resource rejects commits zero rows, reports a failure, and does not write the valid row (all-or-nothing per chunk).
- [x] 3.3 In `test/clickhouse_ex_logger/buffer_test.exs`, replace the `normalize/1`-raises-on-missing-`timestamp` trigger for "a write that dies without reporting an outcome" with a deterministic trigger that actually kills the write process (e.g. a value the client's JSON encoding raises on), and confirm the three dead-write tests pass.
- [x] 3.4 Confirm `test/clickhouse_ex_logger/buffer_failure_test.exs` still names `UNKNOWN_DATABASE` in the reported reason, adapting the extraction or assertion only if Ash's wrapping requires it.

## 4. Verification and deprecation record

- [x] 4.1 Run the full suite (`mix test`) and confirm every Existing `insert`, `buffer`, `buffer_failure`, and `readme` test passes.
- [x] 4.2 Run `mix format --check-formatted` and `mix test --cover`, confirming the 90% lib gate still holds; check `README.md` for any reference to the removed workaround and update it if present.
- [x] 4.3 Add a CHANGELOG entry: the move to the fixed `ash_clickhouse`, the collapse onto `Ash.bulk_create/4` with `stop_on_error?: true`, the `handle_result/1` log moving to `:debug`, and the observable nuance that malformed rows are now rejected by the resource's validation.
