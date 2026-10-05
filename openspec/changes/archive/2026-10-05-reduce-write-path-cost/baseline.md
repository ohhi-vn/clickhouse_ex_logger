# Baseline and result measurements

Numbers for the cost work in this change, measured **on the implementation machine**
so that before and after are comparable. The figures in proposal.md and design.md
were taken during planning on a different run and are used there only to rank costs;
the budget is derived from the numbers here.

## How to reproduce

Run from the repository root with the suite's ClickHouse available:

    mix run --no-start /tmp/measure.exs

Machine this was measured on: darwin (macOS), Elixir 1.20.4 / OTP 28,
`ash_clickhouse` 0.7.3, `clickhouse` 0.32.0.

## Method

`ClickhouseExLogger.Microbenchmark.mean_micros/2` — mean microseconds per call over
50,000 iterations after a 5,000-iteration warm-up. The mean rather than a maximum
because a single scheduling preemption on a shared CI runner costs far more than
the work being measured; see the helper's moduledoc.

Two event shapes, because the cost is not uniform across them:

  * **scalar** — source location plus metadata whose values are a binary, an integer
    and an atom. The common shape.
  * **compound** — the same, plus one metadata value that is a map, which forces the
    `inspect/1` rendering the spec requires for round-trippable compound values.

## Before

| Measurement | us/op |
| --- | --- |
| `Event.row/2`, scalar metadata | 2.55 |
| `Event.row/2`, compound metadata | 3.78 |
| `Insert.normalize/1`, per row | 1.11 |

Harness floor: `mean_micros` of `:erlang.phash2/2`, a function cheap enough to be
almost entirely call overhead, measured **0.02 us**. The measurement apparatus
therefore contributes about 0.02 us to every figure above, which is under 1% of the
caller path and not worth subtracting.

These reproduce the planning figures (2.53 / 3.80 / 1.06) to within 5%, which is the
consistency the averaging method is meant to give. They are the before half of a
same-run pair, which is what the budget is derived from.

The recoverable items design.md identifies account for roughly 0.83 us of the
caller path: 0.51 us of source-location strings and 0.32 us of `metadata/1`
traversal.

## After

Same machine, same harness, same method as the table above.

| Measurement | before | after | change |
| --- | --- | --- | --- |
| `Event.row/2`, scalar metadata | 2.55 | 1.50 | **−41%** |
| `Event.row/2`, compound metadata | 3.78 | 2.59 | **−31%** |
| `Handler.log/2` callback, live cast | 3.72 | 2.26 | **−39%** |
| `Insert.insert/1`, 500-row batch | 1475 | 1421 | **−3.7%** |

The caller path came in better than design.md's ~0.83us estimate: the recovered
amount was ~1.05us. Removing the `Map.drop`/`Map.merge`/`Map.new` chain turned out to
be worth more than the isolated draft suggested, because the chain also allocated two
intermediate maps per event.

The batch path came in **considerably worse than predicted, and this is the honest
result**: ~54us per 500-row batch, not the ~350us the design implied. Two reasons,
both worth recording:

  * A `Map.fetch/2` of a ten-key map is not much cheaper than `to_string/1` on a short
    atom. The precomputed names remove the string *conversion*, but they replace it
    with a lookup, and the saving is correspondingly small.
  * The data layer's own twenty `to_string/1` calls per row — two per field, in
    `build_insert_rows/2` — are untouched and are the larger share of what remains.
    That is decision 3's deliberate trade: removing them means restating the column
    list and the value encoding independently of the resource.

An isolated measurement of the normalisation step alone showed **no** improvement
(1.11us before, 1.15us after). Taken alone that would say the change did nothing; what
the end-to-end `Insert.insert/1` numbers show is a small real gain plus a large
reduction in run-to-run spread (before: min 1465, max 2612; after: min 1414, max
1447). The honest summary is that this half of the change is worth about 4%, not the
double digits its framing in the proposal implied.

### A bug this measurement caught

The first implementation bound the field names *inside* the row mapping's capture —
`&normalize(&1, row_field_names(resource))` — which reads as equivalent and is not:
the capture is re-evaluated per row, so the resource's attribute list was walked once
per row instead of once per batch. That made the batch path **10% slower** than
before the change (1626us against 1483us). The end-to-end measurement is what surfaced
it; the isolated normalisation measurement had shown a merely disappointing number
rather than an inverted one, and would not have caught it.

The fix is to bind `field_names` before the `Enum.map/2`, and both the code and its
comment now say why, since the shorter form is the one that reads naturally.

### Budgets

Derived from these measurements, and both verified to fail against the pre-change code
(see `test/clickhouse_ex_logger/cost_test.exs`):

| Budget | Value | Guards |
| --- | --- | --- |
| Mapping (`Event.row/2`) | 1.9us | tight; catches either optimisation being undone |
| Callback (`Handler.log/2`) | 3.0us | loose; catches a gross failure |

The mapping budget is the sensitive one because it is the stable measurement (4%
spread against the callback's ~15%), and it is where both optimisations live. Verified
to fail at 2.53us against the pre-change mapping, and at 2.19us with only the
source-location cache disabled — the partial regression the loose callback budget
would have missed.

**On the headroom being loosened** (task 5.4 asks for this to be recorded; no commit was
made, so it is recorded here). The callback budget was first set at 2.7us from an
isolated calibration run, and that proved wrong twice over: one measurement reached
2.73us, and a later one 2.49us — a spread the isolated runs had not shown, because they
were taken with less going on around them. Rather than pick the largest number observed
and call it a day, the budget was split into the two above: tight on the mapping, which
measures stably and is where the change lives, and loose on the callback, which
includes a message copy and a third more noise. That keeps the sensitivity the 2.7us
figure was chosen for — it still fails a pre-change regression and a half-regression —
without setting a threshold that a slower machine would trip.

The full suite was then run three times end to end: 298 tests, no flakes.

The `@max_call_micros` ceiling in `workload_test.exs` moved from 50,000 to 2,000,000.
It is a *maximum* over 3200 calls under 8-way contention, where repeated runs measured
1049–5114us with every producer uniformly slow in the slower runs — machine noise, not
a per-call stall. A blocked caller would show the client's 15s `recv_timeout`.