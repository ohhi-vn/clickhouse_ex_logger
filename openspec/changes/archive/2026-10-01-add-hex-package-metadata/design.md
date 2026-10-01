# Design

## Context

See proposal.md — Why.

Constraints that shape the approach:

- `mix.exs` is not only the build file; it **ships inside the package**. Every value
  in it is evaluated by a consuming project's Mix, in every environment.
- The current `:files` list is a deliberate curation, not a leftover default. The
  comments in `test_coverage/0` and `deps/0` reason explicitly about what
  `package/0` does and does not ship, so the list is load-bearing documentation.
- `ClickhouseExLogger.Migration.migrations_path/0` is the only runtime path
  resolution in `lib/`, and it resolves through `:code.priv_dir/1` with a
  deliberately no-fallback comment.
- `test/support/coverage_tool.ex` is named by `test_coverage/0` in `mix.exs`, but
  compiles only under `:test`, because `elixirc_paths/1` adds `test/support` only
  in that environment.
- Repository: `https://github.com/ohhi-vn/clickhouse_logger`, default branch `main`,
  no tags pushed yet. Local Hex is 2.5.1.

## Goals / Non-Goals

**Goals:**

- A built package that a host can install and whose documented first step actually
  runs.
- Package metadata that is accurate and verifiable, with every declared link
  resolving to something the project maintains.
- Documentation published automatically with the release, verifiable locally first.
- The manifest stays a curated list, with the curation justified in place.

**Non-Goals:**

- Publishing. `mix hex.user auth` and `mix hex.publish` stay human-performed; this
  change only makes the project publishable and checkable.
- Any change to `lib/`. The `FunctionClauseError` is fixed by manifest, not by code,
  because the code's priv-directory resolution is already correct and is the reason
  the fix is a one-line manifest change rather than a runtime fallback.
- A CI pipeline for publishing. The guide documents `HEX_API_KEY` publishing, but no
  CI configuration exists in this repository, and inventing one is speculative.
- Bumping `:version`. `0.1.0` is unreleased, so it is still the correct number for the
  first publication.

## Decisions

### Add `priv` to the existing explicit `:files` list, not restore Mix's defaults

