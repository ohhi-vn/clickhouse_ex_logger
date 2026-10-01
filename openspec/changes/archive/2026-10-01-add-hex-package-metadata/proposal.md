# Proposal

## Why

The library cannot be published to Hex in its current state, and one defect would
make the published release broken rather than merely under-documented.

`:files` is `~w(lib .formatter.exs mix.exs README.md LICENSE)`, which omits `priv`.
`ClickhouseExLogger.Migration.migrations_path/0` resolves the shipped migrations
through `:code.priv_dir(:clickhouse_ex_logger)`, so in a consumer's dependency tree
that call returns `{:error, :bad_name}` and `Path.join/2` raises `FunctionClauseError`.
A published package would therefore ship a `mix clickhouse_ex_logger.migrate` task
that crashes on its first invocation — the task the README and the table-contract
requirement both instruct every host to run before logging.

Separately, the project declares no `:links`, `:source_url`, or `:homepage_url`, and
has no `ex_doc` dependency. Hex would accept the release but produce a package with
no discoverable source or homepage, and no documentation on hexdocs.pm at all.

## What Changes

- **BREAKING (packaging)**: add `priv` to the `:files` list, so the shipped
  migration task resolves its migration files in a consumer's dependency tree.
  No code in `lib/` changes; this corrects the release artifact only.
- Add `:links`, `:source_url`, and `:homepage_url` to `project/0`, pointing at
  `https://github.com/ohhi-vn/clickhouse_logger` (the repository's existing
  `origin` remote).
- Add `ex_doc` as a `only: :dev, runtime: false` dependency and a `docs/0`
  configuration, so Hex builds hexdocs automatically on publish and `mix docs`
  verifies them locally beforehand.
- Add `CHANGELOG` to the `:files` list and create a `CHANGELOG.md` seeded with the
  `0.1.0` entry, so release history is present in the published tarball rather than
  only in git.
- Document the release procedure in `README.md`: authenticate, run
  `mix hex.build`, confirm the built tarball's file list includes
  `priv/repo/migrations`, run `mix docs`, then `mix hex.publish`.

Deliberately unchanged: the package name stays `clickhouse_ex_logger` (Mix's
default derived from `app: :clickhouse_ex_logger`, and already fixed by the
`Published library identity` requirement); `:licenses` stays `["Apache-2.0"]`;
`:version` stays `0.1.0`, because this is the first publication rather than a
change to a released one; no `:organization` is set, so the release is owned by a
personal account on the default `hexpm` repository.

## Capabilities

### New Capabilities

None. Package metadata and release packaging belong to the capability that already
owns how this library presents itself to a host, rather than to a near-duplicate
capability about publishing.

### Modified Capabilities

- `clickhouse-log-handler`: the `Published library identity` requirement currently
  fixes the hex package name, OTP application name, and module namespace. It does
  not say what the published tarball must contain or what metadata a consumer of
  hexdocs can act on, so a release can satisfy that requirement and still be
  unusable. This change adds requirements for the package's file manifest,
  resolvable documentation links, and built documentation.

## Impact

- `mix.exs`: `project/0` (new `:links`, `:source_url`, `:homepage_url`, `:docs`),
  `package/0` (`:files` gains `priv` and `CHANGELOG.md`), `deps/0` (adds `ex_doc`).
- `mix.lock`: gains `ex_doc` and its transitive dependencies.
- `CHANGELOG.md`: new file.
- `README.md`: unchanged, except that any repository or documentation link it
  already carries should agree with the new `:links` values.
- No change to any module in `lib/`. No change to the `clickhouse_ex_logger` API,
  the `logs` table contract, or the `mix clickhouse_ex_logger.migrate` task's
  behaviour for existing hosts working from a path or git dependency.
- Publishing itself (`mix hex.user auth`, `mix hex.publish`) remains a manual,
  human-performed action. This change only makes the project publishable and
  verifies the artifact.
