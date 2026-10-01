# Design

## Context

`mix clickhouse_ex_logger.migrate` is a Mix task, so it exists only where Mix
exists. In an OTP release built with `mix release`, `Mix` is not on the code path
and `mix` is not installed on the production host; the library's own documented
first step is therefore unreachable there. See proposal.md for the motivation.

Two constraints in `ClickhouseExLogger.Migration` shape the approach:

1. **`setup/1` always starts the repo connection itself.** It calls
   `AshClickhouse.Connection.start_link/1` under the name
   `ClickhouseExLogger.Repo`, and `ClickHouse.Interface.HTTP.init/1` creates a
   globally named ETS table (`ClickHouse.Interface.HTTP.ClickhouseExLogger.Repo`)
   when the client starts. A second start in the same VM raises
   `ArgumentError: table name already exists` from inside the new process — before
   `start_link/1`'s `{:error, {:already_started, pid}}` branch can apply. This is
   why `Migration`'s moduledoc calls `setup/1` "one call per VM".

   That is fine for a Mix task, which owns a fresh VM. It is *not* fine for a
   release: `bin/my_app eval "..."` boots the release first, so the host's
   supervision tree has usually already started `ClickhouseExLogger.Repo`. Calling
   `setup/1` there as written crashes before it issues a statement. Reusing the
   running connection is therefore a correctness requirement of the release entry
   point, not an optimisation.

2. **Reporting goes through `Logger`, not `Mix.shell()`.** `setup/1` already runs
   the migration runner with `logger: true`, which routes statements to
   `Logger.info/1`. `Logger` is present and working in a release, so the
   surrounding summary must use it too; `Mix.shell().info/1` is unavailable there.

## Goals / Non-Goals

**Goals:**

- A host with a release and no Mix can create the database and apply migrations,
  against the same configuration key it already uses, before the new version
  starts logging.
- One implementation of the migration, shared by both entry points.
- Release invocation is safe whether or not `ClickhouseExLogger.Repo` is already
  running.

**Non-Goals:**

- Changing `mix clickhouse_ex_logger.migrate` behaviour, name, or options.
- Schema rollback in releases. `AshClickhouse.Release.rollback/3` exists, but
  nothing here needs it, and adding it would widen the surface without a caller.
- Changing the package manifest. `priv/repo/migrations/*.exs` is already in
  `:files` and already built into the tarball; this change verifies that, and
  adds a task only if verification finds a gap.

## Decisions

### 1. `ClickhouseExLogger.Utils.migrate/1`, delegating to `Migration.setup/1`

A new public module `ClickhouseExLogger.Utils` in `lib/clickhouse_ex_logger/utils.ex`
exposes `migrate/1`:

```elixir
@spec migrate(keyword()) :: {:ok, map()} | {:error, term()}
def migrate(opts \\ []) do
  Code.ensure_loaded!(ClickhouseExLogger.Repo)

  case ClickhouseExLogger.Migration.setup(opts) do
    {:ok, summary} ->
      Logger.info(fn ->
        "ClickhouseExLogger schema is up to date: " <>
          "#{length(summary.applied)} applied, #{length(summary.skipped)} already applied."
      end)

      {:ok, summary}

    {:error, reason} ->
      Logger.error(fn -> "Could not create the ClickhouseExLogger schema: #{inspect(reason)}" end)
      {:error, reason}
  end
end
```

**Alternative considered — extend `Migration` with a second function.** Rejected:
`Migration` is already the single owner of *how* the schema is prepared, and a
host-facing reporting function is a different concern. `Utils` is the
host-facing, Mix-free surface; `Migration` stays the implementation.

**Alternative considered — document `AshClickhouse.Release.migrate/3` as the
release path.** Rejected: it resolves `:migration_path` from the *host's* app priv
directory and iterates `Application.fetch_env!(host_app, :ash_clickhouse_repos)`.
Our migrations live in *this* dependency's priv, and the host has no reason to
list a foreign repo in its own config. It also cannot be told which repo to use,
so a host would have to hand it `ClickhouseExLogger.Repo` and a migration path —
reimplementing by hand what `Migration.setup/1` already does correctly. That is
the status quo the spec forbids (delegating the entry point away from this
library), just with more steps.

`:dry_run` is accepted and forwarded, matching the Mix task's `--dry-run`, so an
operator can see what a release would do before a deploy.

### 2. `setup/1` reuses a running repo connection instead of always starting one