Mix's default manifest (`~w(lib priv .formatter.exs mix.exs README* readme*
LICENSE* license* CHANGELOG* changelog* src)`) already includes `priv` and
`CHANGELOG*`. Adopting it verbatim would fix the defect in one edit.

Rejected anyway, because the default globs pull in `src/` and any future
`*readme*`/`*changelog*` variant without a human deciding to ship them, and this
project's `mix.exs` is written to be readable as a specification of the release.
The explicit list is kept and extended: `~w(lib priv .formatter.exs mix.exs
README.md LICENSE CHANGELOG.md)`. The omission of `test/support` remains
deliberate and is now stated in a comment where the omission is visible.

### Correct the `mix.exs` comments that assert the old manifest

`test_coverage/0` currently says "`package/0` ships `lib` alone", and `deps/0`
justifies `only: :test` partly on that basis. Once `priv` ships, the first claim is
false and the reader is misled about the release contents. Comments that describe
the manifest are part of the manifest's documentation and are updated in the same
change.

### Do not add `secret_scan: [ignore: ...]`

Two independent reasons. The package ships no credentials, fixtures, or
certificates — `test/` is not in the manifest and `priv/` holds two `.exs`
migration files — so suppression would suppress nothing while asserting otherwise.
And the option requires Hex 2.5.2 or later, while this machine has 2.5.1; declaring
it would make `mix hex.build` fail here.

### Add `ex_doc` as `only: :dev, runtime: false` with the constraint `>= 0.0.0`

Hex builds documentation by running `mix docs`, so without `ex_doc` there is no
documentation task and no docs are published. `only: :dev` keeps it out of a host's
dependency tree entirely, which is what the spec requires of a build tool.

`">= 0.0.0"` rather than `"~> 0.38"` or similar: a documentation generator must
never constrain a host's resolution, and an open lower bound means a new Hex
publishing environment cannot be blocked by an old lockfile in this repository. The
trade-off is that the generated docs' appearance can shift between releases; the
alternative is a maintenance task that exists only to bump a number.

### Configure `docs` with `main: "readme"` and `source_ref` derived from the version

`main: "readme"` makes the documentation home page the README, which is what the
spec requires and what a reader arriving at hexdocs.pm should land on. `extras` is
not set; `main:` is the supported way to include the README, and adding `CHANGELOG`
as a second extra page is deferred until a second release exists to give it shape.

`source_ref: "v#{version}"` makes module source links point at the tag rather than
at `main`, so the documentation always describes the released code. Because no tags
exist yet, the release procedure must create and push `v<version>` *before*
publishing — which is the correct order regardless, and removes the dangling-ref
problem rather than tolerating it. Omitting `source_ref` was the alternative: it
never dangles, but it makes the published docs describe whatever `main` holds at
read time, which is the failure the spec's documentation requirement exists to
prevent.

### Declare `:links`, `:source_url`, and `:homepage_url` against `main` and the repository root only

GitHub is the only hosting this project verifiably has (it is the configured
`origin`). `homepage_url` therefore also points at the repository rather than at a
documentation site or a landing page that does not exist, and `:links` is limited
to `GitHub` and `Changelog` — the latter pointing at
`/blob/main/CHANGELOG.md`, which exists once the changelog is created.

Issues and Discussions are deliberately not declared. Hex renders them as prominent
links and they cannot be verified from the repository without a network call, and
the spec forbids declaring a location the project does not maintain.

### Verify the manifest in the suite rather than only in the release procedure

`mix hex.build` is the authoritative check, and it is in the documented release
procedure. But a check that runs only when a human is about to publish is a check
that gets skipped. So the suite also asserts, hermetically, that the manifest lists
the runtime directories the library resolves through `:code.priv_dir/1`, and that
the introduction, licence, and changelog it depends on are listed.

A new `test/mix_project_test.exs` reads `Mix.Project.config()[:package]` — pure
config inspection, no Hex required, so it runs in CI and on any contributor's
machine. It deliberately does not shell out to `mix hex.build`: that would make the
suite depend on the Hex CLI being installed, which is currently not true everywhere
the suite runs.

The test asserts *coverage of what `lib/` resolves*, not a literal file list, so
adding a future runtime asset directory is caught by the same assertion.

### Leave the `CoverageTool` reference alone

`test_coverage/0` names `ClickhouseExLogger.CoverageTool`, which compiles only in
`:test`, and `mix.exs` ships to consumers. This is safe: the value is a bare module
atom inside a keyword list, inert until `Mix.Tasks.Test.Coverage` loads it during a
coverage run, and a consumer cannot run one against this package because the
manifest ships no test files. Changing it would be a speculative refactor of a
working arrangement.

## Risks / Trade-offs

- **Manifest omissions recur for future runtime assets.** The current list was
  hand-written and shipped broken; the same class of bug appears the next time
  someone adds a runtime directory. → The suite assertion is written against what
  `lib/` resolves through `:code.priv_dir/1`, not against a frozen literal, so a new
  runtime asset is either covered by the check or the check fails to find it.
- **`:source_ref: "v#{version}"` points at a nonexistent tag until the first
  release.** → `mix docs` is a local, uncommitted-output operation, so the tag is
  pushed before publishing in the documented order, and the published docs therefore
  always have their ref.
- **`ex_doc` with an open version bound makes local doc output vary.** → Accepted;
  the alternative is a number to bump for no functional gain. The doc build is
  verified immediately before each release, which is where a rendering regression
  would surface.
- **A consumer on Hex older than the `:secret_scan` requirement is not affected
  precisely because nothing is declared.** → Verified against the local Hex 2.5.1.
- **Publishing to a personal account means the package is tied to one account
  rather than an organisation.** → Reversible for a not-yet-published package, and
  the package is not published until after this change lands. If the project later
  wants organisation ownership, `:organization` is added before the first publish,
  not after.
