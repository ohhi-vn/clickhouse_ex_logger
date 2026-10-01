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
