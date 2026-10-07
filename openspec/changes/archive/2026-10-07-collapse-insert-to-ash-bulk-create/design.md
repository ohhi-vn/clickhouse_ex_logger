# Design

## Context

See `proposal.md` — Why for motivation. What constrains the approach:

- `ClickhouseExLogger.Insert.insert/1` must keep its contract:
  `{:ok, committed} | {:error, message, committed}`, where `committed` is the
  number of rows ClickHouse accepted. `ClickhouseExLogger.Buffer` derives
  `delivered` and `lost` from it and the `clickhouse-log-handler` spec requires
  `accepted == delivered + discarded + lost` to reconcile exactly.
- `insert/1` chunks a flush at 1000 rows and stops at the first failing chunk.
  The chunks before it are already committed and cannot be un-inserted, which is
  why `committed` exists.
- `AshClickhouse.DataLayer.can?(:bulk_create_with_partial_success)` is `false` in
  0.7.5 (as in 0.7.3), and the data layer's chunked `bulk_create/3` returns only
  `{:error, total}` on a failed chunk. A single `Ash.bulk_create/4` call
  therefore cannot report how many rows an earlier internal chunk committed.
- The write runs on the buffer's own spawned process, not in the process that
  logged. A change here does not touch the caller-path budget
  (`Bounded cost added to a logging call`), which measures the handler callback.

## Goals / Non-Goals

**Goals:**

- Remove the hand-rolled insert so the data layer's own bulk path is the single
  implementation of statement building, row encoding, and client-option
  selection.
- Delete the timestamp pre-encoding workaround, which the 0.7.5 encoder makes
  redundant.
- Preserve `insert/1`'s return contract and the row-level committed accounting
  exactly.

**Non-Goals:**

- Changing the `logs` schema, `Event.row/2`'s row shape, `Buffer`'s API or
  counters, or any other public surface.
- Removing the chunk loop. That loop is the accounting mechanism; see Decision 1.
- Chaining flushes, parallelising chunks, or retrying. All remain as they are.

## Decisions

### 1. Call `Ash.bulk_create/4` once per 1000-row chunk, keeping the loop

`insert/1` keeps its `Enum.chunk_every(@chunk_size)` and calls `Ash.bulk_create/4`
per chunk, crediting `length(chunk)` on success and halting on the first failure.

**Why:** a single `Ash.bulk_create/4` over the whole flush would push the chunking
into the data layer, where a later chunk's failure discards the count of rows an
earlier chunk committed (partial success is unsupported). The buffer would then
report more `lost` than it lost and fewer `delivered` than ClickHouse accepted,
breaking the reconciliation requirement. Chunking outside `Ash.bulk_create/4`
keeps the committed count in this module's hands.

**Alternative rejected:** keep the hand-rolled `build_insert_rows/2` +
`Repo.insert_rows/4` path and only delete the timestamp workaround. That leaves a
second implementation of the data layer's bulk path with no remaining reason to
exist — exactly the drift the resource-as-single-source-of-truth design prevents.

### 2. Every chunk is all-or-nothing, by passing `stop_on_error?: true`

`Ash.bulk_create/4` separates changesets that fail the resource's own validation
before it calls the data layer, and with `stop_on_error?` true and partial success
unsupported it aborts the call rather than sending the valid remainder
(`deps/ash/lib/ash/actions/create/bulk.ex:641` calls
`maybe_stop_on_bulk_create_error` per invalid changeset). A chunk containing any
row the resource rejects therefore commits nothing, which matches the current
behaviour: the raw path sends one `INSERT` per chunk and ClickHouse rejects the
whole statement when any row is malformed.

`stop_on_error?` must be passed explicitly — Ash's default is
`Application.compile_env(:ash, :bulk_actions_default_to_errors?, false)`, i.e.
`false` (`deps/ash/lib/ash.ex:493`). Left at the default, Ash writes the rows it
can and reports the rest as errors, so a single success/failure per chunk would
silently under-count the rows that did commit.

**Why this matters:** it is what makes "committed = sum of fully-successful prior
chunks" exact. If a chunk could partially commit, a single boolean success/failure
per chunk would mis-account the rows inside it.

**Alternative rejected:** `stop_on_error?: false` so a flush continues past a bad
chunk. That changes the documented "later chunks are not attempted once one
fails" behaviour and returns `:partial_success`, whose committed-row breakdown
would have to be inferred from `error_count` — undefined for a data-layer error
that fails a whole chunk.

### 3. Map the `Ash.BulkResult` to `insert/1`'s contract

```elixir
case Ash.bulk_create(chunk, LogEntry, :create, opts) do
  %Ash.BulkResult{status: :success} -> {:cont, {:ok, committed + length(chunk)}}
  %Ash.BulkResult{status: status, errors: errors} when status in [:error, :partial_success] ->
    {:halt, {{:error, describe(errors), committed}}}
end
```

