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

Registration SHALL be all-or-nothing. When registration fails for any reason —
including a configuration option the underlying logging system itself rejects —
the system SHALL leave nothing running that it started, so that a rejected
registration does not leave batching machinery attached to no handler. Nothing
already running before the attempt SHALL be torn down by a failed registration.

A bounded flush that reaches its timeout without draining SHALL NOT be reported
to its caller as a completed flush. The caller SHALL be able to distinguish
"the buffer is empty and nothing is in flight" from "the bound was reached with
events still held", because only the first means removal can proceed to stop the
buffer without discarding events that were accepted.

#### Scenario: Handler attaches successfully

- **WHEN** a caller registers the handler with a valid handler id and options
- **THEN** the system returns `{:ok, handler_id}` and subsequent `Logger` calls
  at or above the configured level reach the handler

#### Scenario: Registration fails and leaves nothing running

- **WHEN** a caller registers the handler and registration fails after the system
  would otherwise have started its batching machinery
- **THEN** registration returns the failure and no batching machinery it started
  is left running, so a later registration starts from a clean state

#### Scenario: Failed registration leaves a pre-existing buffer alone

- **WHEN** batching machinery was already running before a registration attempt,
  and that registration fails
- **THEN** the already-running machinery is left untouched, because the failed
  attempt did not start it

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

#### Scenario: Removal reports that the bound was reached

- **WHEN** removal is requested and the flush cannot drain within its bound
- **THEN** removal is told the buffer did not drain, rather than being told the
  flush succeeded, so accepted events are accounted for rather than discarded in
  silence

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

Every option the system accepts SHALL be validated at registration. An option
that is present but holds a value the system or the underlying logging system
cannot honour SHALL cause registration to fail with an error naming that option,
on the same terms as a non-positive integer, rather than being accepted and then
misbehaving during event delivery.

Registration SHALL reject a configuration whose batch size exceeds its maximum
buffer size. With the batch size above the maximum, the queue is capped below the
batch size, the size trigger can never fire, and events are discarded for a reason
the host did not cause — which is indistinguishable, in the discarded count, from
ClickHouse being too slow. A host that genuinely wants a batch no larger than its
maximum configures them equal, which the system SHALL accept.

#### Scenario: Configuration omitted entirely

- **WHEN** the handler is registered with no batching options
- **THEN** the system applies the documented defaults and continues to accept
  and deliver events

#### Scenario: Configuration contains an invalid value

- **WHEN** the handler is registered with a negative batch size, a zero flush
  interval, or a non-integer value
- **THEN** registration returns an error identifying the offending option

#### Scenario: Minimum level is not a level the logging system accepts

- **WHEN** the handler is registered with a minimum level that is not a level the
  underlying logging system recognises
- **THEN** registration returns an error identifying that option, rather than
  passing an uninterpretable level through to the logging system

#### Scenario: Batch size exceeds the maximum buffer size

- **WHEN** the handler is registered with a batch size greater than the maximum
  buffer size
- **THEN** registration returns an error identifying the offending option, so the
  host does not silently discard events the size trigger could never have written

#### Scenario: Batch size equals the maximum buffer size

- **WHEN** the handler is registered with a batch size equal to the maximum buffer
  size
- **THEN** registration succeeds and the size trigger remains reachable

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

User-supplied metadata SHALL be read from the event on the same terms as every
other event field. Depending on the runtime version, an event carries its metadata
either nested or at the top level; both shapes SHALL yield the same row, so that
an event's metadata is never lost to which shape the runtime produced.

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

That total behaviour SHALL extend to every field the mapping reads, not only the
message. A source-location value the system cannot render — a file path carrying
an invalid code point, a list that is not well-formed, a value that is not text at
all — SHALL be rendered in a deterministic textual form rather than raising, and
that row SHALL be buffered and counted like any other.

A source location that is absent SHALL be recorded as no value. A field that
carries no module SHALL NOT be recorded as a string that spells the absence, so
that a query testing for rows with no module finds exactly those rows.

#### Scenario: Event carries source location

- **WHEN** an event includes module, file, line, and function information
- **THEN** the resulting row records all four values as written

#### Scenario: Event has no source location

- **WHEN** an event originates from a call that supplied no module, file, line,
  or function
