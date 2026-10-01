# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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

### Requirement: ClickHouse table contract

The system SHALL define a table, named `logs` in the configured database, whose
columns correspond to the row shape described by the event-to-row mapping
requirement: identifier, timestamp, level, message, module, file, line, function,
node, and metadata. The table SHALL be backed by a ClickHouse engine suitable for
append-only time-series data, ordered by timestamp so that time-range queries
prune parts efficiently.

The system SHALL provide the host application a single migration command that
creates the database and the table, and SHALL NOT create or alter ClickHouse
schema on its own at application boot.

The command SHALL be provided by this library rather than delegated to the
data layer's generic migration task, because that task discovers resources by
scanning the current project's modules and therefore never sees a resource owned
by a dependency.

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
migration command before resuming logging after such an upgrade, and the failure
SHALL be handled per the failure-handling requirement until it does.

#### Scenario: Host creates schema before shipping logs

- **WHEN** a host application runs the migration command this library provides
- **THEN** the `logs` table exists with the documented columns and engine, and
  events written afterwards are readable from it

#### Scenario: Migration is idempotent

- **WHEN** a host application runs the migration command more than once
- **THEN** the command reports the schema as up to date and changes nothing

#### Scenario: Application boot does not touch schema

- **WHEN** an application starts with the handler installed
- **THEN** no table or database is created or altered as part of starting up

#### Scenario: Configured credentials are absent

- **WHEN** the system is configured without a reachable ClickHouse URL or the
  target database does not exist
- **THEN** delivery failures are handled per the failure-handling requirement,
  and the reported reason names the connection or database problem

#### Scenario: Fresh database gets every documented column

- **WHEN** the migration command runs against a database that does not yet exist
- **THEN** the created table has the node column alongside the other documented
  columns, and it is usable without a further migration

#### Scenario: Existing database receives the new column

- **WHEN** the migration command runs against a database whose table was created
  before the node column existed
- **THEN** the node column is added, the rows already present are retained, and
  no existing column changes

#### Scenario: Adding the column again changes nothing

- **WHEN** the migration command runs more than once against a database that
  already has the node column
- **THEN** it reports the schema as up to date and alters nothing

#### Scenario: Upgraded host has not yet migrated

- **WHEN** a host runs a library version that writes the node column against a
  database that does not have it, and has not run the migration command
- **THEN** the writes are rejected by ClickHouse, the failure is reported and
  counted as lost per the failure-handling requirement, and the reported reason
  names the missing column