# Spec Delta

## MODIFIED Requirements

### Requirement: ClickHouse table contract

The system SHALL define a table, named `logs` in the configured database, whose
columns correspond to the row shape described by the event-to-row mapping
requirement: identifier, timestamp, level, message, module, file, line, function,
node, and metadata. The table SHALL be backed by a ClickHouse engine suitable for
append-only time-series data, ordered by timestamp so that time-range queries
prune parts efficiently.

The system SHALL provide the host application a way to create the database and
the table, and SHALL NOT create or alter ClickHouse schema on its own at
application boot.

That way SHALL be provided by this library rather than delegated to the data
layer's generic migration task, because that task discovers resources by
scanning the current project's modules and therefore never sees a resource owned
by a dependency.

It SHALL be reachable both from a Mix project and from a running release that has
no Mix and no build available. A host running a release SHALL therefore not have
to install Mix, copy sources, or reconstruct a build in order to satisfy the
library's own documented first step; it SHALL be able to invoke the same
operation against the running system before the new version starts logging.

The two entry points SHALL perform the same operation: create the database if
missing, apply pending migrations, record them in ClickHouse's version-tracking
table, and be safe to run more than once. Neither SHALL be the only supported
route to the schema, and neither SHALL be required in preference to the other —
a host that cannot run Mix uses the other.

Adding a column to the table SHALL be delivered as a migration separate from the
one that creates the table, because a database that already recorded the creating
migration will never run it again. The system SHALL therefore record the addition
under a version distinct from the creating migration's, leaving the creating
migration's own version and content unchanged.

The migration that adds the column SHALL be additive and SHALL NOT modify,
reinterpret, or remove any existing column. Applying it to a database that already
has the column SHALL change nothing.

Because the write path derives its column list from the table contract, a host
running a library version whose rows include a column its database does not have
SHALL have those writes rejected by ClickHouse. The host SHALL therefore run the
migration entry point before resuming logging after such an upgrade, and the
failure SHALL be handled per the failure-handling requirement until it does.

#### Scenario: Host creates schema before shipping logs

- **WHEN** a host application runs the migration entry point this library provides
- **THEN** the `logs` table exists with the documented columns and engine, and
  events written afterwards are readable from it

#### Scenario: Migration is idempotent

- **WHEN** a host application runs the migration entry point more than once
- **THEN** it reports the schema as up to date and changes nothing

#### Scenario: Host creates schema from a release with no Mix available

- **WHEN** a host runs the migration entry point from a running release, where no
  Mix task is available
- **THEN** the database and `logs` table are created from the migration files
  that release carries, without the host having to install Mix or rebuild the
  release

#### Scenario: Release entry point reports the same outcome as the Mix task

- **WHEN** a host runs the migration from a release against a database that is
  already up to date
- **THEN** it reports that nothing was applied and nothing was changed, in the
  same terms the Mix task reports

#### Scenario: Release entry point fails on an unreachable server

- **WHEN** a host runs the migration entry point from a release and ClickHouse is
  unreachable or the credentials are wrong
- **THEN** the call returns a diagnosable failure naming the connection or
  database problem, rather than raising an unhandled exception or reporting
  success

#### Scenario: Application boot does not touch schema

- **WHEN** an application starts with the handler installed
- **THEN** no table or database is created or altered as part of starting up

#### Scenario: Configured credentials are absent

- **WHEN** the system is configured without a reachable ClickHouse URL or the
  target database does not exist
- **THEN** delivery failures are handled per the failure-handling requirement,
  and the reported reason names the connection or database problem

#### Scenario: Fresh database gets every documented column

- **WHEN** the migration entry point runs against a database that does not yet
  exist
- **THEN** the created table has the node column alongside the other documented
  columns, and it is usable without a further migration

#### Scenario: Existing database receives the new column

- **WHEN** the migration entry point runs against a database whose table was
  created before the node column existed
- **THEN** the node column is added, the rows already present are retained, and
  no existing column changes

#### Scenario: Adding the column again changes nothing

- **WHEN** the migration entry point runs more than once against a database that
  already has the node column
- **THEN** it reports the schema as up to date and alters nothing

#### Scenario: Upgraded host has not yet migrated

- **WHEN** a host runs a library version that writes the node column against a
  database that does not have it, and has not run the migration entry point
- **THEN** the writes are rejected by ClickHouse, the failure is reported and
  counted as lost per the failure-handling requirement, and the reported reason
  names the missing column

### Requirement: Published library identity

The library SHALL be published as the hex package `clickhouse_ex_logger`, built
as the OTP application `:clickhouse_ex_logger`, with all of its public modules
under the `ClickhouseExLogger` namespace. A host SHALL be able to declare the
dependency, configure the connection, start the pipeline, create the schema, and
read pipeline statistics using only those names, without reference to any other
library name.

The connection configuration SHALL be read from the `:clickhouse_ex_logger`
application environment, keyed by the repo module, so that
`config :clickhouse_ex_logger, ClickhouseExLogger.Repo` is the single place a host
states its ClickHouse connection.

The system SHALL provide the schema migration as `mix clickhouse_ex_logger.migrate`
for a host with Mix, and as a function in the `ClickhouseExLogger` namespace that
a host calls from a running release, and those SHALL be the only supported ways
for a host to create the schema — consistent with the table contract requirement,
which forbids delegating to the data layer's generic task.

Both entry points SHALL be documented in the library's introduction, in the
function's own documentation, and in the Mix task's documentation, so that a host
reaches the release path from whichever entry point it already knows.

The system SHALL NOT retain the previous application name, module namespace,
configuration key, or Mix task name in any form. A host still using a previous
name SHALL be given a diagnosable failure rather than a silently absent
configuration.

#### Scenario: Host configures, starts, and migrates using the documented names

- **WHEN** a host adds `{:clickhouse_ex_logger, "~> 0.1"}` to its dependencies,
  configures `config :clickhouse_ex_logger, ClickhouseExLogger.Repo`, adds
  `ClickhouseExLogger.Repo` to its supervision tree, runs
  `mix clickhouse_ex_logger.migrate`, and calls
  `ClickhouseExLogger.Handler.install/2`
- **THEN** the `logs` table exists, subsequent log events reach it, and the
  handler reports itself active

#### Scenario: Host migrates from a release using only the documented names

- **WHEN** a host whose release carries no Mix runs the documented release
  migration function against the same configuration key
- **THEN** the `logs` table is created and the release reports the schema as up
  to date on a subsequent run, with no reference to any other library name

#### Scenario: Operator reads statistics under the renamed module

- **WHEN** an operator calls the buffer's statistics function through the
  `ClickhouseExLogger` namespace
- **THEN** the documented counters are returned, with the same keys and meanings
  as before the rename

#### Scenario: Host still configures the previous application name

- **WHEN** a host sets connection configuration under the previous application
  name and key instead of `:clickhouse_ex_logger`
- **THEN** the system does not silently fall back to a default ClickHouse
  connection, and the failure names the missing configuration rather than
  appearing as an unreachable database

#### Scenario: Host invokes the previous Mix task name

- **WHEN** a host runs the migration command under the previous task name
- **THEN** Mix reports that no such task exists, rather than running a migration
  under a name the library no longer supports