# Spec Delta

## MODIFIED Requirements

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
  configures `config :clickhouse_ex_logger, ClickhouseExLogger.Repo`, runs
  `mix clickhouse_ex_logger.migrate`, and starts its application
- **THEN** the `logs` table exists, subsequent log events reach it, and the
  handler reports itself active, with no reference in the host's own code to the
  connection or the handler

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

### Requirement: Published package contents

The system SHALL publish a package whose contents are sufficient for a host to
complete the whole documented setup — declare the dependency, compile, read the
introduction and the licence, and create the schema — without needing any file from
the source checkout.

The package SHALL include the versioned migration files the library applies at run
time. Those files SHALL be located through the OTP application's priv directory
rather than through a path relative to the working directory, so that they resolve
to the same files from the library's own checkout and from a host's dependency tree.

The package SHALL NOT include the library's own `config/` directory. The build
system evaluates only the current project's configuration, so a dependency's
`config/` is never read: shipping it would place files in the package that cannot
affect a host.

Because the package therefore carries no configuration, a host's build compiles
this library's domain and resource without any domain registration. The system
SHALL NOT report that as a warning in the host's build. It SHALL resolve this
within its own definitions rather than by documenting a configuration line for
the host, because the host has no domain to register: the domain and resource
belong to this library, and a host that registered them would be reaching into a
dependency's internals to silence a report about them.

Suppressing that report SHALL NOT depend on the host disabling the check
globally, and SHALL NOT be achieved by a setting only the host could make. It
SHALL be scoped to this library's own domain and resource, so that a host's own
Ash resources continue to be checked against the host's own configuration.

A package manifest that omits the priv directory SHALL be treated as a defect rather
than as a reduction in scope: the migration command is the only supported way for a
host to create the schema, so a release whose manifest drops the migrations is a
release whose documented first step cannot run. The build SHALL be verified against
the manifest before it is released, so that this is detected before publication
rather than by the first host that installs the package.

The package SHALL NOT include test-only sources, coverage output, container state,
or the project's planning and change records. Test-only sources compile into the
test build and are not part of the library a host consumes.

#### Scenario: Host runs the migration command from a published dependency

- **WHEN** a host application that depends on the published package runs
  `mix clickhouse_ex_logger.migrate`
- **THEN** the command locates the shipped migration files, creates the `logs` table
  described by the table contract, and reports the schema as up to date on a
  subsequent run

#### Scenario: Package manifest omits the priv directory

- **WHEN** the package manifest is inspected and the priv directory is absent from it
- **THEN** the release is rejected before publication rather than published, because
  the migration command would fail to resolve its migration files in a host's
  dependency tree

#### Scenario: Host compiles against the shipped configuration

- **WHEN** a host that has added no configuration for this library compiles
- **THEN** its build reports no warning about this library's domain or resource,
  because the host was never in a position to resolve the report

#### Scenario: Host's own domain checking is unaffected

- **WHEN** a host that keeps its own Ash resources compiles against this library
- **THEN** this library's suppression does not extend to the host's own resources,
  which continue to be checked against the host's own domain configuration

#### Scenario: Manifest excludes the library's own configuration

- **WHEN** the package manifest is inspected
- **THEN** it does not include a `config/` directory, because the build system
  never reads a dependency's configuration and shipping it could not reach a host

#### Scenario: Migration files resolve regardless of working directory

- **WHEN** the migration command is invoked from a directory other than the host
  application's root
- **THEN** it applies the same shipped migrations it applies when invoked from the
  host's root

#### Scenario: Consumer reads the introduction and the licence from the package

- **WHEN** a person installs the package and reads its introduction and licence
  files
- **THEN** those files are present in the installed package and contain the same
  content as the project's

#### Scenario: Manifest excludes build-only and planning content

- **WHEN** the package manifest is inspected
- **THEN** it lists the library sources and its runtime assets, and does not list
  the test-only support sources, coverage output, or the project's change records

## ADDED Requirements

### Requirement: Automatic startup of the log pipeline

The system SHALL start its own pipeline when its application starts: it SHALL
supervise the ClickHouse connection and attach the `:logger` handler. A host that
has declared the dependency and configured the connection SHALL NOT have to write
application code to begin shipping logs.

The automatic start SHALL NOT be a second registration path. It SHALL go through
the same registration operation an explicit host call uses, and SHALL take the
same options and reject the same invalid ones, so that the guarantees that
operation makes — validation before anything starts, all-or-nothing behaviour, and
nothing left running after a rejected registration — hold for it identically.

The options the automatic start uses SHALL be read from the application's
configuration, so that a host states them in the same place it states its
connection.

