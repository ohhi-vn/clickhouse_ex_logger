# Design

## Context

See proposal.md — Why.

The rename is mechanically broad but shallow: no logic changes, and every module
here already references its siblings by full name, so there is no indirection
layer to update. What makes it worth designing rather than doing as a search and
replace is four constraints that a blind rename gets wrong or cannot see.

**The OTP application name is load-bearing in three places, not one.** Beyond
`mix.exs`, it is the `otp_app:` argument to `use AshClickhouse.Repo` in
`lib/clickhouse_logger/repo.ex`, and the argument to `:code.priv_dir/1` in
`ClickhouseLogger.Migration.migrations_path/0`, which locates the shipped
migration files. Miss the third and the migration silently falls back to the
relative path `"priv/repo/migrations"`, which resolves against the host
application's working directory rather than this library's — producing a
confusing "no migrations found" in a host that has migrations of its own.

**A missing configuration does not fail loudly.** `AshClickhouse.Repo.config/0`
returns `[]` when the application environment has no entry, and
`AshClickhouse.Repo.config_to_conn_opts/1` then fills in
`url: "http://localhost:8123"` and `database: nil`. So a host that renames the
dependency but leaves `config :clickhouse_logger, ClickhouseLogger.Repo` behind
would not get an error about the renamed key. It would connect to whatever
ClickHouse happens to be on localhost, writing into a database this library never
asked for — or reporting every flush as failed while appearing to start cleanly.
The spec delta forbids that silent fallback, so the rename has to add the check
that makes it loud.

**Migration tracking is by version, not module name.**
`AshClickhouse.MigrationRunner` records applied migrations in ClickHouse's
`schema_migrations` table, matching on the `version/0` string
(`deps/ash_clickhouse/lib/ash_clickhouse/migration_runner.ex`). Renaming
`ClickhouseLogger.Migrations.CreateLogsTable` to
`ClickhouseExLogger.Migrations.CreateLogsTable` therefore does not disturb an
existing database — provided the version string stays exactly
`20260101000000`. This is the one place where the obvious thing to do (stamp the
rename into the version, the way one would in a relational world) is actively
wrong, and it is not detectable by running the test suite against a fresh
container.

**The suite is the only real verification available.** `mix test` provisions a
ClickHouse container and asserts end-to-end behaviour, and the test modules and
support code carry roughly forty references to the old names. A rename is
complete when that suite compiles and passes — but the suite is also what a
partially-applied rename breaks, so task ordering matters more here than usual.

## Goals / Non-Goals

**Goals:**

- One mechanical rename applied completely, with no residue of the old name
  reachable from any entry point a host uses.
- Preserve existing ClickHouse databases across the rename, so a host that
  upgrades does not re-create or lose its `logs` table.
- Make the renamed configuration key's absence a diagnosable failure.
- Leave behaviour identical, so the existing spec requirements need no delta.

**Non-Goals:**

- No compatibility shims, deprecated aliases, or config fallbacks for the old
  names (see Decisions).
- No version bump for the library, and no change to the `logs` table, its
  columns, its engine, or the `ORDER BY` clause.
- No change to dependencies, the batching pipeline, or the counter semantics.
- No cleanup of pre-existing issues noticed during the rename — notably the
  duplicated comment block in `lib/clickhouse_logger/log_entry.ex`, which is
  outside this change's scope.

## Decisions

### Rename by definition rename and file move, not by string substitution

The module namespace, the OTP application, the config key, the Mix task name, the
internal marker metadata key, and the dev/test database names all move in one
commit, using `git mv` for the affected paths so history follows the files.

Renaming definitions (not merely aliasing old names to new ones) is what makes
the suite meaningful: `ClickhouseLogger.Handler` stops compiling as soon as the
library is renamed, so the ~40 references across `test/` are a forced,
self-checking inventory of the rename surface. A shim approach would leave those
references compiling and passing, hiding whatever was missed.

Alternative considered: leave `ClickhouseLogger.*` as thin `defdelegate` wrappers
over `ClickhouseExLogger.*` for one release. Rejected — the library is unreleased
at `0.1.0`, so there is no installed base to protect, and the wrappers would be
permanent surface with a permanent removal decision attached.

### Rename the Mix task by renaming its file

`lib/mix/tasks/clickhouse_logger.migrate.ex` becomes
`lib/mix/tasks/clickhouse_ex_logger.migrate.ex`, moving the module to
`Mix.Tasks.ClickhouseExLogger.Migrate`. Mix derives a task's name from its
filename, so the file must move for the task rename to take effect — a module
rename alone would leave the old task name registered.

### Keep the migration version at `20260101000000`

The module renames; `@version` does not. See Context for why module identity is
irrelevant to migration tracking and why changing the version would cause
`CREATE TABLE` to be re-issued against databases that already have the table.

This is worth a scenario in the spec delta and a dedicated verification step in
the task list, precisely because the test suite — which runs against a container
whose `schema_migrations` starts empty — cannot detect the mistake.

### Add an explicit configuration-presence check

`ClickhouseExLogger.Repo` overrides `config/0` to raise
`AshClickhouse.Error.ConfigurationError` when
`Application.get_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo)` is absent,
naming both the application and the module the host should configure.

