# Proposal

## Why

Installing this library takes five steps, and two of them exist only because the
library declines to start itself. A host adds the dependency, writes two config
blocks, runs one command, and then edits `Application.start/2` to add
`ClickhouseExLogger.Repo` to its supervision tree and call
`Handler.install/2` — with a documented ordering requirement between the two
lines, because the wrong order is only visible later as a climbing `lost`
counter. A third block, `ash_domains:`, silences a compile-time Ash warning
about a domain the host has no reason to know about.

Most of that is the library asking the host to do work it can do itself. What
should be three steps — add the dependency, configure the connection, run the
migration — is currently five, and the two extra ones are the ones that are easy
to get wrong.

## What Changes

- **The library starts itself.** `mix.exs` gains an OTP application callback.
  The `:clickhouse_ex_logger` application supervises `ClickhouseExLogger.Repo`
  and attaches the `:logger` handler, so a host writes no application code. The
  handler's batching options are read from application configuration, and a
  configuration switch disables the automatic start for hosts that need to place
  the connection themselves. `Handler.install/2` and `Handler.uninstall/1` remain
  the explicit API and are unchanged.

- **A host that adds the dependency without configuring the connection now fails
  its own boot**, where before it failed only its first flush. This is the cost
  of moving the work into the library's start path, and it is the trade this
  change accepts: a misconfiguration is reported by the process that caused it
  rather than by a counter nobody is watching.

- **Startup probes once for the `logs` table before attaching the handler.** If
  the server answers and the table is absent, the library logs one error naming
  the migration command and does not attach, so a forgotten migration is a
  readable message instead of a `lost` count that is indistinguishable from a
  ClickHouse outage. If the server does not answer at all, the handler attaches
  anyway and the existing failure handling applies — a transient outage at boot
  must not turn logging off until the next restart. The probe is read-only:
  boot still creates and alters no schema.

- **The `ash_domains` configuration line is gone.** Ash's domain-inclusion
  warning is suppressed in the library's own resource and domain definitions,
  which is where the suppression belongs: the host cannot register a
  dependency's internal domain, and the check was only ever reporting the
  library's packaging decision back at the host.

- **The README's Setup section is rewritten from five steps to three**, and the
  `ClickhouseExLogger.Domain` moduledoc stops telling hosts to add a line they no
  longer need.

Nothing is removed from the public API. `Handler.install/2`, `Handler.uninstall/1`,
`Handler.validate/1`, `mix clickhouse_ex_logger.migrate`, and
`ClickhouseExLogger.Utils.migrate/1` all keep their current behaviour, and the
connection configuration key stays the single place a host states its
ClickHouse connection.

## Capabilities

### New Capabilities

None. This change adds no capability the project does not already describe; the
behaviour it introduces is host onboarding, which is what the existing
`clickhouse-log-handler` capability already covers.

### Modified Capabilities

- `clickhouse-log-handler`:
  - *Published library identity* — the "host configures, starts, and migrates"
    scenario describes adding the repo to the host's supervision tree and calling
    `install/2`, which is no longer the documented path.
  - *Published package contents* — the requirement to document the `ash_domains`
    configuration line is replaced by in-code suppression, so the host's build is
    quiet without the host doing anything.

Two requirements are added: automatic startup of the pipeline, and the read-only
startup check that decides whether to attach.

*Handler registration and lifecycle* and *ClickHouse table contract* are
deliberately **not** modified. The automatic start calls the existing
registration operation rather than introducing a second registration path, so
every guarantee those requirements make — all-or-nothing registration, no network
work in the registering process, bounded removal, no schema created or altered at
boot — continues to hold unchanged. The startup check is read-only, so it does
not conflict with the table contract's prohibition on schema changes at boot.

## Impact

**Code**

- `mix.exs` — `application/0` gains `mod:`. `files/0` and the package manifest
  are unchanged; the new module ships under `lib/`.
- New `lib/clickhouse_ex_logger/application.ex` — the supervision tree, the
  handler-options reader, and the readiness probe.
- `lib/clickhouse_ex_logger/domain.ex`, `lib/clickhouse_ex_logger/log_entry.ex` —
  DSL options that suppress Ash's domain-inclusion checks.
- `lib/clickhouse_ex_logger/handler.ex`, `repo.ex` — moduledocs updated to
  describe automatic start as the default path. No behavioural change.
- `README.md` — Setup section reduced to three steps; the domain-warning section
  and the supervision-tree example are removed.

**Tests** — `test/test_helper.exs` starts the repo connection itself, so it will
need the automatic start disabled. `test/clickhouse_ex_logger/readme_test.exs`
asserts against the README's setup content, and
`no_schema_at_boot_test.exs` covers the boot-touches-no-schema guarantee, which
the readiness probe must not weaken. New tests cover the automatic start, the
opt-out, and both probe outcomes.

**Dependencies** — none added. The probe uses the ClickHouse connection this
library already opens.

**Compatibility** — **BREAKING**: a host on 0.2.0 that keeps its own
`ClickhouseExLogger.Repo` child will now crash on boot. The second connection
cannot be started in the same VM — `ClickHouse.Interface.HTTP` creates a named
ETS table per connection in `init/1`, so the second start raises
`ArgumentError: table name already exists` from inside the new process, before
`AshClickhouse.Connection.start_link/1` can map it. The host's supervisor fails to
start and its application does not boot. This is the same constraint
`ClickhouseExLogger.Migration` already documents for its own bootstrap
connection, and it is why the opt-out switch is required rather than advisory. The
README upgrade note must name the error and the switch, because a host meets it as
a boot crash rather than as a log line it can read.