`opts` sets `batch_size: @chunk_size`, `return_records?: false` (no record
building), `return_errors?: true` (so a reason is available), and
`stop_on_error?: true` (Decision 2). Any non-`:success` status is treated as a
failed chunk — Decision 2 makes `:partial_success` mean a client-side validation
failure that committed nothing.

### 4. Failure reasons come from the `Ash.BulkResult`, not from inspecting structs

`describe/1` changes from matching client error structs to extracting a readable
message from the Ash error list: `Exception.message/1` for exception-shaped
errors, joined, with an `inspect/1` fallback. This keeps the requirement that a
reported failure names the problem the server or the client reported, and keeps
it a sentence an operator can read rather than an inspection of an internal data
structure. The `UNKNOWN_DATABASE` and unreachable-server cases are the tests that
pin it.

**Note:** the resource's client-side validation now produces some reasons (for
example `"id is invalid"` for a non-UUID `id`) where ClickHouse used to
(`"Cannot parse UUID"`). The reason still names the problem; only its source and
text change. This is inside the existing requirement, hence no spec delta.

### 5. Raise the dependency floor to the fixed `ash_clickhouse` (`~> 0.7.5`)

`~> 0.7` permits 0.7.0–0.7.3, where the removed workaround was required for
`DateTime64` writes to succeed, and 0.7.4's `encode_datetime/2` still emitted an
integer count of microseconds for `DateTime64(6)` — which ClickHouse's JSON reader
takes as seconds and overflows. The fix that emits a fractional-second number
first lands in 0.7.5, so the floor must move to it.

### 6. The dead-write tests need a new deterministic trigger

`buffer_test.exs` currently provokes "a write that dies without reporting an
outcome" by handing `insert/1` a row with no `timestamp`, relying on
`normalize/1` raising. That trigger disappears: a missing `timestamp` is now a
resource validation failure, so `Ash.bulk_create/4` returns an error rather than
killing the write process. The scenario itself is unchanged and still required —
the `clickhouse` 0.32 client still raises on responses its error lookup does not
recognise — so the tests must kill the write process another honest,
deterministic way (a metadata value the encoder cannot render raises before a
connection is used). The buffer's `:DOWN` handling is not touched.

### 7. The data layer's own failure log moves to `:debug`

Routing the write through `Ash.bulk_create/4` causes
`AshClickhouse.DataLayer.handle_result/1` to log `:warning`/`:error` on every
failed insert. The old direct `Repo.insert_rows/4` path returned the error without
that log, so a failed flush was reported once (the buffer's marked error). Two
things break if it stays visible: the spec requires each failed flush be reported
once, and a handler that writes to the same ClickHouse would capture the unmarked
warning and buffer a row describing its own failure — the feedback loop the
`clickhouse_ex_logger_internal` marker exists to prevent.

The fix belongs in the data layer: it already returns the error, so logging it at
a visible level duplicates the caller's reporting. `handle_result/1` is changed to
log at `:debug` in the `ash_clickhouse` checkout, matching
`Connection.insert_rows/4`. The buffer remains the single reporter.

## Risks / Trade-offs

- **A chunk's committed count could be mis-credited if Ash ever returns
  `:partial_success` after committing rows.** → Decision 2 relies on
  `stop_on_error?` aborting before the data layer when a changeset is invalid.
  The implementation must assert, in a test, that a chunk mixing a good row with
  an unencodable/ invalid row commits zero and reports a failure.
- **Ash's error wrapping could obscure the server's message.** → The existing
  `UNKNOWN_DATABASE`, unreachable-server, and absent-connection tests assert the
  reason is the server's or client's own text and not an inspected struct; they
  are the guard and must keep passing (with text adjusted for the new source).
- **Reintroduced changeset cost on the buffer process.** → Accepted. The spec's
  cost budget covers the caller path only; the caller path is untouched. If a
  later measurement shows the batch path is the bottleneck, the building-block
  path can be restored from history.
- **The dependency logs a second, unmarked failure report.** → Decision 7 moves
  `handle_result/1`'s log to `:debug`; `buffer_failure_test` is the guard that a
  failed flush produces exactly one captured report.
- **The dependency floor excludes releases before 0.7.5 for hosts.** → Intended and
  documented in the CHANGELOG; those versions cannot write these rows correctly
  (0.7.0–0.7.3 leak client options and overflow `DateTime64`; 0.7.4 still
  overflows `DateTime64(6)`).

## Migration Plan

None for hosts: no schema change, no configuration change, no public API change.
`mix deps.get` resolves `ash_clickhouse` 0.7.5 or newer once it is published (the
working tree currently points at a local `../ash_clickhouse` checkout so the fix
can be exercised before release; `mix.exs` must switch to `~> 0.7.5` before
publishing). Rollback is reverting the commit and restoring the previous
requirement.

## Open Questions

None.
