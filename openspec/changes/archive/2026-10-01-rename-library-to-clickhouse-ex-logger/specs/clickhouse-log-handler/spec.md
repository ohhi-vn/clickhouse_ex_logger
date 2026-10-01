# Spec Delta

## ADDED Requirements

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

The system SHALL provide the schema migration command as
`mix clickhouse_ex_logger.migrate`, and that command SHALL be the only supported
way for a host to create the schema — consistent with the table contract
requirement, which forbids delegating to the data layer's generic task.

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

### Requirement: Migration identity survives the rename

The migration that creates the `logs` table SHALL be tracked in ClickHouse's
`schema_migrations` table under the same version it has always used. Renaming the
migration module SHALL NOT change that version, and the version SHALL NOT be
changed to reflect the library's rename.

The system SHALL therefore treat a database whose `schema_migrations` table
already records that version as up to date, regardless of which module now
implements the migration, and SHALL NOT re-issue the table creation statement
against such a database.

#### Scenario: Migration command runs against a database created before the rename

- **WHEN** the migration command runs against a database where the `logs` table
  was created by the previous library name and `schema_migrations` already
  records the shipped version
- **THEN** the command reports the schema as up to date and applies no
  statements, leaving the existing table and its rows untouched

#### Scenario: Migration is applied fresh after the rename

- **WHEN** the migration command runs against a database that does not exist
- **THEN** the table is created and the same shipped version is recorded, so a
  later run against that database is also a no-op

#### Scenario: The shipped migration version is not the rename date

- **WHEN** the shipped migration is inspected after the rename
- **THEN** its version string is unchanged from the version the library has
  always shipped, rather than a version derived from the rename