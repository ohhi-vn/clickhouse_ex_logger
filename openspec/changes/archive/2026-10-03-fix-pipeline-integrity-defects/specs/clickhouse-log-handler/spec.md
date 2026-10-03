# Spec Delta

## MODIFIED Requirements

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
affect a host, while still leaving the host to name this library's domain itself.

Where a host's build reports that this library's domain is not among the
configured domains, the system SHALL document the configuration line that
silences it, because the setting has to be stated in the host's own
configuration and cannot be shipped from here.

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

- **WHEN** a host's build reports that this library's domain is not among the
  configured domains
- **THEN** the library's documentation states the configuration line that resolves
  it, and the line is one the host adds to its own configuration

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
- **THEN** it lists the library sources and its runtime assets, and does not list the
  test-only support sources, coverage output, or the project's change records