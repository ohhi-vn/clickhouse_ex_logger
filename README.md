# ClickhouseLogger

Ship Elixir [`Logger`](https://hexdocs.pm/logger/Logger.html) events into
ClickHouse, through [Ash](https://hexdocs.pm/ash) and
[AshClickhouse](https://hexdocs.pm/ash_clickhouse), so they land in a table you
can `SELECT` against instead of a file you have to grep.

Logging stays non-blocking: `Logger.info/1` formats a row and hands it to a
buffer process. Batches are written with one insert each. If ClickHouse is slow
or down, the oldest buffered rows are discarded and counted — your application
never blocks and never runs out of memory.

## Installation

```elixir
def deps do
  [{:clickhouse_logger, "~> 0.1.0"}]
end
```

## Setup

**1. Configure the connection.**

```elixir
# config/runtime.exs
config :clickhouse_logger, ClickhouseLogger.Repo,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  username: System.get_env("CLICKHOUSE_USER", "default"),
  password: System.get_env("CLICKHOUSE_PASSWORD", ""),
  database: "my_app"
```

**2. Create the schema.** Run this from your application *before* you attach the
handler, so the first flush has somewhere to go.

```sh
mix clickhouse_logger.migrate
```

It creates the database if it is missing and the `logs` table if it is not, and
is safe to re-run. To see what it would do without changing anything:

```sh
mix clickhouse_logger.migrate --dry-run
```

> Use this task, not `mix ash_clickhouse.migrate`. That task finds AshClickhouse
> resources by listing the modules of the *current* project, so it never sees
> `ClickhouseLogger.LogEntry` — that resource belongs to this dependency.

**3. Add the repo to your supervision tree, then install the handler.** Order
matters: before the repo is up, early flushes fail and are counted. That is safe
but noisy.

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClickhouseLogger.Repo,
      MyAppWeb
      # ...
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor) do
      :ok = ClickhouseLogger.Handler.install(:clickhouse_logger, batch_size: 500)
      {:ok, pid}
    end
  end
end
```

`Handler.install/2` registers the `:logger` handler and starts the batching
buffer. `Handler.uninstall/1` removes the handler and flushes what is still
buffered, so call it from your shutdown path if you have one:

```elixir
ClickhouseLogger.Handler.uninstall(:clickhouse_logger)
```

### Declarative registration

You can also register through `:logger` directly:

```elixir
config :my_app, :logger,
  handler: [
    {:handler, :clickhouse_logger, ClickhouseLogger.Handler,
     %{batch_size: 500, flush_interval_ms: 1_000, max_buffer_size: 10_000}}
  ]
```

then `Logger.add_handlers(:my_app)` from `Application.start/2`.

Prefer `Handler.install/2`. Declarative registration hands the config straight to
`:logger`, which neither validates it nor gives this library a hook to flush on
removal — so a typo in `:batch_size` shows up as a misbehaving buffer rather than
an error at boot, and removing the handler discards whatever was buffered.

## Configuration

All keys are optional.

| Key | Default | Meaning |
| --- | --- | --- |
| `:level` | `:all` | Minimum level to ship. `:logger` filters on this. |
| `:batch_size` | `500` | Buffered rows that trigger a write. |
| `:flush_interval_ms` | `1_000` | How often to write a partial batch. |
| `:max_buffer_size` | `10_000` | Hard cap on buffered rows. |

`:batch_size` is a **trigger, not a cap**: a write always takes everything
buffered, so a slow write lets rows accumulate rather than leaving a remainder
behind.

A value that is not a positive integer fails `install/2` with an error naming the
option, rather than failing later during delivery.

## The `logs` table

| Column | ClickHouse type | Meaning |
| --- | --- | --- |
| `id` | `UUID` | Unique identifier for the row |
| `timestamp` | `DateTime64(6)` | When the event was logged (UTC) |
| `level` | `String` | Erlang severity, e.g. `"info"` |
| `message` | `String` | The rendered log message |
| `module` | `Nullable(String)` | Calling module |
| `file` | `Nullable(String)` | Calling file |
| `line` | `Nullable(Int64)` | Calling line |
| `function` | `Nullable(String)` | Calling function/arity |
| `metadata` | `Map(String, String)` | Log metadata, values stringified |

`ENGINE = MergeTree()`, `ORDER BY (timestamp)` — so time-range queries prune
parts. Read rows back with plain SQL, or with Ash:

```elixir
ClickhouseLogger.LogEntry
|> Ash.Query.filter(level == :error)
|> Ash.Query.sort(timestamp: :desc)
|> Ash.Query.limit(20)
|> Ash.read!()
```

### Two things about `id`

It is an identifier, not a uniqueness constraint. ClickHouse deduplicates by
*sorting key*, not by primary key, so it will happily store two rows with the same
`id`. It exists so you can cross-reference a specific row.

### Metadata values are strings

The column is `Map(String, String)`, so `ClickhouseLogger.Event` renders every
value as text. Binaries pass through; other scalars go through `to_string/1`;
compound terms are stored as `inspect/1` output behind a `"term:"` marker so they
can be told apart from a genuine string and read back:

```elixir
"term:[1, 2]"
|> String.replace_prefix("term:", "")
|> Code.eval_string()
#=> {1, 2}, [1, 2]
```

Erlang's own event keys (`:mfa`, `:file`, `:line`, `:time`, …) are lifted into
their own columns and deliberately left out of the metadata map.

## Observing the pipeline

```elixir
ClickhouseLogger.Buffer.stats()
#=> %{
#=>   accepted: 12_480,   # rows taken from the handler
#=>   delivered: 12_470,  # rows ClickHouse confirmed
#=>   discarded: 10,      # rows dropped because the buffer was full
#=>   failed: 0,          # writes that failed
#=>   buffered: 0,        # rows waiting right now
#=>   active?: true       # the buffer is running and accepting
#=> }
```

Read these as follows:

- **`accepted` minus `delivered` minus `discarded`** is `failed` rows' worth of
  loss, plus anything still in flight. A `discarded` count that climbs means
  logging outpaces ClickHouse.
- **`discarded`** counts rows dropped oldest-first, so the buffer stays bounded.
- **`failed` counts flushes, not rows.** One bad batch is one failure no matter
  how many rows it held.
- **`active?: false`** means the buffer is not running — the handler will keep
  accepting events and dropping them.

A failed write logs one error, marked so it does not become a row itself:

```
ClickhouseLogger: dropped 500 buffered log row(s); the ClickHouse insert failed: …
```

Nothing is retried. A log pipeline that queues behind a database turns a
downstream outage into an upstream memory leak.

## Development

Start a ClickHouse for the test suite:

```sh
podman compose up -d      # or: docker compose up -d
mix test
```

Tests that need ClickHouse are tagged `:clickhouse`. With no server reachable
they are excluded and the suite explains why:

```
Skipping :clickhouse tests — no ClickHouse server at http://localhost:8123 — …
```

Point the suite at another server with `CLICKHOUSE_URL`,
`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_TEST_DATABASE`.

## A note on `ash_clickhouse`

This library pins `ash_clickhouse ~> 0.7`. In 0.7.3 the data layer's
`Ash.bulk_create/4` cannot write to ClickHouse — it leaks Ash's internal bulk
options into the client option list, which the client rejects, and its
`DateTime64` encoding overflows. `ClickhouseLogger.Insert` works around both
using the data layer's own public building blocks, so the resource stays the
single source of truth for the table and its encoding.

The workaround lives in one module and its docs name both defects. When
upstream fixes them, `ClickhouseLogger.Insert` collapses to
`Ash.bulk_create/4` with no behavioural change. See
`ClickhouseLogger.Insert`.

## License

Apache-2.0. See [LICENSE](LICENSE).