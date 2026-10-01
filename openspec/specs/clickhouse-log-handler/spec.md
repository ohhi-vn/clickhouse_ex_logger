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

#### Scenario: Handler attaches successfully

- **WHEN** a caller registers the handler with a valid handler id and options
- **THEN** the system returns `{:ok, handler_id}` and subsequent `Logger` calls
  at or above the configured level reach the handler

#### Scenario: Handler is removed with events still buffered

- **WHEN** the handler is removed while the system holds buffered events
- **THEN** the system flushes the remaining buffered events before returning, so
  that removal does not discard logs already accepted

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
calling library supplied one. Rows SHALL carry a unique identifier and SHALL
preserve every piece of user-supplied log metadata as string key/value pairs.
Metadata values that are not natively representable as strings SHALL be
rendered in a documented, deterministic textual form rather than dropped.

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
accepted, delivered, discarded, and failed events observable to operators.

#### Scenario: ClickHouse is unreachable

- **WHEN** a flush fails because ClickHouse is unavailable
- **THEN** the events from that batch are discarded, one error describing the
  failure is reported through the logger, the failed-event counter increases,
  and the application continues to run

#### Scenario: The handler's own error report is not fed back into itself

- **WHEN** the handler reports an insert failure through the logger
- **THEN** that report does not result in a row being written for itself, and
  the failure counter does not increase again as a result

#### Scenario: Operator inspects handler state

- **WHEN** an operator queries the handler for its current statistics
- **THEN** the counts of accepted, delivered, discarded, and failed events since
  the handler started, plus whether the handler is currently active, are
  returned

### Requirement: ClickHouse table contract

The system SHALL define a table, named `logs` in the configured database, whose
columns correspond to the row shape described by the event-to-row mapping
requirement: identifier, timestamp, level, message, module, file, line, function,
and metadata. The table SHALL be backed by a ClickHouse engine suitable for
append-only time-series data, ordered by timestamp so that time-range queries
prune parts efficiently.

The system SHALL provide the host application a single migration command that
creates the database and the table, and SHALL NOT create or alter ClickHouse
schema on its own at application boot.

The command SHALL be provided by this library rather than delegated to the
data layer's generic migration task, because that task discovers resources by
scanning the current project's modules and therefore never sees a resource owned
by a dependency.

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
