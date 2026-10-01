# Clickhouse Log Handler

## Purpose

Defines how Elixir `Logger` events are turned into durable, queryable rows in
ClickHouse: handler registration and configuration, the mapping from a log event
to a table row, buffered batched delivery, and the behaviour of the system when
ClickHouse is slow, overloaded, or unreachable.

## Requirements

### Requirement: Handler registration and lifecycle

The system SHALL provide a module usable as an Elixir `:logger` handler,
registered without the calling process performing any network or database work.
Registration SHALL be an explicit operation that validates its configuration and
starts the batching machinery, returning a handler identifier. The system SHALL
support removal of the handler at runtime, flushing any events still buffered
before the handler stops.

That final flush SHALL be bounded by a fixed timeout. Removal SHALL therefore
complete within that bound even when ClickHouse has stalled and is accepting
nothing, and any rows the bounded flush could not deliver SHALL be counted as
lost rather than retried indefinitely.

#### Scenario: Handler attaches successfully

- **WHEN** a caller registers the handler with a valid handler id and options
- **THEN** the system returns `{:ok, handler_id}` and subsequent `Logger` calls
  at or above the configured level reach the handler

#### Scenario: Handler is removed with events still buffered

- **WHEN** the handler is removed while the system holds buffered events
- **THEN** the system flushes the remaining buffered events before returning, so
  that removal does not discard logs already accepted

#### Scenario: Removal completes in bounded time while ClickHouse is stalled

- **WHEN** the handler is removed while ClickHouse is not accepting writes and
  the system still holds buffered events
- **THEN** removal returns within the documented bound rather than waiting on
  ClickHouse indefinitely, and the events that could not be written are counted
  as lost

#### Scenario: Handler raises while handling an event

- **WHEN** any unexpected error occurs while processing one event
- **THEN** the process that emitted the log is not crashed and does not receive
  an exception

### Requirement: Event configuration

The system SHALL accept a level threshold and a batching configuration at
registration time. The configuration SHALL support a minimum level, a batch
size, a flush interval in milliseconds, and a maximum buffer size. Values that
are absent SHALL take documented defaults. A value that is present but not a
positive integer SHALL cause registration to fail with an error naming that
option, rather than causing a failure later during event delivery.

#### Scenario: Configuration omitted entirely

- **WHEN** the handler is registered with no batching options
- **THEN** the system applies the documented defaults and continues to accept
  and deliver events

#### Scenario: Configuration contains an invalid value

- **WHEN** the handler is registered with a negative batch size, a zero flush
  interval, or a non-integer value
- **THEN** registration returns an error identifying the offending option

#### Scenario: Minimum level filters events

- **WHEN** the handler is registered at minimum level `:warning` and the
  application logs at `:info`
- **THEN** that event is not accepted into the buffer and no row is written for
  it

### Requirement: Event-to-row mapping

The system SHALL map each accepted log event to exactly one row containing the
event's timestamp, severity level, message text, and source location when the
calling library supplied one. Rows SHALL carry a unique identifier, SHALL record
the name of the node that handled the event, and SHALL preserve every piece of
user-supplied log metadata as string key/value pairs. Metadata values that are
not natively representable as strings SHALL be rendered in a documented,
deterministic textual form rather than dropped.

The node name SHALL be recorded in full, including the part identifying the
application as well as the part identifying the host, so that two applications
sharing one host are distinguishable. Where the system is not distributed, the
name SHALL be recorded as no value rather than as a placeholder that could be
confused with a real host.

Reading the node name SHALL NOT introduce any additional wait on the process that
logged, and SHALL NOT be capable of causing that process to fail.

Mapping an event to a row SHALL NOT raise, whatever the event's message field
contains. A message the system cannot render as text — chardata that is not
valid Unicode, a list that is not well-formed — SHALL be stored in a
deterministic textual form instead, on the same terms as any other value it
cannot render: rendered rather than dropped. An event that raises out of the
mapping is an event whose row is lost without being counted, which is the one
outcome this system's other requirements exist to prevent.