- **THEN** the row records these as empty rather than failing to be written, and a
  query testing for rows with no module finds those rows

#### Scenario: Source location carries an invalid code point

- **WHEN** an event's file field carries a code point that is not a valid
  character, such as a surrogate
- **THEN** the mapping returns a row with that field in a deterministic textual
  form, and does not raise

#### Scenario: Source location is not a well-formed list

- **WHEN** an event's file field is a list that is neither valid character data
  nor valid report data, such as an improper list
- **THEN** the mapping returns a row with that field in a deterministic textual
  form, and does not raise

#### Scenario: Event carries structured metadata

- **WHEN** an event carries metadata such as `user_id` and `request_id`
- **THEN** every metadata key and value appears on the row, with values rendered
  as strings

#### Scenario: Metadata is carried at the top level of the event

- **WHEN** an event carries its metadata as top-level keys rather than nested
  under a metadata key
- **THEN** those keys and values appear on the row exactly as they would for a
  nested event of the same content

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

At most one write SHALL be outstanding at any moment, including while the system
is shutting down. Successive writes SHALL therefore remain ordered all the way
to the end of the system's life, not only while it is running normally.

The system SHALL recover from a write that fails without producing a result. A
write is performed on a separate process, and that process may die — because the
client library raised an exception the connection layer did not recognise, for
instance — without ever reporting an outcome. In that case the system SHALL treat
the whole batch as lost, count it as lost, report the failure once, and resume
delivering subsequent events. Liveness of the buffer SHALL NOT depend on a write
completing successfully: a write that never reports SHALL NOT prevent later events
from being written, and the system SHALL NOT continue to report itself active
while delivering nothing.

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

#### Scenario: A write dies without reporting an outcome

- **WHEN** a batch is being written and the process performing the write dies
  without reporting success or failure
- **THEN** the system counts the batch as lost, reports the failure once through
  the logger, and continues to accept and deliver events logged afterwards

#### Scenario: The system keeps working after a write dies

- **WHEN** a write has died without reporting an outcome and further events are
  logged
- **THEN** those events are delivered to ClickHouse rather than accumulating
  undelivered in the buffer indefinitely

#### Scenario: Shutdown does not run two writes at once

- **WHEN** the system shuts down while a write is still outstanding and more events
  are buffered
- **THEN** the buffered events are written by that outstanding write or not at
  all, and no second write runs alongside it
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

That reconciliation SHALL hold for a batch whose write died without reporting an
outcome, and SHALL hold once nothing is in flight. A row the system accepted and
could not account for is a row an operator cannot reason about, so no path that
loses rows may leave them unaccounted.

The reason the system reports for a failed write SHALL name the problem the
server or the client reported. A failure SHALL NOT be reported as an opaque
inspection of an internal data structure, because an operator reading it cannot
then tell a connection failure from a rejected statement.

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

#### Scenario: A write that died is accounted at row level

- **WHEN** a batch is lost because the write died without reporting an outcome,
  and nothing is in flight afterwards
- **THEN** every row of that batch is counted as lost, so subtracting delivered,
  discarded, and lost from accepted leaves zero

#### Scenario: The reported failure names the problem

- **WHEN** a write fails and the system reports the failure through the logger
- **THEN** the reported reason is the message the server or client supplied, so an
  operator can tell a connection failure from a rejected statement

#### Scenario: The handler's own error report is not fed back into itself

- **WHEN** the handler reports an insert failure through the logger
- **THEN** that report does not result in a row being written for itself, and
  the failure counter does not increase again as a result

#### Scenario: The self-feeding guard holds on either event shape

- **WHEN** the handler's own error report reaches it on an event whose metadata is
  carried at the top level rather than nested
- **THEN** the report is still recognised as the system's own and does not result
  in a row being written for itself

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

#### Scenario: Operator is not told a busy system is idle

- **WHEN** an operator queries statistics while the system is delivering events
  and the query cannot be served
- **THEN** the system does not report zeroed counts as though the system were not
  running, because zeroed counts with an inactive marker are indistinguishable
  from a system that never started
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

Neither entry point SHALL raise where it reports failure. A configuration the
system cannot honour — a database name the server would not accept — SHALL
return a diagnosable failure naming the problem, so that both entry points can
present it as the actionable guidance they document, rather than surfacing an
exception the host has to interpret itself.

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