In `ClickhouseExLogger.Migration.start_repo_connection/0`, return `:ok` early when
`AshClickhouse.Connection.get_conn(ClickhouseExLogger.Repo)` yields a connection
whose `pid` is alive; otherwise start it as today. `get_conn/1` erases its
`:persistent_term` entry when the client dies (the `Process.monitor/1` set up in
`Connection.start_link/1`), so a stale entry cannot make this skip a start it
needs.

**Alternative considered — have `Utils.migrate/1` check for a running repo and
branch.** Rejected: the ETS-table collision is a property of starting a second
client, so the guard belongs next to the start. Putting it in `Utils` would leave
`setup/1` able to crash for a caller that did nothing wrong.

Behaviour for existing callers is unchanged. The test suite already stops the
shared connection before each `setup/1` call, so it takes the start path exactly
as before.

**Alternative considered — have `Utils.migrate/1` stop a connection it started
afterwards.** Do this: `setup/1` returns which path it took only if we thread it
through, which is more surface than the case deserves. Instead, `Utils.migrate/1`
records whether a connection was already running *before* calling `setup/1` and
stops it in an `after` only when it started one. In `bin/my_app eval` the caller
process exits immediately afterwards and would take the linked connection down
anyway; this just makes that deterministic rather than incidental, and it leaves
a host-supervised `ClickhouseExLogger.Repo` untouched.

### 3. `CREATE DATABASE` keeps using the throwaway bootstrap connection

Unchanged, and it remains necessary in a release for the reason in `Migration`'s
moduledoc: a client bound to a database that does not exist yet fails every
statement on it, including `CREATE DATABASE`. The bootstrap client is registered
under its own name, so it has its own ETS table and does not collide with a
running `ClickhouseExLogger.Repo`. `setup/1`'s `try/after` still stops it.

### 4. Documentation in all three places a host looks

- README setup step 2: keep the Mix task as the primary instruction, add the
  release invocation as the alternative for hosts without Mix.
- README upgrade note ("Run this again"): currently tells the reader to re-run
  `mix clickhouse_ex_logger.migrate`. It must also name the release command,
  because that note is read precisely when a deploy is in progress, which is
  exactly when a release exists.
- `ClickhouseExLogger.Utils` moduledoc and `migrate/1` doc: show
  `bin/my_app eval "ClickhouseExLogger.Utils.migrate()"`.
- `mix clickhouse_ex_logger.migrate`'s moduledoc: one paragraph pointing at the
  release path, so a reader who found the Mix task learns the other exists.

### 5. Package contents verified, not changed

`mix hex.build` output already lists both
`priv/repo/migrations/*.exs` files, `mix.exs` `@shipped_directories` already
includes `priv`, and `test/mix_project_test.exs` already fails if either
migrates out of the manifest or if `priv` disappears entirely. In an OTP release,
Mix copies each application's `priv` into the release, so `:code.priv_dir/1`
resolves there. Nothing to change; task 5 re-runs the verification so the claim
rests on the current tree rather than on this document.

## Risks / Trade-offs

- **`Utils.migrate/1` is untested in an actual `mix release`** → The suite cannot
  build and boot a host release cheaply. Test what is actually library-owned:
  `Utils.migrate/1` against the container-provisioned ClickHouse, including the
  already-running-repo path, which is the branch only a release exercises in
  anger. The remaining gap is Mix's absence, which is enforced by the function
  touching no `Mix` API — stated as a limitation rather than papered over.
- **The reuse guard is a behaviour change to `setup/1`**, which the Mix task also
  calls → Guarded by the existing task and migration tests, which stop the shared
  connection first and therefore still exercise the start path. Add a case where
  a connection is already running.
- **A release operator runs the migration against the wrong release's priv** →
  Migrations are resolved through `:code.priv_dir(:clickhouse_ex_logger)`, so they
  are the ones the running release actually carries. This is the desired
  behaviour; the docs say to run it before the new version starts logging.
- **Reusing the running connection means a stale database binding** → The
  connection's `:database` is the configured one, resolved from the same app env
  the Mix task reads. If a host changes `:database`, the supervisor's connection
  is stale, but so is the running handler's, and fixing that belongs to the host's
  config reload, not to a migration helper.

## Migration Plan

No data migration and no deploy ordering constraint on existing hosts: this adds
a function and documentation. Hosts that already run the Mix task are unaffected.
Hosts that need it adopt the release command in their own release steps; because
the operation is idempotent, a partially adopted fleet can run either entry point
per host.