#### Scenario: Event carries source location

- **WHEN** an event includes module, file, line, and function information
- **THEN** the resulting row records all four values as written

#### Scenario: Event has no source location

- **WHEN** an event originates from a call that supplied no module, file, line,
  or function
- **THEN** the row records these as empty rather than failing to be written

#### Scenario: Event carries structured metadata

- **WHEN** an event carries metadata such as `user_id` and `request_id`
- **THEN** every metadata key and value appears on the row, with values rendered
  as strings

#### Scenario: Metadata value is not a simple scalar

- **WHEN** an event carries metadata whose value is a map, list, or other
  compound term
- **THEN** the row stores the value in a deterministic textual form that
  round-trips to an equivalent Elixir term when parsed, and the event is not
  dropped

#### Scenario: Row records the node that handled it

- **WHEN** the system runs distributed and an event is accepted
- **THEN** the row records the full node name, including both the application
  part and the host part

#### Scenario: System is not distributed

- **WHEN** the system runs as a single local node and an event is accepted
- **THEN** the row records no node value rather than a placeholder, and the event
  is still written

#### Scenario: Recording the node does not slow the logging call

- **WHEN** the process that logs an event is measured during the log call
- **THEN** the call returns without waiting on ClickHouse, and reading the node
  name adds no wait of its own

#### Scenario: Recording the node cannot fail the logging call

- **WHEN** anything unexpected occurs while reading the node name
- **THEN** the process that emitted the log is not crashed and the event is still
  buffered

#### Scenario: Message chardata is not valid Unicode

- **WHEN** an event's message is chardata that contains bytes that are not a
  valid character sequence, such as a binary holding an invalid byte
- **THEN** the row stores the message in its inspected textual form, the mapping
  returns a row rather than raising, and no exception reaches the caller

#### Scenario: Message is not well-formed chardata

- **WHEN** an event's message is a list that is neither valid chardata nor valid
  report data, such as an improper list
- **THEN** the row stores the message in its inspected textual form and the
  mapping returns rather than raising

### Requirement: Buffered batched delivery

The system SHALL accumulate accepted events in memory and deliver them to
ClickHouse in batches, writing a batch as a single insert operation. The system
SHALL flush a partial batch when the flush interval elapses even if the batch
size has not been reached. Delivery SHALL be ordered such that events are
delivered in the order they were logged.

#### Scenario: Batch size reached

- **WHEN** the number of buffered events reaches the configured batch size
- **THEN** the system writes exactly that batch as one insert operation and
  empties the buffer

#### Scenario: Interval elapses before batch size is reached

- **WHEN** fewer than the configured batch size are buffered and the flush
  interval elapses
- **THEN** the system writes the buffered events as one insert operation

#### Scenario: Accepting an event does not perform a write

- **WHEN** the process that logs an event is measured during the log call
- **THEN** the call returns without waiting on ClickHouse, and the write occurs
  later on the system's own process

#### Scenario: Delivery preserves logging order

- **WHEN** events E1, E2, E3 are logged in that order
- **THEN** the rows for E1, E2, E3 are delivered such that querying the table
  ordered by timestamp and identifier shows them in that order

### Requirement: Non-blocking behaviour under load

The process that logs an event SHALL NOT block on buffer state, and the system
SHALL bound its memory use by never holding more than the configured maximum
buffer size. When the buffer is full, the system SHALL drop the oldest buffered
event to make room for the newest, rather than growing without bound or blocking
the caller.

#### Scenario: Buffer at capacity

- **WHEN** an event arrives while the buffer already holds the configured
  maximum number of events
- **THEN** the oldest buffered event is discarded, the new event is retained,
  and the logging call still returns immediately

#### Scenario: Sustained overload