#### Scenario: Entry point reports a database name the server would reject

- **WHEN** a host runs either migration entry point with a configured database
  name the server would not accept as an identifier
- **THEN** the call returns a diagnosable failure naming that option, rather than
  raising, so the host is told which configuration value to change

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

### Requirement: Bounded cost added to a logging call

The system SHALL bound the processor time it adds to a logging call, measured from
entry to the handler callback to its return. The bound SHALL be stated as a per-event
budget and SHALL hold as an average over a run of at least ten thousand events, so
that ordinary scheduling variation cannot account for the result either way.

The budget SHALL cover only the work this system performs. It SHALL NOT be satisfied
by work performed on the host's behalf by the logging system itself, or by any other
handler the host has installed, because the host owns the cost of those and this
system cannot reduce it.

This bound is what makes the promise that a logging call never blocks meaningful. A
call that does not wait on ClickHouse can still be arbitrarily expensive to make, and
a host that finds logging too slow eventually turns it off — which loses the logs
rather than slowing the application, and is a worse outcome than either.

#### Scenario: A single logging call stays within the per-event budget

- **WHEN** the process that logs an event is measured across a run of at least ten
  thousand events carrying source location and metadata
- **THEN** the average processor time the handler adds to each call is at or below
  the stated per-event budget

#### Scenario: The bound does not depend on how many events are logged

- **WHEN** the same measurement is taken under a sustained rate rather than a single
  event
- **THEN** the average added cost per event remains at or below the same budget, so
  the cost of shipping a log does not grow with volume

#### Scenario: Cost is measured for this system's work only

- **WHEN** the budget is evaluated
- **THEN** the measurement spans the handler callback alone, and a host running
  additional handlers or an expensive formatter is not charged for their cost against
  this budget

### Requirement: Work that depends only on the source location is not repeated per event

The system SHALL NOT, for each accepted event, re-derive a value whose result is
fully determined by the event's source location. A value that varies only across the
set of distinct call sites in the running system SHALL be derived once per distinct
value and reused for subsequent events reporting that value.

Rendering the calling module and the calling function is the motivating case. In a
running system the set of call sites that log is small and fixed, while the number of
events they log is not, so deriving these per event repeats identical work once per
logged line.

The system SHALL reuse a derived value without changing what the row records: a row
for an event that reuses a previously derived value SHALL be indistinguishable from
one that derived it again, on every field the derivation feeds.

#### Scenario: Repeated events from one call site record the same values

- **WHEN** many events are logged from a single call site
- **THEN** every resulting row records the same module and function values, exactly
  as it would if each were derived independently

#### Scenario: Distinct call sites are not conflated

- **WHEN** events are logged from two different call sites, or from the same module
  at different lines or arities
- **THEN** each row records the values belonging to its own call site, and no value
  derived for one call site is reported for another

#### Scenario: Reuse does not outlive a change of value

- **WHEN** a source location's derived value would differ from the previously derived
  value for that location
- **THEN** the new value is recorded, so reuse can never report a stale value

### Requirement: A batch's field names are converted to wire form once per batch

When the system encodes a batch for delivery, it SHALL convert the row field names to
their wire form once for the batch rather than once per row. The field names of a
batch are fixed by the table the rows target, so converting them per row repeats work
whose result is identical for every row in the batch.

The system SHALL continue to take the field names, their order, and the value
encoding from the resource that defines the table, so that the wire format cannot
drift from the table definition.

#### Scenario: Field names are converted once for a batch

- **WHEN** a batch of many rows is encoded for delivery
- **THEN** each field name is converted to its wire form once for the batch rather
  than once per row, so the cost of conversion does not grow with the number of rows

#### Scenario: Wire format still derives from the table definition

- **WHEN** the table's resource changes a field's name, order or encoding
- **THEN** rows are encoded according to the changed definition, because the wire form
  is read from the resource rather than restated independently of it

#### Scenario: Every row still carries every column

- **WHEN** a batch is encoded
- **THEN** each row carries a value for every column the table defines, in the order
  the table defines them, and a row missing a value is still encoded rather than
  dropped

### Requirement: Configured credentials reach the server

