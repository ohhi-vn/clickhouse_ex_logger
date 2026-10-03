defmodule ClickhouseExLogger.MixProjectTest do
  @moduledoc """
  Guards the contents of the published package.

  `:files` in `mix.exs` decides what a host receives, and the failure it guards
  against is silent: a manifest that omits a directory the library reads at run
  time produces a package that installs, compiles, and only breaks once a host
  runs the documented setup step. `mix hex.build` catches it, but only for
  whoever is about to publish. These assertions run for every contributor and in
  CI.

  The assertions are about coverage of what `lib/` resolves, not about a frozen
  list of paths. A new runtime asset directory is caught the day it is added,
  rather than on the day someone remembers to add it to the manifest.
  """
  use ExUnit.Case, async: true

  @files Mix.Project.config()[:package][:files]

  # `ClickhouseExLogger.Migration` resolves this through `:code.priv_dir/1`,
  # because `AshClickhouse.MigrationRunner` would otherwise resolve its default
  # relative path against the *caller's* working directory. A package without
  # these files ships a `mix clickhouse_ex_logger.migrate` task that raises on
  # `{:error, :bad_name}` — so this is the one manifest omission that makes the
  # package unusable rather than merely incomplete.
  @priv_path "priv"
  @config_path "config"

  test "every shipped migration is in the manifest" do
    migrations = Path.wildcard(Path.join(@priv_path, "repo/migrations/*.exs"))

    assert migrations != [],
           "no migrations found on disk at #{@priv_path}/repo/migrations, so this " <>
             "test would pass on an empty assertion. Check priv/ still exists."

    for path <- migrations do
      assert path in @files,
             "#{path} is missing from :files. `mix clickhouse_ex_logger.migrate` " <>
               "resolves migrations through :code.priv_dir/1, so a package without " <>
               "it raises {:error, :bad_name} instead of creating the logs table."
    end
  end

  test "the priv directory is shipped at all" do
    assert Enum.any?(@files, &String.starts_with?(&1, @priv_path)),
           "no file under #{@priv_path}/ is in :files, but " <>
             "ClickhouseExLogger.Migration resolves its migrations through " <>
             ":code.priv_dir/1."
  end

  test "the documentation the README links to is shipped" do
    for path <- ["README.md", "LICENSE", "CHANGELOG.md"] do
      assert path in @files, "#{path} is missing from :files."
    end
  end

  test "the configuration is deliberately not shipped" do
    # Mix evaluates only the *current* project's configuration — `mix loadconfig`
    # reads `Mix.Project.config()[:config_path]` — so a dependency's `config/` is
    # never read by a host. Shipping `config/config.exs` would put files in the
    # package that cannot affect anything, and would not give a host the
    # `ash_domains` entry it needs. The README documents that entry instead.
    refute Enum.any?(@files, &String.starts_with?(&1, @config_path)),
           "config/ is in :files, but Mix never loads a dependency's config"
  end

  test "the manifest ships no harness or build output" do
    for path <- @files do
      refute String.starts_with?(path, "test/"),
             "#{path} is test-only code and must not reach a host's dependency tree."

      refute String.starts_with?(path, "openspec/"),
             "#{path} is a planning record, not library code."

      refute String.starts_with?(path, "cover/"),
             "#{path} is coverage output."

      refute Path.basename(path) =~ ~r/^\._/,
             "#{path} is an AppleDouble sidecar this volume wrote beside a real " <>
               "file. It is untracked (see .gitignore) and would ship as junk."
    end
  end

  test "the formatter is configured with a non-empty input list" do
    # `.formatter.exs` computes its `:inputs` rather than globbing, because this
    # volume's AppleDouble sidecars would break the formatter. It used to compute
    # them with `Path.wildcard/1` on the whole pattern list, which returns `[]` for a
    # list rather than expanding it — silently, with no error. `mix format` then
    # formatted nothing and `--check-formatted` passed on every run, which is how an
    # unformatted `handler.ex` reached the repository.
    {_value, opts} = Code.eval_file(".formatter.exs")
    inputs = Keyword.fetch!(opts, :inputs)

    assert is_list(inputs)

    assert inputs != [],
           ".formatter.exs computes an empty :inputs, so `mix format` " <>
             "silently formats nothing and `mix format " <>
             "--check-formatted` always passes"

    for path <- [
          "mix.exs",
          ".formatter.exs",
          "config/config.exs",
          "lib/clickhouse_ex_logger/handler.ex",
          "lib/clickhouse_ex_logger.ex",
          "test/mix_project_test.exs"
        ] do
      assert path in inputs,
             "#{path} is not in the formatter's :inputs, so " <>
               "`mix format` never checks it"
    end

    refute Enum.any?(inputs, &(Path.basename(&1) =~ ~r/^\._/)),
           "an AppleDouble sidecar is in :inputs, which makes `mix format` die with " <>
             "UnicodeConversionError"
  end

  test "the package is named for the OTP application it builds" do
    assert Mix.Project.config()[:app] == :clickhouse_ex_logger

    assert Mix.Project.config()[:package][:name] == nil,
           "an explicit :name would drift from app:. A host that declares " <>
             "{:clickhouse_ex_logger, ...} must get that package."
  end

  test "the package declares links that resolve to the project's repository" do
    links = Mix.Project.config()[:package][:links]
    repository = Mix.Project.config()[:source_url]

    assert is_map(links) and map_size(links) > 0,
           "Hex renders :links on the package page; without them a reader has no " <>
             "way to reach the source."

    for {name, url} <- links do
      assert String.starts_with?(url, repository),
             "#{name} points at #{url}, which is not under #{repository}. Hex " <>
               "renders every declared link, so one pointing somewhere the " <>
               "project does not maintain is a broken claim."
    end
  end

  test "the documentation build names this release" do
    docs = Mix.Project.config()[:docs]

    assert docs[:main] == "readme",
           "the documentation home page must be the README, so a reader arriving " <>
             "at the documentation site gets the same orientation as a reader of " <>
             "the repository."

    assert "README.md" in docs[:extras],
           "`main: \"readme\"` names a page in :extras. Without the entry, " <>
             "index.html redirects to a readme.html that is never generated."

    assert docs[:source_ref] == "v#{Mix.Project.config()[:version]}",
           "source links must pin to the release tag, not to the default branch, " <>
             "or the published documentation describes code that was not published."
  end
end
