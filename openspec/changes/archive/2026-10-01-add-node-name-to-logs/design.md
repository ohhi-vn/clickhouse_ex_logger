# Design

## Context

See proposal.md — Why.

The change is small in code and consequential in two places the code does not
show. Both were verified against the running ClickHouse 26.9 and the installed
`ash_clickhouse` 0.7.3, and both shape the approach.

**A new column cannot come from the existing migration.** `LogEntry` is the single
source of truth for the table: `create_table_cql/1` generates `CREATE TABLE` from
the resource, and `Insert` derives its column list from the same resource. Adding
an attribute therefore changes both ends at once. But the create-table migration
is version `20260101000000`, and every existing host has that version recorded in
`schema_migrations`. `MigrationRunner` skips by version, so that migration will
never run again anywhere — it can no longer introduce the column. The column needs
a second migration, with a version distinct from the first, leaving the first
untouched. That is also why this does not disturb the guarantee added by the
rename change, which pins the *creating* migration's version: that migration is not
being modified, only joined by a new one.

**An unmigrated host loses every row, quietly.** Because `Insert` names the column
explicitly, a host that upgrades without re-running the migration has its whole
batch rejected. Verified:

    Code: 16. DB::Exception: No such column node in table (NO_SUCH_COLUMN_IN_TABLE)

This is the library's whole failure mode being exercised: rows are counted `lost`,
`accepted == delivered + discarded + lost` still reconciles, and the counters look
healthy. Nothing raises. So the upgrade step cannot be a README footnote — it is a
requirement, and the migration task's own output is where an operator will look.

**The obvious rollback is broken upstream.** `AshClickhouse.Migration.reverse_statement/1`
has an `ALTER TABLE` branch that emits `DROP COLUMN IF NOT EXISTS`. ClickHouse has
no such syntax — it accepts `DROP COLUMN IF EXISTS`. Verified:

    Code: 62. DB::Exception: Syntax error: failed at position 30 (NOT):
    NOT EXISTS b. Expected one of: EXISTS, token sequence, … (SYNTAX_ERROR)

The existing create-table migration gets away with `reverse_statement/1` because its
statement is `CREATE TABLE`, whose reversal is valid. A column-adding migration
would inherit the broken branch, so its `down/0` must be written explicitly rather
than derived.

**Additive column generation already exists.** `AshClickhouse.Migration.alter_table_cql/2`
compares the resource's attributes against `system.columns` and emits
`ALTER TABLE … ADD COLUMN IF NOT EXISTS` for whatever is missing — additive only,
by design; it never drops or retypes. That is exactly the shape this change needs,
and deriving the statement from the resource means the column's type cannot drift
from the attribute definition. It requires a live repo connection, which
`Migration.setup/1` already provides: it starts the connection before applying
migrations, and it does so in `--dry-run` too, so a dry run can report the
statement it would run.

## Goals / Non-Goals

**Goals:**

- One new `Nullable(String)` column, populated by default, removable by option.
- Existing databases gain the column through a migration; no data rewritten, no
  existing column touched.
- The create-table migration keeps its version and content byte-for-byte.
- The rollback path actually works against ClickHouse.

**Non-Goals:**

- Not making the library read connection credentials — the separate
  `:username`/`:password` gap noted in `TestContainer` is untouched.
- Not querying or aggregating by node; only storing it.
- Not changing batching, ordering, the counter set, or the metadata map's
  treatment of user keys.
- Not reworking the duplicated comment block in `log_entry.ex`, noted as a
  pre-existing issue in the rename change's design.

## Decisions

### Read `node/0` at row-build time, and do not reserve a `:node` metadata key

`Event.row/2` calls `node/0` directly. It is a plain read of a loaded atom — no
message, no allocation, no I/O — so it cannot meaningfully slow the logging call
or fail it, which is what the event-to-row mapping requirement now demands.

The alternative, reading a `:node` key from the event's metadata, was rejected: it
would mean adding `:node` to `@event_keys`, which silently changes what
`Logger.info("x", node: "foo")` does today. That metadata is user data, and this
change has no reason to reinterpret it. Keeping `node/0` as the only source means
metadata behaviour is untouched, and the spec pins that.

`Event.row/1` keeps working, defaulting to capture enabled, so existing callers and
tests are unaffected.

### Disabled capture stores no value rather than dropping the column

`:include_node => false` writes NULL. The alternative — omitting the field — would
mean two different insert shapes for the same table, since `build_insert_rows`
encodes a missing key as nil anyway, so there is no efficiency argument for it.

The real reason is that the column's existence is a property of the schema, not of
configuration. A host that disables capture still gets the column, so a query
written against it keeps working, and re-enabling capture needs no migration.

