# Spec Delta

## ADDED Requirements

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