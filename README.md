# ClickhouseExLogger

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
  [{:clickhouse_ex_logger, "~> 0.1.0"}]
end
```

## Setup

**1. Configure the connection.**

```elixir
# config/runtime.exs
config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  username: System.get_env("CLICKHOUSE_USER", "default"),
  password: System.get_env("CLICKHOUSE_PASSWORD", ""),
  database: "my_app"
```

That key is required, and a missing one is an error rather than a default:

```
** (AshClickhouse.Error.ConfigurationError) ClickhouseExLogger.Repo is not configured.
```

Without the check it would fall back to `http://localhost:8123` and quietly
write your logs somewhere you did not choose — or report every flush as failed,
which looks like a ClickHouse outage rather than a configuration mistake.

**2. Create the schema.** Run this from your application *before* you attach the
handler, so the first flush has somewhere to go.

```sh
mix clickhouse_ex_logger.migrate
```

It creates the database if it is missing and the `logs` table if it is not, and
is safe to re-run. To see what it would do without changing anything:

```sh
mix clickhouse_ex_logger.migrate --dry-run
```

In a release — where there is no Mix and no `mix` on the machine — call the same
operation instead:

```sh
bin/my_app eval "ClickhouseExLogger.Utils.migrate()"
bin/my_app eval "ClickhouseExLogger.Utils.migrate(dry_run: true)"
```

Both do exactly the same thing: same migrations, same files shipped in
`priv/repo/migrations`, same connection configuration. Run either *before* the
new version starts logging.

> **Upgrading an existing deployment? Run this again.** A later version of this
> library writes a `node` column that tables created by an earlier version do not
> have, and ClickHouse rejects the whole batch — `No such column node in table`.
> Nothing raises in your application; the rows are simply counted as `lost`. So
> run this command as part of the deploy, *before* the new version starts
> logging. The command is the same one you already run; you just have to run it
> again — `mix clickhouse_ex_logger.migrate` from a checkout, or
> `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"` from a release.

> Use this task, not `mix ash_clickhouse.migrate`. That task finds AshClickhouse
> resources by listing the modules of the *current* project, so it never sees
> `ClickhouseExLogger.LogEntry` — that resource belongs to this dependency.

**3. Add the repo to your supervision tree, then install the handler.** Order
matters: before the repo is up, early flushes fail and are counted. That is safe
but noisy.

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClickhouseExLogger.Repo,
      MyAppWeb
      # ...
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor) do
      :ok = ClickhouseExLogger.Handler.install(:clickhouse_ex_logger, batch_size: 500)
      {:ok, pid}
    end
  end