### `:include_node` is a handler option, validated separately from the buffer options

`Handler.validate/1` returns `Buffer.options()` — a map of batching knobs with
`@type Buffer.options`. Node capture is not a batching concern; it affects how a
row is built, and the buffer never sees it. Folding it into that map would widen a
type whose only job is sizing a buffer.

So validation is a separate step in `install/2`, next to the batching validation,
rejecting a non-boolean with `{:error, {option, message}}` — the same error shape
`validate/1` already returns, so a host sees one consistent failure format.

`install/2` already passes the raw config to `register/2` alongside the validated
options, so an unrecognised key already reaches the handler; no plumbing change is
needed for the option to arrive in `log/2`.

### Declare `node` as the last attribute

`alter_table_cql/2` appends columns, so on a migrated table the physical order is
`…, metadata, node`. Declaring the attribute last makes a freshly created table
match, instead of putting `node` before `metadata` on new databases and after it
on old ones.

ClickHouse does not care about column order for named access, so this is cosmetic
— but `SELECT *` output order would otherwise differ between a fresh and a
migrated database, which is the kind of difference that surfaces as a puzzling
diff in someone's query output much later.

### `node` is optional and nullable

Declared with no `allow_nil?: false`, so `wrap_nullable/3` emits
`Nullable(String)` — matching `module`, `file`, and `function`. A non-null column
would force a placeholder for the not-distributed case, which is exactly what the
spec rules out.

### The new migration derives its statement from the resource and reverses itself explicitly

`change/0` calls `AshClickhouse.Migration.alter_table_cql(LogEntry, LogEntry.repo())`,
so the column type comes from the attribute and the statement is a no-op on a
database that already has it.

`down/0` is hand-written as `ALTER TABLE logs DROP COLUMN IF EXISTS node`, not
derived from `reverse_statement/1`, because of the syntax defect above. The
comment on it should name the defect, so the next person does not "simplify" it
back into a call that produces invalid SQL.

### A new migration version, leaving the create migration alone

The new file gets a version later than `20260101000000`, following the same
timestamp convention. `20260101000000` is left byte-identical — module name,
version string, and content — because the rename change's requirement depends on
it, and because changing it would re-issue `CREATE TABLE` against databases that
already have the table.

## Risks / Trade-offs

[A host upgrades and does not re-run the migration, so every flush fails and rows
are counted lost without any error surfacing to the application] → This is the
change's one real hazard. Mitigated by stating it as a requirement, documenting it
in the README's setup and in the migration task's moduledoc, and covering it with a
scenario. It cannot be made non-destructive: the resource is deliberately the
single source of truth for the column list, which is exactly what makes an unmigrated
host fail loudly instead of silently writing nothing.

[`reverse_statement/1` is used elsewhere and may be assumed correct] → The new
migration's `down/0` avoids it and the comment says why. The pre-existing
create-table migration still uses it, and is unaffected, because its reversal is
valid.

[`:include_node` is a new public option and a typo in it would otherwise be
silently treated as enabled] → Mitigated by validating it as a boolean in
`install/2` and by a test asserting a non-boolean fails with the option named.

[Two tests assert exact column sets and will fail until updated] → `resource_test.exs`
and `readme_test.exs` both enumerate columns; both are in the task list explicitly
rather than left to be discovered.

[A `node` column adds bytes to every row on hosts that never wanted it] → Accepted.
That is what the option is for, and `Nullable(String)` with an empty value costs
almost nothing on MergeTree.

[Node name is a string column, so grouping by it is not free] → Accepted. It is
for filtering, which is the stated purpose; a low-cardinality dictionary or a
`LowCardinality` type could be considered later if measured to matter.

## Migration Plan

1. Add the `node` attribute to `LogEntry` as the last attribute, and accept it on
   the `:create` action.
2. Teach `Event.row/2` to read `node/0` and honour the option; keep `row/1`
   defaulting to enabled.
3. Pass the option through `Handler.install/2`'s validation and document it.
4. Add the column-adding migration, with an explicit `down/0`.
5. Update the two exact-column tests and the README's table and configuration
   sections.
6. Verify against a database that predates the column, and against one that
   already has it.

**For existing hosts:** run `mix clickhouse_ex_logger.migrate` as part of the
deploy, before the new version starts logging. The same command, no new steps.

**Rollback.** Dropping the column with `mix`'s rollback for the new migration, or
the hand-written `down/0`, returns the schema to its previous shape; rows already
written keep the value until the column goes. Rolling the *library* back is also
safe: an older version does not name the column, and ClickHouse ignores extra
columns on read.