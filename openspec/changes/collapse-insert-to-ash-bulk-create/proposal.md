# Proposal

## Why

`ClickhouseExLogger.Insert` exists only because `ash_clickhouse` 0.7.3's
`Ash.bulk_create/4` path was broken: `Insert.insert_opts/2` leaked Ash's internal
bulk options into the client option list, and `encode_datetime/2` encoded
`DateTime64` in the wrong unit. The module works around both by hand-rolling an
insert from the data layer's public building blocks, and `normalize/1`
pre-encodes the timestamp as an ISO-8601 string.

`ash_clickhouse` upstream fixes both defects. The option leak is fixed in 0.7.4
(`insert_opts/2` now forwards only client-recognised keys). The `DateTime64`
overflow is fixed in 0.7.5: 0.7.4's encoder still emitted an integer count of
microseconds for `DateTime64(6)`, which ClickHouse's JSON reader interprets as
seconds and overflows; 0.7.5 emits a fractional-second number. The workaround and
its timestamp compensation are therefore redundant, and the hand-rolled insert is
a second, independently maintained copy of the data layer's own bulk path — the
drift the resource-as-single-source-of-truth design exists to prevent.

The switch also exposes a second, unmarked failure log from the data layer's
`handle_result/1` (`:warning`/`:error`) that the old direct building-block call
never triggered. Because the buffer reports each failed flush once and a handler
writing to the same ClickHouse must not feed a row describing its own failure back
into the failing pipeline, the data layer's failure log is moved to `:debug`.

## What Changes

- **Replace `Insert`'s hand-rolled write with `Ash.bulk_create/4`.** The
  statement building, row encoding, and client-option selection currently done
  with `build_insert_rows/2` + `qualified_table/1` + `insert_statement/2` +
  `Dsl.insert_opts/1` + `Repo.insert_rows/4` all move back into the data layer.
- **Keep the 1000-row chunk loop around `Ash.bulk_create/4`, with
  `stop_on_error?: true`.** A flush is still split into chunks and stops at the
  first failing chunk, because the data layer does not advertise
  `:bulk_create_with_partial_success` (it is `false` in 0.7.5, as in 0.7.3).
  Without the outer loop, a single `Ash.bulk_create/4` call cannot report how many
  rows an earlier chunk committed, which the buffer's `delivered`/`lost`/`accepted`
  reconciliation depends on. `stop_on_error?: true` (Ash's default is `false`) is
  what makes each chunk all-or-nothing, so `committed` is the sum of the
  fully-successful chunks. The chunk loop is what keeps `insert/1`'s
  `{:ok, committed} | {:error, message, committed}` contract.
- **Remove the timestamp pre-encoding workaround.** `normalize/1` currently
  rewrites a `DateTime` to an ISO-8601 string so the broken encoder would not
  overflow; the 0.7.5 encoder handles a raw `DateTime` correctly. `normalize/1`'s
  remaining job — converting row keys from atoms to the strings
  `build_insert_rows/2` looks up — is no longer needed either, because
  `Ash.bulk_create/4` accepts the row map directly.
- **Raise the dependency floor to the fixed `ash_clickhouse` (`~> 0.7.5`).** `~> 0.7`
  permits 0.7.0–0.7.3, where removing the workaround would reintroduce the bugs,
  and 0.7.4's `DateTime64(6)` encoding is still wrong.
- **Move the data layer's own failure log to `:debug`** (in the `ash_clickhouse`
  fork), so the buffer remains the single reporter of a failed flush.
- **Extract a readable failure reason from the `Ash.BulkResult`** rather than
  inspecting client error structs, preserving the requirement that a reported
  failure names the server's or client's problem.
- **Rewrite `Insert`'s moduledoc.** It is no longer a workaround. It records the
  one remaining reason it does not delegate wholesale to a single
  `Ash.bulk_create/4`: partial-success accounting is unavailable, so the chunk
  loop is the accounting mechanism.
- **Behavioral nuance (not a requirement change):** a row malformed for the
  resource — a non-UUID `id`, a missing `timestamp`, an input the table does not
  define — is now rejected by the resource's own client-side validation before any
  request reaches ClickHouse. The reported reason still names the problem, but its
  text changes (for example `"id is invalid"` instead of ClickHouse's `"Cannot
  parse UUID"`), a missing-`timestamp` row is now a reported insert error rather
  than a write process that dies, and a chunk holding a rejected row commits none
  of it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. This replaces an implementation and preserves every observable contract —
row contents, delivery order, row-level committed/lost accounting, bounded
non-blocking logging, and single-flush-per-failure reporting. The error-text
nuance above stays inside the existing "reason names the problem the server or the
client reported" requirement, so no requirement text changes and the change is
opted out of specs via `skip_specs: true`.

## Impact

**Code**

- `lib/clickhouse_ex_logger/insert.ex` — collapses to a chunk loop over
  `Ash.bulk_create/4` plus failure-reason extraction; removes `normalize/1`,
  `string_keys/1`, `wire_name/1`, `row_field_names/1`, and the direct
  building-block calls.
- `mix.exs` — `ash_clickhouse` switched to the fixed release (currently the local
  `../ash_clickhouse` path at 0.7.5; must become `~> 0.7.5` once published).
- `../ash_clickhouse/lib/ash_clickhouse/data_layer.ex` (dependency checkout) —
  `handle_result/1`'s failure log moved from `:warning`/`:error` to `:debug`.

**Tests**

- `test/clickhouse_ex_logger/insert_test.exs` — the non-UUID and unknown-database
  assertions now depend on how Ash surfaces the failure; the `normalize/1`-driven
  timestamp test changes meaning.
- `test/clickhouse_ex_logger/buffer_test.exs` — the "write that dies" cases are
  currently triggered by `Insert.normalize/1` raising on a row with no
  `timestamp`; that trigger disappears, so they need a mechanism that still kills
  the write process (for example a row that makes the client raise).

**Dependencies**

- `ash_clickhouse` minimum `0.7.5`. No new dependency; no public API change.

**Public surface**

- None. `ClickhouseExLogger.Insert.insert/1`'s spec, return shapes, and the
  `logs` schema are unchanged.
