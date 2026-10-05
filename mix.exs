defmodule ClickhouseExLogger.MixProject do
  use Mix.Project

  # Named once, so `version:`, `source_url:`, `homepage_url:`, `:links`, and the
  # ExDoc `source_ref` cannot drift apart. Hex requires a semantic version; while
  # the major version is `0`, a breaking change increments the minor version.
  #
  # 0.3.0 is a breaking change for one host shape: a host that supervises
  # `ClickhouseExLogger.Repo` itself now collides with this library starting the
  # same connection, and must set `auto_start: false`. See the README's upgrade
  # section.
  @version "0.3.0"

  # The project's one canonical URL. It is the only host this project verifiably
  # has, being the configured `origin`, so `homepage_url` is the repository rather
  # than a documentation site or landing page that does not exist — see `package/0`.
  @repository "https://github.com/ohhi-vn/clickhouse_logger"

  def project do
    [
      app: :clickhouse_ex_logger,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Read by ExDoc for the per-module source links, and shown on the package page.
      source_url: @repository,
      homepage_url: @repository,
      deps: deps(),
      package: package(),
      docs: docs(),
      test_coverage: test_coverage()
    ]
  end

  # Gates `lib/` at 90% line coverage, which is Elixir 1.20's own default for
  # `:summary`'s threshold. It is spelled out here so the gate is a stated
  # project decision rather than a constant a future Elixir could move, and so
  # `mix test --cover` failing is a deliberate outcome rather than a surprise.
  #
  # `:tool` is `Mix.Tasks.Test.Coverage` with one addition: this checkout is on
  # an exFAT volume, which makes the volume write an AppleDouble stub beside every
  # beam Mix writes, and `:cover` cannot be told to skip them. See
  # `ClickhouseExLogger.CoverageTool`.
  defp test_coverage do
    [
      tool: ClickhouseExLogger.CoverageTool,
      summary: [threshold: 90],
      # The test harness, not the library. These compile into the test build
      # only — `package/0` ships neither `test/` nor `test/support` — and most of
      # `ClickhouseExLogger.TestContainer`'s executable lines are diagnostics
      # for conditions the suite itself refuses to run under: no container
      # engine, an unreachable socket, an engine CLI that fails. Covering them
      # means asserting on error message text.
      #
      # `ClickhouseExLogger.Domain` and `Inspect.ClickhouseExLogger.LogEntry` are
      # excluded for a different reason: their only executable lines are module
      # bodies, which run at compile time, so `:cover` can only ever report 0.00%
      # for them however thoroughly they are exercised. `ResourceTest` asserts
      # against the domain directly. Listing them would put two phantom 0.00% rows
      # in every report.
      ignore_modules: [
        ~r/^ClickhouseExLogger\.(Case|CaptureHandler|CoverageTool|TestContainer|TestServer)$/,
        ClickhouseExLogger.Domain,
        Inspect.ClickhouseExLogger.LogEntry
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      description: "Ship Elixir Logger events into ClickHouse through Ash and AshClickhouse.",
      # Hex renders these as prominent links on the package page, so each one is a
      # claim that the destination exists and is maintained. GitHub is the
      # repository; the changelog is a file in it. Issues and Discussions are
      # deliberately absent — they cannot be verified from the repository without a
      # network call, and publishing a link to a disabled tracker is a broken claim.
      #
      # `:name` is left unset so the package takes `clickhouse_ex_logger` from
      # `app:`, matching the module namespace and the config key a host uses.
      #
      # No `:organization`: the release is owned by a personal account on the
      # default `hexpm` repository. No `:secret_scan` either — nothing shipped is a
      # credential, fixture, or certificate, and the option needs Hex 2.5.2 while
      # this project develops against 2.5.1, where declaring it fails the build.
      links: %{
        "GitHub" => @repository,
        "Changelog" => @repository <> "/blob/main/CHANGELOG.md"
      },
      files: files()
    ]
  end

  # `main:` makes the README the documentation home page, so a reader arriving at
  # hexdocs.pm gets the same orientation a reader of the repository gets. It names
  # a page in `extras/0`, so the README has to be listed there — `main:` alone
  # leaves `index.html` redirecting to a `readme.html` that was never generated.
  #
  # The changelog is a second page rather than a third link, so that a reader
  # arriving at hexdocs.pm can see the release history without leaving the docs.
  #
  # `source_ref` pins module source links to the release tag rather than to `main`,
  # so published documentation always describes the code that was published. No tag
  # exists yet, which is why the documented release procedure pushes `v<version>`
  # *before* publishing rather than after.
  defp docs do
    [
      main: "readme",
      extras: extras(),
      source_url: @repository,
      source_ref: "v#{@version}"
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      # The README ends with a relative link to the licence. ExDoc resolves a
      # relative file link only against `extras/0`, so without this the one link
      # out of the documentation home page renders as a dangling reference.
      "LICENSE"
    ]
  end

  # The release contents, enumerated here rather than left as globs for Hex to
  # expand, for one reason: Hex has no way to exclude a name, so a `lib` entry
  # carries every AppleDouble sidecar this volume wrote beside the sources
  # (`lib/._handler.ex`) straight into the tarball. Those are untracked local
  # files — see `.gitignore` — so a clean clone would not produce them, but a
  # publisher working on an exFAT volume would ship 30-odd junk files without
  # noticing.
  #
  # The exclusion comes from `Path.wildcard/2` itself, which defaults to
  # `match_dot: false` and so never matches a name beginning with a dot. That is
  # the whole mechanism — there is no filter to read here. It is worth stating
  # because it is the only thing keeping the sidecars out, and it is a default
  # rather than a decision this file makes.
  # `test/mix_project_test.exs` asserts the resulting manifest contains no
  # sidecar, so the property is guarded rather than assumed.
  #
  # The two directories are exhaustive on purpose, so that adding a runtime asset
  # does not also require adding a manifest entry.
  #
  # `config` is deliberately *not* shipped, even though this project keeps
  # `config/config.exs` in the checkout. Mix evaluates only the *current* project's
  # configuration — `mix loadconfig` reads `Mix.Project.config()[:config_path]` — so a
  # dependency's `config/` is never read by a host. Shipping it would add files to
  # the package that cannot affect anything, and the host still needs to name the
  # domain in its own config. The README says so where a host configures the repo.
  #
  # `priv` is load-bearing, not padding. `ClickhouseExLogger.Migration` resolves its
  # migrations through `:code.priv_dir/1`, because
  # `AshClickhouse.MigrationRunner` would otherwise resolve its default relative
  # path against the *caller's* working directory. Omitting `priv` ships a
  # `mix clickhouse_ex_logger.migrate` task that fails on `:code.priv_dir/1`
  # returning `{:error, :bad_name}` — the task every host runs before it can log
  # anything. `test/mix_project_test.exs` fails if a migration goes missing.
  #
  # `test/support` is deliberately absent. It compiles into the test build only
  # (`elixirc_paths/1`) and is harness code, not library code.
  @shipped_directories ~w(lib priv)
  @shipped_files ~w(.formatter.exs mix.exs README.md LICENSE CHANGELOG.md)

  defp files do
    @shipped_directories
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
    |> Enum.filter(&File.regular?/1)
    |> Kernel.++(@shipped_files)
    |> Enum.sort()
  end

  # `mod:` is what makes this library start itself. Without it a host has to add
  # `ClickhouseExLogger.Repo` to its own supervision tree and call
  # `ClickhouseExLogger.Handler.install/2` — two steps, in an order that matters,
  # for work this library can do. See `ClickhouseExLogger.Application`.
  #
  # A dependency's `config/` is never read, so a host cannot switch this off by
  # configuring us; the host's own `config :clickhouse_ex_logger, auto_start: false`
  # is the switch, read at runtime from the host's application environment.
  def application do
    [
      mod: {ClickhouseExLogger.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.34"},
      {:ash_clickhouse, "~> 0.7"},
      {:clickhouse, "~> 0.32"},
      # Provisions the ClickHouse the suite runs against, so a developer needs a
      # container engine and nothing else. `only: :test` keeps it out of every
      # host's dependency tree.
      {:testcontainer_ex, "~> 0.9.1", only: :test},
      # Hex publishes documentation by running `mix docs`, so without this there is
      # no `docs` task and nothing is published to hexdocs.pm.
      #
      # `only: :dev` keeps it out of a host's dependency tree entirely — a
      # documentation generator a host never calls must not reach its release. The
      # constraint is an open lower bound rather than a pinned version for the same
      # reason: it must never constrain a host's resolution, and a new publishing
      # environment should not be blocked by this repository's lockfile. The
      # trade-off is that rendered docs can shift between releases, which is why
      # `mix docs` is a documented step immediately before publishing.
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
