# Proposal

## Why

An audit of `lib/` against the capability spec found seventeen defects, all
confirmed by running the code. The severe ones share one failure mode: the
buffer can stop delivering rows **silently and permanently** while still
reporting that it is active. The rest are places where the library's own
documentation, its `@spec`s, and its code disagree — which is how the severe ones
went unnoticed in the first place.

## What Changes

**Silent, permanent loss of all logging**

- `Buffer` clears its in-flight write reference only when the write result message
  arrives. A write that dies before sending one leaves the reference set forever:
  no batch trigger fires again, `flush/1` never replies, the crashed rows are
  counted nowhere, and `active?` still reports `true`. This is reachable in
  production, not just from a malformed row, because `clickhouse` 0.32.0 raises
  `UndefinedFunctionError` (it references an undefined `ClickHouse.NetworkError`
  struct for `DB::NetException` bodies) and `MatchError` (its error-type lookup
  returns `nil` for an unrecognised body), and neither is in
  `AshClickhouse.Connection`'s rescue list.
- `Buffer.tally/2` has no clause for any other `Insert.insert/1` result shape, so
  an unexpected shape crashes the buffer into the same wedge.
- `Insert.insert/1`'s `@spec` and `@doc` advertise an `{:error, message}` shape it
  can never return — documenting the buffer's crash trigger as legitimate.
- `Buffer.terminate/2` starts a second concurrent write while one is already in
  flight, breaking the module's own "at most one write is in flight" invariant.

**Silent row loss and broken contracts**

- `Handler.validate/1` accepts `batch_size` greater than `max_buffer_size`, which
  makes the batch trigger unreachable: the buffer silently drops the majority of
  rows (10 rows accepted → 7 discarded at a 60s interval) for self-inflicted
  reasons, not because ClickHouse is slow.
- `Handler.install/2` starts the buffer before registering the handler, so a
  registration failure leaves a running, `start_link`ed buffer behind —
  contradicting the moduledoc's guarantee that a rejected install "leaves nothing
  running".
- `:level` is the one handler option nothing validates, so an invalid level
  surfaces as a `:logger` tuple instead of the documented `{:error, {option,
  message}}`.
- `Event.metadata/1` and `Event.internal?/1` read only `:meta`, although the
  moduledoc promises both event shapes are handled: a top-level event yields
  `metadata: %{}`, and a top-level internal marker is missed, so the guard that
  stops the handler feeding itself can be bypassed.
- `Event.string_or_nil/1` raises `UnicodeConversionError` (surrogate code points)
  and `FunctionClauseError` (improper lists), breaking `row/2`'s "never raises"
  contract. The message path was hardened for exactly these cases; this path was
  not.
- `Buffer.flush/1` maps a call timeout to `:ok`, indistinguishable from "drained",
  so `Handler.uninstall/1` stops the buffer believing it flushed.

**Dead code and documentation that contradicts the code**

- `Insert.describe/1`'s clause for `AshClickhouse.Error.ClickhouseError` never
  matches the common path — the client returns `ClickHouse.ConnectionError` /
  `DatabaseError` unnormalised — so operators read a stringified struct instead of
  the server's message.
- `Migration.ensure_database/1` calls a bang validator that raises, violating
  `setup/1`'s `{:error, reason}` contract and costing both entry points their
  actionable failure message.
- `Event.source_location/1` renders a `nil` module from `:mfa` as the string
  `"nil"`, defeating `WHERE module IS NULL`.
- `mix.exs` omits `config/`, so the `ash_domains` entry that silences Ash's
  domain-inclusion warning never reaches a host.
- `CHANGELOG.md` documents `capture_node: false`, but the code reads
  `:include_node`; the unknown key is silently accepted, so a host believes node
  capture is off while it is on.
- `LogEntry`'s moduledoc claims rows are ordered by `(timestamp, id)`; the DDL is
  `ORDER BY (timestamp)`.
- `Insert`'s moduledoc says "three separate defects" and "exactly the three points
  above" but enumerates two; `LogEntry` has a verbatim duplicated comment block.
- `Handler`'s `:buffer` doc says a host can use "its own buffer under a different
  name", but only a pid is accepted — an atom name is silently ignored.
- `lib/clickhouse_ex_logger/handler.ex` is not `mix format`-formatted. It went
  unnoticed because `mix format --check-formatted` with no arguments is silently
  defeated by Mix's `format_timestamp` manifest cache, which skips every file older
  than the last format run.

No public function is removed and no table column changes. The one externally
visible behavioural tightening is that registration now **rejects** configurations
it previously accepted: an invalid `:level`, and `batch_size` greater than
`max_buffer_size`. Both fail at registration with an error naming the option,
which is the behaviour the spec already requires for every other option.

## Capabilities

### New Capabilities

None. Every fix belongs to the existing pipeline capability.

### Modified Capabilities

- `clickhouse-log-handler`: harden the failure paths so a dead write cannot wedge
  the buffer silently (**Buffered batched delivery**, **Failure handling and
  observability**); reject configurations that silently discard rows and validate
  every handler option (**Event configuration**); leave nothing running when
  registration fails, and stop reporting a bounded flush as drained (**Handler
  registration and lifecycle**); make row mapping total across both event shapes
  and both error directions, and stop rendering an absent module as a string
  (**Event-to-row mapping**); report the server's own message on failure and return
  an error tuple rather than raising on an invalid database name (**ClickHouse
  table contract**); ship the configuration the host needs to suppress Ash's
  domain warning (**Published package contents**).

## Impact

- `lib/clickhouse_ex_logger/buffer.ex` — in-flight write recovery, tally fallback,
  `terminate/2` write ordering, `flush/1` timeout honesty.
- `lib/clickhouse_ex_logger/handler.ex` — validation of `:level` and the
  batch/buffer relationship, install rollback, `:buffer` documentation, formatting.
- `lib/clickhouse_ex_logger/event.ex` — metadata and internal-marker lookup across
  both event shapes, `string_or_nil/1` hardening, `source_location/1` nil module.
- `lib/clickhouse_ex_logger/insert.ex` — error description, return-shape contract,
  moduledoc accuracy.
- `lib/clickhouse_ex_logger/migration.ex` — non-raising database-name validation.
- `lib/clickhouse_ex_logger/log_entry.ex` — duplicated comment, sorting-key doc.
- `mix.exs` — package manifest gains `config/`.
- `CHANGELOG.md` — correct the node-capture option name.
- Tests: new coverage for a write that dies, an install that fails, the
  `batch_size`/`max_buffer_size` relationship, both event shapes, the `:file` edge
  inputs, and the migration error path.
- No dependency changes, no schema migration, no table or column change.