The automatic start SHALL NOT create or alter any ClickHouse schema.

Starting the pipeline SHALL be reversible within the documented bounds. When the
host's application stops, the handler SHALL stop receiving events before the buffer
drains, and the drain SHALL remain bounded, with events that could not be delivered
counted as lost.

A host SHALL be able to disable the automatic start, and when it is disabled the
system SHALL start nothing. The host SHALL be able to disable it because the
connection cannot be established twice in one VM: a host that both supervises the
connection itself and leaves the automatic start enabled would fail to start, and
the system SHALL NOT require a host to learn that by crashing. The documentation
SHALL state this, naming both the situation it applies to and the setting that
resolves it.

Where the connection is not configured, the automatic start SHALL fail and the
failure SHALL name the configuration the host is missing. It SHALL NOT fall back to
a default destination.

#### Scenario: Host declares the dependency and configures the connection

- **WHEN** a host declares the dependency, configures the connection, and starts
  its application
- **THEN** the connection is supervised and the handler is attached, and the
  host's own code contains no reference to either

#### Scenario: Automatic start uses the host's configured options

- **WHEN** the host configures a minimum level, batch size, flush interval, maximum
  buffer size, or node-capture option, and its application starts
- **THEN** the running pipeline uses those values, and an option the host omitted
  takes its documented default

#### Scenario: Configured option is invalid

- **WHEN** the host configures an option the system cannot honour and its
  application starts
- **THEN** the start fails with an error identifying that option, and nothing the
  start began is left running

#### Scenario: Connection is not configured

- **WHEN** a host declares the dependency without configuring the connection and
  starts its application
- **THEN** the start fails with an error naming the missing configuration, rather
  than starting against a default destination

#### Scenario: Host disables the automatic start

- **WHEN** the host disables the automatic start and its application starts
- **THEN** the system starts no connection and attaches no handler, so the host
  can supervise the connection and attach the handler itself

#### Scenario: Host registers explicitly while the automatic start is enabled

- **WHEN** the automatic start has already attached the handler and the host
  attaches it again through the explicit operation
- **THEN** one handler and one buffer are running, not two

#### Scenario: Application stops while events are buffered

- **WHEN** the host's application stops with events still buffered
- **THEN** the handler stops receiving events first, the buffer drains within the
  documented bound, and the events it could not deliver are counted as lost

### Requirement: Startup schema readiness

Before attaching the handler automatically, the system SHALL determine once
whether the table it writes to exists, and SHALL base its decision to attach on
that result.

Where the server answers and the table is absent, the system SHALL NOT attach the
handler and SHALL report once through the standard logger that the table is
missing, naming the operation that creates it. A host that has not created the
schema SHALL therefore be given a readable message rather than a rising count of
events silently lost.

Where the server cannot be reached, the system SHALL attach the handler anyway and
leave delivery to be handled as any other delivery failure. A server that is
briefly unavailable at startup SHALL NOT leave the host without log capture until
its next restart.

The check SHALL confirm that the table exists, not that it carries every column the
current library version writes. A table that exists but predates a column added by
a later version SHALL still be attached, and the writes ClickHouse rejects SHALL be
reported and counted per the failure-handling requirement, which is the outcome
the upgrade guidance already describes.

The check SHALL be read-only. It SHALL NOT create, alter, or migrate any schema,
and it SHALL NOT be performed by the process that attaches the handler, so that
attaching performs no network work.

The check SHALL NOT hold up the host's start-up. It SHALL be performed on the
system's own process, and the host's application SHALL reach its own start-up
return whether or not the check has answered.

#### Scenario: Table exists

- **WHEN** the server answers at startup and the table exists
- **THEN** the handler is attached and no statement that creates or alters schema
  has been issued

#### Scenario: Table does not exist

- **WHEN** the server answers at startup and the table does not exist
- **THEN** the handler is not attached, and one error naming the operation that
  creates the table is reported

#### Scenario: Server cannot be reached

- **WHEN** the server cannot be reached at startup
- **THEN** the handler is attached anyway, and delivery failures are reported and
  counted as any other delivery failure

#### Scenario: Table predates a column this version writes

- **WHEN** the table exists at startup but does not carry a column the current
  library version writes
- **THEN** the handler is attached, and the writes ClickHouse rejects are reported
  with the missing column named and counted as lost

#### Scenario: Check does not hold up start-up

- **WHEN** the host's application starts against a server that is slow to answer
  or does not answer at all
- **THEN** the host's own start-up returns without waiting for the check to
  complete

#### Scenario: Check changes no schema

- **WHEN** the check runs at startup
- **THEN** no database is created, no table is created or altered, and no migration
  is recorded