end
```

`Handler.install/2` registers the `:logger` handler and starts the batching
buffer. `Handler.uninstall/1` removes the handler and flushes what is still
buffered, so call it from your shutdown path if you have one:

```elixir
ClickhouseExLogger.Handler.uninstall(:clickhouse_ex_logger)
```

### Declarative registration

You can also register through `:logger` directly:

```elixir
config :my_app, :logger,
  handler: [
    {:handler, :clickhouse_ex_logger, ClickhouseExLogger.Handler,
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
| `:include_node` | `true` | Record the node name on each row. See [below](#node-tells-you-which-machine). |

`:batch_size` is a **trigger, not a cap**: a write always takes everything
buffered, so a slow write lets rows accumulate rather than leaving a remainder
behind.

A value that is not a positive integer fails `install/2` with an error naming the
option, rather than failing later during delivery. A non-boolean `:include_node`
fails the same way.

`:include_node` is a *handler* option rather than a batching one, so it does not
appear in `Buffer.options()`.

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
| `node` | `Nullable(String)` | Node that handled the event, or `NULL` |

### `node` tells you which machine

Every row records the node that handled it — `my_app@10.0.0.5`, the full name, so
two applications sharing a host stay distinguishable. That is what makes
`WHERE node = 'my_app@10.0.0.5'` answer "which instance threw this".

It is `NULL` in two cases, and both are deliberate:

- **The system is not distributed** — a local `iex -S mix`, or the test suite,
  where the node is `:nonode@nohost`. There is no host to report, and a stored
  `nonode@nohost` is indistinguishable from a real host at a glance.
- **The host disabled capture** with `:include_node: false`.

So distributed rows are filterable in one step:

```sql
SELECT node, count() FROM logs WHERE node IS NOT NULL GROUP BY node
```

Turning the option off writes `NULL`; it does not remove the column. The schema is
the same either way, so a query written against `node` keeps working and turning
capture back on needs no migration.

`ENGINE = MergeTree()`, `ORDER BY (timestamp)` — so time-range queries prune
parts. Read rows back with plain SQL, or with Ash:

```elixir
ClickhouseExLogger.LogEntry
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

The column is `Map(String, String)`, so `ClickhouseExLogger.Event` renders every
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
ClickhouseExLogger.Buffer.stats()
#=> %{
#=>   accepted: 12_480,   # rows taken from the handler
#=>   delivered: 12_470,  # rows ClickHouse confirmed
#=>   discarded: 10,      # rows dropped because the buffer was full
#=>   lost: 0,            # rows ClickHouse did not accept, after a failed write
#=>   failed: 0,          # flushes that failed
#=>   buffered: 0,        # rows waiting right now
#=>   active?: true       # the buffer is running and accepting
#=> }
```

Read these as follows:

- **`accepted == delivered + discarded + lost`**, exactly, once nothing is in
  flight. Every row the handler accepted is accounted for. A `discarded` count
  that climbs means logging outpaces ClickHouse; a `lost` count that climbs
  means ClickHouse refused rows.
- **`discarded`** counts rows dropped oldest-first, so the buffer stays bounded.
- **`lost`** counts rows a failed write did not get accepted. One flush is
  several inserts, and the ones before a failure are already committed, so this
  is counted per row rather than per flush.
- **`failed` counts flushes, not rows.** One bad batch is one failure no matter
  how many rows it held.
- **`active?: false`** means the buffer is not running — the handler will keep
  accepting events and dropping them.

A failed write logs one error, marked so it does not become a row itself:

```
ClickhouseExLogger: dropped 500 buffered log row(s); the ClickHouse insert failed: …
```

Nothing is retried. A log pipeline that queues behind a database turns a
downstream outage into an upstream memory leak.

## Development

The suite starts its own ClickHouse, in a container, so you need a container
engine and nothing else:

```sh
podman machine start      # or start Docker Desktop
mix test
```

`test/test_helper.exs` provisions the container, waits for it, creates the
schema, and points the suite at it. There is nothing to start by hand.

If no engine is reachable, `mix test` fails and says so. It does not skip the
ClickHouse-backed tests: a suite that quietly excludes the tests proving the
pipeline survives a stalled database is worse than one that tells you it cannot
run. The four modules that need no database still pass without an engine
(`mix test test/clickhouse_ex_logger/event_test.exs` and friends).

The container is reused between runs, so only the first one pays ClickHouse's
startup. To remove it:

```sh
podman rm -f $(podman ps -q --filter ancestor=clickhouse/clickhouse-server:26.9)
```

Set `CONTAINER_ENGINE_HOST` if your engine's socket is somewhere
`testcontainer_ex` does not look — with `podman machine` this is already handled,
but the socket path moves between machines and macOS releases. `CONTAINER_ENGINE`
forces a specific engine.

### Releasing

Releasing is a deliberate, manual act. `mix hex.publish` is irreversible in
practice: the name is taken on hex.pm, and anyone who published can be seen doing
so. Authenticate once with `mix hex.user auth`.

Run these in order. Each one catches something the next would otherwise ship.

```sh
mix test --cover      # 204 tests; lib/ is gated at 90% line coverage
mix docs              # must build with no warnings — Hex rebuilds this on publish
mix hex.build         # writes clickhouse_ex_logger-<version>.tar
```

Then read the file list `mix hex.build` prints, and confirm the two shipped
migrations are in it:

```
priv/repo/migrations/20260101000000_create_logs.exs
priv/repo/migrations/20261001000000_add_node_to_logs.exs
```

This is the step that matters most. `mix clickhouse_ex_logger.migrate` resolves its
migrations through `:code.priv_dir/1`, so a release whose manifest omits `priv`
installs cleanly, compiles cleanly, and then raises `{:error, :bad_name}` the first
time a host runs the migration — the one step every host must run before it can log
anything. `test/mix_project_test.exs` asserts the manifest covers what `lib/`
resolves, so `mix test` already fails if that regresses.

Push the tag before publishing, not after. The published documentation points its
per-module source links at `v<version>`, so the tag has to exist when Hex builds
the docs:

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin main --tags
mix hex.publish
```

To publish documentation for a version already on hex.pm without republishing the
package, use `mix hex.publish docs`. A release can be withdrawn for one hour after
publication with `mix hex.publish --revert VERSION`.

## A note on `ash_clickhouse`

This library pins `ash_clickhouse ~> 0.7`. In 0.7.3 the data layer's
`Ash.bulk_create/4` cannot write to ClickHouse — it leaks Ash's internal bulk
options into the client option list, which the client rejects, and its
`DateTime64` encoding overflows. `ClickhouseExLogger.Insert` works around both
using the data layer's own public building blocks, so the resource stays the
single source of truth for the table and its encoding.

The workaround lives in one module and its docs name both defects. When
upstream fixes them, `ClickhouseExLogger.Insert` collapses to
`Ash.bulk_create/4` with no behavioural change. See
`ClickhouseExLogger.Insert`.

## License

Apache-2.0. See [LICENSE](LICENSE).