Without this, the stale-config scenario in the spec delta cannot hold: the
dependency is renamed, the host's config key is not, `config/0` returns `[]`, and
`config_to_conn_opts/1` supplies `http://localhost:8123` — so the pipeline starts
cleanly and writes to an unintended database or reports every flush as lost,
which reads as a ClickHouse outage rather than a rename the host missed.

`config/0` is `defoverridable` in `AshClickhouse.Repo`, so this is an override of
an existing callback rather than a new mechanism. The check runs at connection
time, not at compile time, so it also covers a host that renames the dependency
and configures the new key with `nil` or a non-keyword value.

Alternative considered: leave the check to `AshClickhouse.Repo` and document the
rename in a changelog. Rejected — it is documentation the host reads once, versus
a failure at the moment of misconfiguration that names the fix. This is a
library whose entire failure mode is "ClickHouse is unreachable", so an
unconfigured repo masquerading as an unreachable ClickHouse is the most
expensive possible confusion.

### Test the config check in isolation

The check lives in `Repo.config/0` and needs no database, so it is asserted in a
plain `async: true` `ExUnit.Case` with `Application.delete_env/3` in setup and
restore in `on_exit`. This keeps the guarantee covered even when no container
engine is available, consistent with the project's existing stance that
database-free modules still run without an engine.

### Move the project directory last, and separately — dropped during apply

The working directory was to be renamed to `clickhouse_ex_logger` after the
in-repo rename was complete and green, as its own step. Renaming it first would
relocate the repo mid-change and make every subsequent path stale.

This was dropped during apply: live tooling holds the old absolute path. The
editor's `dexter` formatter daemon runs with `/…/clickhouse_logger` and
`/…/clickhouse_logger/.formatter.exs` in its argv, and the `.expert` indexer
holds `.expert/expert.log` open, so the move would have broken `mix format` from
the editor until it was restarted. The user chose to leave the folder named
`clickhouse_logger`.

Nothing about the published artifact depends on it: the hex package name comes
from `app: :clickhouse_ex_logger` in `mix.exs`, and `package.files` is
`~w(lib .formatter.exs mix.exs README.md LICENSE)`, which names no directory. So
the *library* identity in the spec delta — OTP application, module namespace,
config key, Mix task — is fully satisfied without the folder move. Only local
cosmetic consistency is deferred, and the recipe to finish it is in `tasks.md`
section 9.

Renaming the dev and test databases (`clickhouse_logger_dev` →
`clickhouse_ex_logger_dev`, `clickhouse_logger_test` →
`clickhouse_ex_logger_test`) does happen in this change. Nothing is carried
across: these hold development data, and the migration is idempotent, so
recreating them is cheaper than migrating them. Existing tables in the old
database are left in place and can be dropped by hand.

## Risks / Trade-offs

[Host has renamed the dependency but not its config key, and gets a silent
connection to localhost instead of an error] → Mitigated by the `Repo.config/0`
override described above, plus a test asserting the raised error names both the
application and the module. This is the rename's only way to hurt someone at
runtime, which is why it gets an explicit check rather than a changelog line.

[Migration version accidentally bumped to the rename date, causing `CREATE TABLE`
to be re-issued against existing databases] → Mitigated by an explicit task-list
verification that asserts the shipped version string is still `20260101000000`,
and by a spec scenario stating the version is not derived from the rename. The
container-based suite cannot catch this, since its `schema_migrations` is empty.

[A reference to the old name survives in a doc comment or `@moduledoc`, where no
compiler will catch it] → Mitigated by a final repository-wide grep for
`clickhouse_logger` and `ClickhouseLogger` over source, config, docs, and
dotfiles, expecting only intentional historical references in
`openspec/changes/archive/`.

[Directory rename breaks a path the user or tooling holds — an open editor, a
running `mix` shell, a CI checkout, an IDE project reference] → This materialised
during apply: the editor's `dexter` formatter daemon was running with the old
absolute path in its argv. The rename was dropped by user decision and the
folder stays `clickhouse_logger`; `tasks.md` section 9 carries the recipe to
finish it later. No spec or task depends on the folder name.

[Renaming the test databases orphans `clickhouse_logger_dev` and
`clickhouse_logger_test` on a developer's machine] → Accepted. Accepted in the
proposal as costing no data worth keeping, and the old databases are inert
rather than harmful. Flagged here so it is a known consequence and not a
surprise.

[`git mv` on this volume may produce AppleDouble `._*` sidecars, which
`.formatter.exs` already filters out of `mix format` inputs] → Follow the
existing convention: the filter is already in place, and the new paths inherit
the same protection. No new handling needed.

## Migration Plan

1. Rename modules, files, directories, the OTP application, the config key, the
   Mix task, and the internal marker key in-repo.
2. Add the `Repo.config/0` presence check and its test.
3. Update `mix.exs`, `README.md`, `.gitignore`, and all doc references.
4. Run `mix format --check-formatted` and the full containerised `mix test`.
5. Grep for residual old-name references and confirm the only hits are the
   intentional historical ones in the archived changes.
6. ~~Rename the project directory to `clickhouse_ex_logger`.~~ Dropped during
   apply; see the decision above and `tasks.md` section 9.

**Rollback.** This change is unreleased and unpushed, so rollback is a `git reset
--hard` to the pre-rename commit — no data recovery step and no published
artifact to unpublish. If a host has already pulled the renamed dependency,
reverting is a matter of restoring their previous dependency name and config
key; their ClickHouse database is untouched by the rename, since only the
migration module's name changed and its version did not.