- **WHEN** logging outpaces ClickHouse delivery for a sustained period
- **THEN** the buffer size stays at or below the configured maximum, the
  process logging events is never blocked, and the count of discarded events is
  observable

### Requirement: Failure handling and observability

A failed insert SHALL NOT raise into the application, SHALL NOT retry
indefinitely, and SHALL NOT cause the handler to write a row describing its own
failure. The system SHALL report each failed flush once through the standard
logger, and SHALL make both the running state and the cumulative counts of
accepted, delivered, discarded, lost, and failed events observable to operators.

A single flush MAY be split into several insert operations, and those operations
MAY partially succeed. The counts SHALL therefore be maintained at row
granularity, not per flush: the delivered count SHALL credit every row ClickHouse
accepted, including those committed by an operation that a later operation in the
same flush failed after. The accepted, delivered, discarded, and lost counts SHALL
reconcile exactly — every accepted event appears in exactly one of the other
three, with no unaccounted remainder.

#### Scenario: ClickHouse is unreachable

- **WHEN** a flush fails because ClickHouse is unavailable
- **THEN** the events from that batch are discarded, one error describing the
  failure is reported through the logger, the failed-event counter increases,
  and the application continues to run

#### Scenario: Partially failed flush is accounted at row level

- **WHEN** a flush delivers some rows to ClickHouse and a later part of that same
  flush fails
- **THEN** the delivered count increases by exactly the rows ClickHouse accepted,
  the lost count increases by exactly the rows it did not, and the failed count
  increases by one for the flush

#### Scenario: The handler's own error report is not fed back into itself

- **WHEN** the handler reports an insert failure through the logger
- **THEN** that report does not result in a row being written for itself, and
  the failure counter does not increase again as a result

#### Scenario: Operator inspects handler state

- **WHEN** an operator queries the handler for its current statistics
- **THEN** the counts of accepted, delivered, discarded, lost, and failed events
  since the handler started, plus whether the handler is currently active, are
  returned

#### Scenario: Operator reconciles the counters

- **WHEN** an operator subtracts the delivered, discarded, and lost counts from
  the accepted count
- **THEN** the result is zero, so the operator can tell exactly how many events
  were lost rather than inferring it

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

### Requirement: Published package contents

The system SHALL publish a package whose contents are sufficient for a host to
complete the whole documented setup — declare the dependency, compile, read the
introduction and the licence, and create the schema — without needing any file from
the source checkout.

The package SHALL include the versioned migration files the library applies at run
time. Those files SHALL be located through the OTP application's priv directory
rather than through a path relative to the working directory, so that they resolve
to the same files from the library's own checkout and from a host's dependency tree.

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
- **THEN** it lists the library sources and its runtime assets, and does not list the
  test-only support sources, coverage output, or the project's change records

### Requirement: Published package metadata

The package SHALL declare a description, a licence, and a set of links identifying
where the project lives, so that a person browsing the package page or the
documentation can reach the source, report a problem, and read the introduction
without knowing anything about the repository in advance.

Every link the package declares SHALL resolve to a publicly reachable location that
the project actually maintains. A link SHALL NOT be declared for a resource the
project does not publish, such as a discussion page or a hosted changelog, because
the metadata is a claim that the destination exists and a dead link is a broken
claim.

The documentation home page SHALL be the project's introduction, so that a reader
arriving at the documentation site is given the same orientation the introduction
gives.

The package SHALL NOT declare suppression for credential scanning over paths the
package does not ship. Suppression exists to keep deliberate test fixtures and
certs out of the scan report; with none such shipped, declaring it would be a
statement that the package contains credentials.

#### Scenario: Person browses the package page

- **WHEN** a person looks up the package on Hex
- **THEN** a description of what the library does and its licence are shown, and a
  link leads to the project's source repository

#### Scenario: Reader follows a source link from the documentation

- **WHEN** a reader follows a source link for a module or function in the published
  documentation
