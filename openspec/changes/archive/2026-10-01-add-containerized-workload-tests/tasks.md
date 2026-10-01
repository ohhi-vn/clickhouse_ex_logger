# Tasks

## 1. Dependencies

- [x] 1.1 Add `{:testcontainer_ex, "~> 0.9.1", only: :test}` to `deps/0` in `mix.exs`, leaving the three runtime deps untouched; verify `mix deps.get` resolves it and `mix compile --warnings-as-errors` still succeeds
- [x] 1.2 Confirm the dep is test-only by construction: verify `files:` in `package/0` is unchanged and still ships no test or harness code

## 2. Container harness

- [x] 2.1 Add `test/support/test_container.ex` compiled only for `:test` (already covered by `elixirc_paths/1`): start `TestcontainerEx`, provision a ClickHouse container pinned to image `clickhouse/clickhouse-server:26.9` with reuse enabled and an HTTP `/ping` wait strategy, and expose `url/0`, `container_id/0`, `pause/0`, `unpause/0`; verify it compiles and that `url/0` returns an `http://host:port` URL built from the container's mapped port. Note: build the config through `TestcontainerEx.Container.Config` directly rather than `TestcontainerEx.ClickHouseContainer`, whose wait strategy shells out to `clickhouse-client --port 8123` and never reports ready
- [x] 2.2 Rewrite `test/test_helper.exs` to start the container, `Application.put_env/3` the resulting URL onto `:clickhouse_logger, ClickhouseLogger.Repo` so it overrides `config/test.exs`, run `ClickhouseLogger.Migration.setup/1`, and **fail loudly** with the detected engine and its status instead of excluding `:clickhouse`; register `ExUnit.after_suite/2`; verify `mix test` runs the `:clickhouse` modules against the container's port rather than `localhost:8123`
- [x] 2.3 Remove `available?/0` and `unavailable_message/0` from `ClickhouseLogger.TestServer`; verify with a repo-wide search that no caller remains

## 3. Shared-state ordering

- [x] 3.1 Make `ClickhouseLogger.Case` default to `async: false` with an explicit `async: true` opt-in, and correct `ClickhouseLogger.BufferFailureTest`'s moduledoc to match what it now is; verify every module using the case template still compiles and the suite runs without cross-module interference

## 4. Bound the shutdown flush

- [x] 4.1 In `ClickhouseLogger.Buffer`, add a `@shutdown_flush_timeout 5_000` constant and change `terminate/2` to run the final write on a `spawn_monitor` and wait for it with `receive`/`after`, matching the shape `start_write/1` already uses; verify `mix compile --warnings-as-errors`
- [x] 4.2 Cover the bound: assert that removing the handler while the container is paused returns well inside the bound and that the unwritten rows are counted as `lost`, not retried

## 5. Row-level accounting for partially failed flushes

- [x] 5.1 Change `ClickhouseLogger.Insert.insert/1` to accumulate rows committed across chunks and return `{:ok, committed}` or `{:error, message, committed}`; update its `@spec` and moduledoc; verify it compiles and `ClickhouseLogger.Buffer` is its only caller
- [x] 5.2 In `ClickhouseLogger.Buffer`, rewrite `tally/2` for both result shapes to credit `delivered` with rows committed and charge the remainder of `in_flight` to a new `lost` counter; add `lost` to the `@type stats`, to `counters/1`, and to `empty_stats/0`; verify `mix compile --warnings-as-errors`
- [x] 5.3 Cover the invariant `accepted == delivered + discarded + lost` for a clean run, a buffer-overflow run, and a failed run; verify each case reconciles to zero remainder
- [x] 5.4 Update the `stats/1` example in `ClickhouseLogger.Buffer`'s moduledoc and in `README.md` to show `lost` and its meaning

## 6. Workload test

- [x] 6.1 Add `test/clickhouse_logger/workload_test.exs` as `async: false`: phase 1 drives concurrent producers at a healthy ClickHouse and asserts `delivered == accepted`, `discarded == 0`, and the buffer drains to zero
- [x] 6.2 Phase 2 pauses the container mid-flight and, while load continues, samples `Buffer.stats/0` to assert the buffer never exceeds `max_buffer_size`, that the per-call logging latency of producers stays bounded, that `discarded` climbs (the bound is real, not vacuous), and that no producer process crashes
- [x] 6.3 Phase 3 unpauses the container and asserts the buffer drains to zero, `delivered` advances after recovery, and `accepted == delivered + discarded + lost` reconciles exactly

## 7. Cleanup

- [x] 7.1 Delete `ClickhouseLogger.Migration.server_available?/0` and its now-empty supporting helpers; verify the module still compiles and nothing references it
- [x] 7.2 Delete `docker-compose.yml` and remove every reference to it and to starting a server by hand from `README.md`, `ClickhouseLogger.Case`'s moduledoc, and `ClickhouseLogger.TestServer`'s moduledoc; document that `mix test` needs a running Podman or Docker engine and how to remove a reused container. Also document in `config/test.exs` why the Podman socket has to be exported there rather than in `test_helper.exs`
- [x] 7.3 Verify the full suite passes against the container, with the workload test included, and that the four engine-independent modules still pass on their own
