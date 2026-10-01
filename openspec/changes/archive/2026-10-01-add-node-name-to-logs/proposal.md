# Proposal

## Why

A row in the `logs` table says what happened and where in the code it happened,
but not *which machine* it happened on. On a single node that costs nothing. The
moment a service runs on more than one, every row from every node lands in the
same table with nothing to distinguish them, and the questions that logs exist to
answer become unanswerable: which instance threw this error, is this one noisy
node the cause, does a stack trace only reproduce on one machine.

Node name is also the missing half of a debugging session. A row carries
`module`, `file`, and `line`, so an operator can jump straight to the code — but
cannot tell whether the code that failed is the code that just got deployed to
one node out of twelve.

Capturing it is cheap: `node/0` is an already-loaded atom, read while the row is
being built in the process that logged, adding no I/O and no measurable cost to
the logging call.

## What Changes

- Add a `node` column to the `logs` table, holding the full Erlang node name as
  a string — `my_app@10.0.0.5` — so two applications sharing a host stay
  distinguishable.
- Record the node name on every row **by default**, with no configuration
  required.
- Add a handler option to turn it off. When disabled the column records no value
  rather than the column disappearing, so the table shape is the same for every
  host and toggling the option never requires a migration.
- Where the node is not distributed — a local `iex` session or `mix test`, where
  the node is `:nonode@nohost` — the column records no value. A stored
  `nonode@nohost` is indistinguishable from a real host name at a glance, so
  absence is the honest representation and it makes distributed rows filterable
  with a single "is not null" query.
- Ship a second migration that adds the column to databases created before it.
  The existing create-table migration has already been recorded in
  `schema_migrations` on every existing host, so it will not run again and cannot
  be relied on to introduce the column.

**BREAKING for existing hosts:** after upgrading, the insert names a column the
old table does not have, and ClickHouse rejects the whole batch. A host MUST run
`mix clickhouse_ex_logger.migrate` before resuming logging, or every flush fails
and its rows are counted as lost. This is stated as a requirement rather than left
to release notes, because the failure surfaces only as rows quietly going missing.

The migration that creates the `logs` table keeps its version `20260101000000`
and its content unchanged. This adds a new migration alongside it and does not
alter the existing one, so the guarantee that a renamed library reuses the same
migration identity continues to hold.

## Capabilities

### New Capabilities

None. The node name is another field on the row the existing capability already
describes.

### Modified Capabilities

- `clickhouse-log-handler`: `Event-to-row mapping` gains the node name as a row
  field; `ClickHouse table contract` gains the `node` column and the requirement
  that existing databases receive it through a new migration. A new requirement
  covers the option that turns node capture off and what it means when it is.

## Impact

**Code.** `LogEntry` gains the attribute and accepts it on `:create`;
`Event` reads `node/0` when building a row and takes the option into account;
`Handler` exposes and validates the option.

**Not changed.** `Insert` needs no edit — it derives its column list and value
encoding from the resource, so the column flows through automatically. `Buffer`
is untouched: batching, ordering, and the counters are unaffected.

**Schema.** One additive column, `Nullable(String)`, appended to the table. No
existing column changes type, and the engine and `ORDER BY` are unchanged, so
this is a metadata-only change in ClickHouse terms and does not rewrite data.

**Migration.** A second migration file with a new version, applying
`ALTER TABLE logs ADD COLUMN IF NOT EXISTS`. Additive and idempotent — it is a
no-op on a database that already has the column, including one migrated twice.

**Tests.** `resource_test.exs` asserts the exact attribute set and
`readme_test.exs` asserts the documented column list; both must gain `node`.
`integration_test.exs` gains end-to-end coverage that the value reaches the table.

**Operators.** Existing hosts must re-run the migration command before logging
resumes. That is the one action this change requires of them, and it is the same
command they already run at deploy time.