# Design

## Context

See `proposal.md` for why. What shapes the approach is a set of facts about the
existing code that constrain every option below.

**The connection cannot be started twice in one VM.**
`ClickHouse.Interface.HTTP.init/1` calls `:hackney_pool.start_pool/2` with a name
derived from the connection name, and the client keeps a named ETS table per
connection. A second start under the same name raises from inside the new
process, before `AshClickhouse.Connection.start_link/1` can map
`{:error, {:already_started, pid}}` to `{:ok, pid}`. `ClickhouseExLogger.Migration`
already documents this about its own bootstrap connection. It is the reason the
opt-out has to exist and the reason a host cannot be left to discover the
collision by crashing.

**The unconfigured case already fails loudly, and it fails during a child's
start.** `ClickhouseExLogger.Repo.config/0` raises
`AshClickhouse.Error.ConfigurationError` rather than defaulting, and it is
reached from `child_spec/1`, which the supervisor calls while starting the tree.
A library that supervises the connection therefore inherits that message for
free, including the "nothing is left running" property, because a supervisor that
fails to start a child terminates the ones it already started.

**Asking whether the table exists is harder than it looks.** A ClickHouse client
binds to a database for the life of the connection, so a plain statement against a
database that does not exist fails with `UNKNOWN_DATABASE` — which reads exactly
like the server being down. On a first install the database is missing too, which
is the case the check most needs to catch.

It is still answerable on the connection the library already has, because the
`database` the data layer sends is a *per-request* option. Verified against the
suite's container: a connection bound to a database that does not exist answers
`SELECT 1` with `UNKNOWN_DATABASE`, and answers the same statement with
`database: system` normally. That is the whole mechanism, and it is what the
check uses.

**The Ash warning is compile-time, in the dependency's compilation.**
`Ash.Domain`'s and `Ash.Resource`'s inclusion checks run from Spark's `verify/2`,
which reads `Application.get_env(otp_app, :ash_domains, [])` while compiling the
module. A host adding the package compiles this library's domain with no
configuration of its own, so it sees the warning. Nothing a host or this library
sets at runtime can affect it, and shipping `config/` — which is how this
repository avoids the warning for itself — is excluded from the package on
purpose.

**`mix test` starts the application before `test/test_helper.exs` runs**, and the
harness replaces the repo configuration with the container's afterwards. So an
automatic start would open a connection against the compile-time database before
the harness that provisions the real one has run.

## Goals / Non-Goals

**Goals:**

- A host that has declared the dependency and configured the connection writes no
  application code, and the pipeline is supervised rather than linked to whatever
  process happened to call `install/2`.
- One registration path, not two. Every guarantee `Handler.install/2` makes today
  holds for the automatic start because it *is* `Handler.install/2`.
- A host that has not created the schema is told so in words, at boot, rather than
  discovering it later as a rising `lost` count.
- Shutdown order stays the one the specs require: handler off, then bounded
  drain, then connection closed.

**Non-Goals:**

- Not reducing the number of configuration *keys*. The connection block is four
  keys and each one is a real destination fact; folding them into a connection
  string would mean parsing URL userinfo the client does not parse, to save three
  lines.
- Not reading `CLICKHOUSE_URL` and friends from the environment. The existing
  specification deliberately refuses to let this library choose a destination on
  the host's behalf, and an implicit environment read is that choice with extra
  steps.
- Not auto-migrating at boot. "Boot touches no schema" is a load-bearing
  guarantee of this library, not an accident of the current design.
- Not making `mix ash_clickhouse.migrate` work, and not adding a third migration
  entry point.
- Not a configurable handler id. There is one documented id and no host has
  needed a second.

## Decisions

### The automatic start calls `Handler.install/2`; it does not become a second path

`ClickhouseExLogger.Application` reads the handler configuration, and the child
that attaches the handler calls `Handler.install/2` with it.

The alternative — an `AutoStart.install/0` with its own validation and its own
rollback — duplicates the part of `install/2` that is easiest to get subtly wrong,
and the two would drift. `install/2` already has the properties this needs:
`ensure_buffer_started/1` reuses a running buffer rather than starting a second
one, `register/2` treats `{:error, {:already_exist, id}}` as success, and the
whole thing is validated before anything starts.

This is also why the *Handler registration and lifecycle* requirement is not
modified by this change: its subject is the registration operation, and there is
still exactly one.

### The buffer is supervised; the attaching child is a `GenServer` that stays alive

The tree is:

```
ClickhouseExLogger.Repo
ClickhouseExLogger.Buffer   (started with the validated options)
ClickhouseExLogger.HandlerInstaller
```

`Buffer.start_link/1` does not validate, so `Application.start/2` validates first
— `Handler.validate/1` for the batching options and
`Handler.validate_include_node/1` for the rest — and builds the child's spec from
what those return. An invalid option therefore fails the application start, and
the supervisor unwinds the repo it already started.