The system SHALL authenticate to ClickHouse with the credentials the host
configures. It SHALL do so by placing them where the connection stack honours
them — in the URL the requests carry — because no layer beneath it accepts a
credential of its own, and SHALL do so internally rather than requiring the host
to compose the URL. A host that configures a username and password SHALL NOT have
to write URL-manipulation code to authenticate.

Credentials SHALL be composed into the URL by percent-encoding each value, so a
password containing characters that are meaningful in a URL — `@`, `:`, `/`, a
space — SHALL be transmitted as that password rather than altering the URL's
host, port, or path. A username or password carrying a non-ASCII character SHALL
be transmitted as that character.

A configured username with no password SHALL authenticate as that user with an
empty password, rather than falling back to the server's own default user. The
system SHALL NOT treat a passwordless configuration as a request to send no
credentials at all: on a server whose default user is protected, sending none is
how a host is silently authenticated as the wrong identity.

The system SHALL NOT alter a URL that already carries a userinfo. A host pointing
`CLICKHOUSE_URL` at a server whose URL embeds its own credentials SHALL have that
URL used verbatim, so that the credentials already in the URL win over the
separate username and password options and are not parsed, overridden, or
doubled.

The system SHALL send no credential header at all when no credential is
configured, so that a password-less local server is not sent an
authentication the host did not ask for.

Every connection the system opens — the supervised one, the one the migration
entry points open, and the one they open with no database bound — SHALL be
authenticated the same way from the same configuration. A host SHALL NOT be able
to migrate against a server its logging cannot reach, or reach it the other way
round.

The composed URL SHALL NOT be reported anywhere the host did not ask for it. It
SHALL NOT be written to a log, an error message, or reported statistics, because
it carries the password in recoverable form, and this system reports its own
failures through the logger it is logging to.

An option that is present but holds a value the system cannot use — a username or
password that is not a string, a URL that is not a URL — SHALL cause the
connection's configuration to fail with an error naming that option, rather than
being silently ignored or producing a request the server rejects much later with
a reason the host cannot connect to their configuration.

#### Scenario: Password-protected server accepts the configured credentials

- **WHEN** a host configures a username and a password for a ClickHouse server
  that requires them, and delivers an event
- **THEN** the request carries those credentials as HTTP basic authentication, and
  the server accepts it rather than answering with an authentication failure

#### Scenario: Password contains characters that are meaningful in a URL

- **WHEN** a host configures a password containing `@`, `:`, `/`, or a space
- **THEN** the request authenticates as that password, and the request still
  reaches the configured host and port rather than a host or path derived from
  the password

#### Scenario: Password contains a non-ASCII character

- **WHEN** a host configures a username or password containing a non-ASCII
  character
- **THEN** the server receives that exact character as the credential, not a
  percent-escaped or mangled form of it

#### Scenario: Username with no password

- **WHEN** a host configures a username and leaves the password empty, against a
  server where that user has no password
- **THEN** the request authenticates as that username rather than as the
  server's default user

#### Scenario: URL already carries its own credentials

- **WHEN** a host configures a URL whose userinfo holds credentials, and also
  configures a separate username and password
- **THEN** the request uses the URL exactly as configured, and the separate
  username and password have no effect on it

#### Scenario: No credentials configured

- **WHEN** a host configures only a URL, with no username and no password
- **THEN** the request carries no authentication header, so a password-less local
  server is not sent credentials the host did not configure

#### Scenario: Migration entry point authenticates identically

- **WHEN** a host runs the migration entry point against a password-protected
  server, including from a release
- **THEN** the migration's connections authenticate with the configured
  credentials, and it succeeds rather than failing with an authentication failure

#### Scenario: Composed URL is not reported

- **WHEN** the system composes a credentialed URL and then reports a failure
  through the logger or reports its statistics
- **THEN** neither output contains the password or any part of the credentialed
  URL

#### Scenario: Credential value is not a string

- **WHEN** a host configures a username or a password that is not a string, such
  as a number or an atom
- **THEN** the configuration fails with an error naming that option, rather than
  dropping the credential and authenticating as the default user

#### Scenario: URL cannot be parsed

- **WHEN** a host configures a `:url` that is not a parseable URL, such as a bare
  hostname with no scheme
- **THEN** the configuration fails with an error naming `:url`, rather than
  producing a request that fails later with a reason the host cannot trace to
  their configuration