- **THEN** the link resolves to that module's or function's source in the project's
  repository

#### Scenario: Reader arrives at the documentation site

- **WHEN** a reader opens the published documentation
- **THEN** the home page is the project's introduction, including its installation
  and quick-start content

#### Scenario: Declared links are checked against what the project maintains

- **WHEN** the package's declared links are compared against the project's
  repository
- **THEN** every declared link has a corresponding location that exists, and no link
  is declared for a location the project does not host

#### Scenario: Credential scanning is not suppressed

- **WHEN** the package's metadata is inspected
- **THEN** no path is excluded from credential scanning, because the package ships
  no credentials, test fixtures, or certificates that would need excluding

### Requirement: Published package documentation

The library SHALL publish documentation to its documentation host alongside the
package, and that documentation SHALL be built from the sources in the release it
describes. Documentation describing code that was not shipped would send a reader
to functions the installed version does not have.

The documentation build SHALL be runnable from a clean checkout through the standard
Mix documentation task, so that a publisher verifies the documentation locally
before releasing instead of relying on the publishing service to report a broken
build afterwards.

The documentation tooling SHALL NOT be a runtime dependency of the library, so that a
host's compiled release does not carry a tool the host never calls.

The project SHALL state its release procedure in the repository, including how to
inspect the built package's file list before publishing, so that the manifest
requirement above is checked by a repeatable step rather than by inspection at the
moment of release.

#### Scenario: Publisher verifies documentation before releasing

- **WHEN** a publisher builds the documentation from a clean checkout
- **THEN** the documentation task completes successfully and produces a local site
  containing the library's modules and the introduction as its home page

#### Scenario: Documentation is published with the package

- **WHEN** the package is published to Hex
- **THEN** the documentation for that exact version is available on the
  documentation host without the publisher taking a separate manual step

#### Scenario: Host is not burdened by the documentation tooling

- **WHEN** a host application depends on the library
- **THEN** the documentation tooling is absent from the host's runtime dependency
  tree and from the host's release

#### Scenario: Publisher inspects the built package before publishing

- **WHEN** a publisher follows the documented release procedure
- **THEN** the procedure includes building the package, listing the files it contains,
  and confirming the priv directory's migration files are among them, before the
  publishing step is run

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

### Requirement: Node name capture is configurable

The system SHALL record the node name on every row without requiring any
configuration, and SHALL accept a handler option that turns that capture off.
The option SHALL be a boolean and SHALL default to enabled.

Disabling the option SHALL stop the value from being recorded; it SHALL NOT change
the table's shape. The column SHALL exist either way and record no value when
capture is disabled, so a host that turns the option off and back on does not
require a schema migration to do so.

An option value that is present but not a boolean SHALL cause registration to fail
with an error naming that option, rather than being treated as either enabled or
disabled.

The node name SHALL be read from the running system, not from the event's
metadata. A metadata key named `node` SHALL therefore remain user-supplied data
and SHALL continue to appear in the row's metadata map, unchanged from before
this option existed.

#### Scenario: Node name is recorded without configuration

- **WHEN** a host registers the handler with no node-related option
- **THEN** every row written on a distributed node carries that node's name

#### Scenario: Capture is disabled by option

- **WHEN** a host registers the handler with node capture turned off
- **THEN** rows are written with no value in the node field, and the node field
  continues to exist on the table

#### Scenario: Capture is re-enabled without a schema migration

- **WHEN** a host registers the handler with capture disabled, then later with it
  enabled again
- **THEN** rows carry the node name again, with no migration run in between

#### Scenario: Option value is not a boolean

- **WHEN** a host registers the handler with the node-capture option set to a
  non-boolean value
- **THEN** registration returns an error identifying that option

#### Scenario: Metadata supplies its own node key

- **WHEN** an event carries user metadata with a key named `node`
- **THEN** that key and value appear in the row's metadata map as user-supplied
  data, and do not affect the row's node field