The Installer does the readiness check and then calls `install/2`, which finds
the buffer already running and registers the handler without starting anything.

Supervising the buffer directly, rather than letting `install/2` start it, is what
makes it supervised at all. Left to `install/2` the buffer is linked to whichever
process called it — today the host's `Application.start/2`, and under automatic
start the Installer. A buffer crash would then take its caller down with it
instead of being restarted.

The Installer stays alive after attaching, doing nothing, so that it has a
`terminate/1`. Children terminate in reverse start order, so the sequence on
shutdown is: Installer runs `Handler.uninstall/1`, then the supervisor stops the
buffer, then the repo closes. A detached task could not honour that order.

Its `terminate/1` calls `Handler.uninstall/1` rather than reimplementing the
sequence, because that function already *is* this sequence — handler off, bounded
flush, stop the buffer — in this order, on the explicit path this library already
documents and tests.

**The buffer's own `terminate/2` does not run on a supervisor shutdown, and that
is why the drain has to happen in the Installer.** A supervisor shuts a child down
with an exit *signal*, and a process that does not trap exits dies on the spot:
the signal never becomes a mailbox message, so `{'EXIT', Parent, Reason}` never
reaches the receive loop and `terminate/2` is never called. Confirmed against
OTP directly — a bare `GenServer` with a `terminate/2` under a supervisor prints
nothing when the supervisor stops.

That was invisible while `Handler.install/2` owned the buffer's lifecycle, because
`Handler.uninstall/1` flushed explicitly before calling `GenServer.stop/3`, which
does invoke `terminate/2`. Supervising the buffer makes the supervisor's signal the
only one it gets, so without the Installer draining, every buffered row would be
dropped silently at shutdown.

The alternative considered and rejected was `Process.flag(:trap_exit, true)` in
`ClickhouseExLogger.Buffer.init/1`, which does make `terminate/2` run. It also
changes the buffer's behaviour for every existing caller, and it made eight
existing buffer tests fail on a teardown race: a trapping buffer now reacts to its
parent's exit, and those tests' `on_exit` handlers call `GenServer.stop/3` directly
and so exit when the buffer goes down as `:shutdown` instead of `:normal`. Making
a module this change did not otherwise need to touch behave differently, to serve
an ordering a sibling already implements, is the wrong trade. Rejected; the buffer
is unchanged.

### Two configuration keys, both optional

```elixir
config :clickhouse_ex_logger, handler: [level: :info, batch_size: 500]
config :clickhouse_ex_logger, auto_start: false
```

`:handler` is passed to `install/2` unchanged, so it accepts exactly the options
`install/2` already documents — `:level`, `:batch_size`, `:flush_interval_ms`,
`:max_buffer_size`, `:include_node` — and rejects them on exactly the same terms.
No new option is introduced, and the table in the README stays the single list.

`:auto_start` defaults to enabled. It exists because of the double-start
constraint in Context, and it is the answer to the one host that cannot use the
default.

The readiness check gets no switch. A host has no reason to want it off, and a
switch that disables the error message is a switch that hides the failure the
message exists to name.

### The readiness check runs in `handle_continue`, and answers three ways

The Installer's `init/1` returns `{:ok, state, {:continue, :attach}}` and does the
work in `handle_continue/2`. Two properties fall out of that placement:

- The host's start-up does not wait for it, so an unreachable server does not add
  its connect timeout to every boot.
- The query does not run in the process that calls `install/2`, so `install/2`
  keeps performing no network work and the registration requirement stands
  unchanged.

The check needs to be able to see past the connection's own binding, for the
reason in Context: on a first install the database does not exist, and a bound
connection cannot report that with a plain statement. The `database` query option
is what resolves it — sent per request, so asking for `system` overrides whatever
the connection was bound to. No second connection is opened, which also means the
check cannot collide with `Migration.setup/1`'s bootstrap connection, whose
one-call-per-VM lifecycle this library already has to reason about. The query is
still bounded, still a single `SELECT count()`, and still performed on the
installer's own process rather than in the caller's.

It answers three ways rather than two:

| Answer | Attach? | Why |
| --- | --- | --- |
| table present | yes | the normal case |
| table absent | **no** | one error naming the migration entry point; a host that has not created the schema gets words, not a `lost` count |
| server unreachable | yes | a server that is briefly down at boot must not leave the host without log capture until its next restart |

The third row is the whole reason this is not a boolean. "Server down" and
"table missing" call for opposite decisions, and collapsing them would either
disable logging during a transient outage or do nothing on a first install.

The query is a read of `system.tables`. It creates and alters nothing and records
no migration, which is what keeps "application boot does not touch schema" true
while boot does talk to the database.

It checks that the table exists, not that it carries every column the current
version writes. A table from before the `node` column still attaches, and the
rejected writes are reported and counted per the failure-handling requirement —
the documented upgrade path, unchanged.

### Suppress the Ash inclusion checks on this library's own definitions

