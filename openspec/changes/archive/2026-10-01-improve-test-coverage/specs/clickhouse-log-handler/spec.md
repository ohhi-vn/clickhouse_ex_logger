# Spec Delta

## Purpose

Narrows one guarantee in *"Event-to-row mapping"*: mapping an event to a row
must not raise, whatever the event's message field contains.

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
