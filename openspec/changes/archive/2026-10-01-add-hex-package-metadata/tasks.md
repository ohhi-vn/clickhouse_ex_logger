# Tasks

## 1. Package manifest

- [x] 1.1 Create `CHANGELOG.md` with a `## 0.1.0` entry describing the first
      release (initial handler, buffered delivery, `node` column, migration task).
      Verify: the file exists and `mix format --check-formatted` is unaffected.
- [x] 1.2 Extend `package/0`'s `:files` in `mix.exs` to
      `~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)`.
      Verify: `mix hex.build` lists `priv/repo/migrations/*.exs` among the
      included files and reports no missing-file warning.
- [x] 1.3 Correct the comment in `test_coverage/0` that claims `package/0` ships
      `lib` alone, and state there why `test/support` stays out of the manifest.
      Verify: `grep -n "ships" mix.exs` shows no remaining claim that `priv` is
      excluded.

## 2. Package metadata

- [x] 2.1 Add `:source_url` and `:homepage_url` to `project/0` in `mix.exs`, both
      `https://github.com/ohhi-vn/clickhouse_logger`. Verify: `mix hex.build`
      output shows the URL, and no other host is declared.
- [x] 2.2 Add `:links` to `package/0` with `GitHub` pointing at the repository and
      `Changelog` pointing at `.../blob/main/CHANGELOG.md`. Verify: each path
      resolves against the repository — the changelog one only after 1.1 is on
      `main`.
- [x] 2.3 Confirm `mix.exs` declares no `:organization`, no `:secret_scan`, and no
      `:build_tools`, and that `:name` is left unset so the package keeps the
      `clickhouse_ex_logger` name derived from `app`. Verify: `mix hex.build`
      output names the package `clickhouse_ex_logger`.

## 3. Documentation

- [x] 3.1 Add `{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}` to `deps/0` and
      run `mix deps.get`. Verify: `mix.lock` gains `ex_doc`, and
      `mix deps.tree --only prod` does not list it.
- [x] 3.2 Add a `docs/0` function returning `[main: "readme",
      source_url: ..., source_ref: "v#{version}"]`, referenced from `project/0`.
      Verify: `mix docs` succeeds and the generated `index.html` is the README.
- [x] 3.3 Confirm `mix docs` produces no reference to a module absent from `lib/`
      and no broken-grouping warning. Verify: read the `mix docs` output; treat
      any warning as a task to fix in the same change.

## 4. Manifest verification

- [x] 4.1 Add `test/mix_project_test.exs` asserting that `Mix.Project.config()
      [:package][:files]` lists `priv` — the directory
      `ClickhouseExLogger.Migration.migrations_path/0` resolves through — and that
      it lists `README.md`, `LICENSE`, and `CHANGELOG.md`. Assert against the
      priv-directory resolution rather than a frozen literal list.
      Verify: `mix test test/mix_project_test.exs` passes.
- [x] 4.2 Temporarily remove `priv` from `:files` and confirm 4.1 fails, then
      restore it. Verify: the test fails with a message naming `priv`, and passes
      again after restore.
- [x] 4.3 Run the full suite and confirm coverage stays at or above the 90% gate,
      since a new top-level test module is compiled into the test build.
      Verify: `mix test --cover` exits zero.

## 5. Release procedure

- [x] 5.1 Add a `### Releasing` subsection to `README.md`'s Development section:
      `mix test --cover`, `mix docs`, `mix hex.build`, inspect the included-files
      list for `priv/repo/migrations`, push tag `v<version>`, then
      `mix hex.publish`. State that publishing is manual and that
      `mix hex.publish --revert VERSION` undoes a bad release.
      Verify: a reader can follow it top to bottom without consulting Hex docs.
- [x] 5.2 Run the documented steps in order up to and including `mix hex.build`
      and confirm each succeeds on this machine with Hex 2.5.1. Verify: all four
      commands exit zero and the file list contains both migration files.