```elixir
use Ash.Domain, validate_config_inclusion?: false
use Ash.Resource, ..., validate_domain_inclusion?: false
```

Ash documents both options as the supported way to resolve this for a module that
knows its own answer.

Considered and rejected:

- **Ship `config/`.** It would silence the warning the same way it silences it in
  this repository, but it contradicts an explicit package requirement, and it adds
  files to the tarball that cannot affect a host at runtime — the reason the
  directory is excluded in the first place.
- **Keep documenting `ash_domains`.** The status quo asks the host to register a
  domain that belongs to this library, in order to silence a report about this
  library. The host is not in a position to resolve it.
- **Set `:ash_domains` at runtime from `Application.start/1`.** Cannot work. The
  check runs while the module is compiled, which for a dependency happens before
  any application starts.
- **`config :ash, validate_*: false`.** Global. It would stop reporting the host's
  own resources too, which is a real loss to the host and is not this library's
  decision to make.

The options are set per module, so the host's own resources keep being checked
against the host's own configuration.

### The suite opts out in `config/test.exs`

`config :clickhouse_ex_logger, auto_start: false`, set in `config/test.exs`
rather than in `test_helper.exs`, because Mix loads configuration before it starts
any application and `test_helper.exs` runs after.

The automatic start is still covered: a test starts the Application's children
directly under `start_supervised!/1`, which exercises the same code without
fighting the application lifecycle the suite already owns.

## Risks / Trade-offs

- **A host on 0.2.0 that keeps its own `ClickhouseExLogger.Repo` child crashes on
  boot** with `ArgumentError: table name already exists` from inside the second
  connection, and its application does not start. → Cannot be softened in code
  without giving up automatic start, because the failure is the client's, not
  ours. The README upgrade note names the error, the cause, and the
  `auto_start: false` setting, because this is the one host-visible break and a
  host meets it as a crash rather than as something readable. It is also the only
  reason this change increments the minor version of a `0.x` library.

- **The Installer's `terminate/1` is deferred while the readiness check is in
  flight**, because a `GenServer` blocked in `handle_continue/2` does not run its
  terminate callback. → The check is bounded at 2s, and the caller waits at most
  3s, both comfortably inside the supervisor's shutdown budget. If the bound is
  ever exceeded, the check is abandoned, the handler attaches anyway, and the
  worst case is a handler still registered against a stopped buffer — which
  `GenServer.cast/2` to an unregistered name drops silently, exactly as it already
  does for a row cast after any buffer crash. The drain is unaffected either way:
  it is `Handler.uninstall/1`'s bounded flush, not the buffer's `terminate/2`.

- **The host loses the ability to choose when log capture begins.** A library that
  installs a `:logger` handler at boot takes that decision by default. →
  `auto_start: false` is the documented way out, and `install/2`'s idempotency
  means a host that installs explicitly anyway does not end up with two handlers.

- **A first install now produces one error at boot and no rows**, where before it
  produced a climbing `lost` count and no rows. Both lose the same events; only
  one says why. → Intended, and the reason the check exists. The host recovers by
  running the migration entry point and restarting, which the README's ordering
  already told it to do.

- **The readiness check adds one query to every boot.** → A single `SELECT
  count()` against `system.tables`, on the connection the pipeline is opening
  anyway, bounded at 2s. No second connection, so nothing to leak and nothing that
  can collide with the migration path's own.

## Migration Plan

1. Ship as `0.3.0` — a breaking change for the supervision-tree case, and the only
   one.
2. README: Setup becomes three steps — declare the dependency, configure the
   connection, run the migration. The supervision-tree example and the
   `ash_domains` section are removed. An upgrade section states that a host
   already supervising `ClickhouseExLogger.Repo` must set `auto_start: false`
   before upgrading, and names the error it will otherwise meet.
3. `ClickhouseExLogger.Repo`, `ClickhouseExLogger.Handler`, and
   `ClickhouseExLogger.Domain` moduledocs are updated to describe automatic start
   as the default path. `ClickhouseExLogger.Domain` stops telling hosts to add a
   line they no longer need.
4. CHANGELOG entry, marked breaking for that case.

**Rollback.** A host that hits the boot crash does not need to change code: it
sets `auto_start: false` and its existing `Application.start/2` works unchanged
against the new version, because `install/2`, `uninstall/1`, and the migration
entry points are untouched. Rolling the library back to `0.2.x` also works — the
`handler` and `auto_start` keys are simply unread. No schema change is involved
in either direction, so nothing needs unwinding in ClickHouse.

## Open Questions

None. The questions that would have changed the approach — whether an unreachable
server may legitimately disable log capture, and whether the readiness check can
distinguish "server down" from "table missing" — are settled by existing behaviour
in this codebase (the buffer's own failure accounting, and the `database`
per-request option the data layer already sends), and are settled above. Two
mechanisms changed during implementation on the evidence — the check's connection,
and where the shutdown drain happens — and both are recorded above with what was
rejected.