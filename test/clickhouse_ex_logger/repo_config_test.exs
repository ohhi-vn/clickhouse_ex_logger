defmodule ClickhouseExLogger.RepoConfigTest do
  @moduledoc """
  Covers the configuration check in `ClickhouseExLogger.Repo.config/0`.

  That check exists so a host that renamed the dependency without renaming its
  config key gets an error naming the key, rather than a silent connection to
  whatever ClickHouse happens to be on localhost — see `ClickhouseExLogger.Repo`.

  Runs without a container engine, like the other database-free modules: it
  touches only the application environment, never a connection.

  Synchronous, not `async: true`, despite mutating global state being the only
  thing it does. `ClickhouseExLogger.TestServer.repo_config/0` reads the same key
  through `Application.fetch_env!/2`, which raises when the key is absent, and
  `ClickhouseExLogger.TestServerTest` — which is `async: true` — calls it. An
  `async: true` module deleting that key would pull the environment out from
  under it and fail intermittently for a reason that has nothing to do with
  either module. This is the same rule `ClickhouseExLogger.Case` documents for
  the rest of the suite: anything that moves shared global state runs
  synchronously.
  """

  use ExUnit.Case, async: false

  alias ClickhouseExLogger.Repo

  # Stands in for an unconfigured repo: `config/0` returning `[]` is the shape
  # `ClickhouseExLogger.Repo` would have without its override, and it is the
  # shape `config_to_conn_opts/1` turns into a silent localhost connection.
  # Only `config/0` is needed — `config_to_conn_opts/1` calls nothing else — so
  # the behaviour is not declared and the stub stays minimal.
  defmodule EmptyConfigRepo do
    @moduledoc false
    def config, do: []
  end

  setup do
    original = Application.fetch_env(:clickhouse_ex_logger, Repo)

    on_exit(fn ->
      case original do
        {:ok, config} -> Application.put_env(:clickhouse_ex_logger, Repo, config)
        :error -> Application.delete_env(:clickhouse_ex_logger, Repo)
      end
    end)

    :ok
  end

  describe "when the repo is not configured" do
    test "raises rather than falling back to a default connection" do
      Application.delete_env(:clickhouse_ex_logger, Repo)

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      # Names both halves of what the host has to write, because the failure is
      # otherwise indistinguishable from ClickHouse being down.
      assert Exception.message(error) =~ ":clickhouse_ex_logger"
      assert Exception.message(error) =~ "ClickhouseExLogger.Repo"
    end

    test "the raised error is what config_to_conn_opts/1 would otherwise hide" do
      Application.delete_env(:clickhouse_ex_logger, Repo)

      assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      # The check is only load-bearing because of this fallback. An unconfigured
      # repo is exactly the shape below — a repo whose config is `[]` — and
      # without the override it would resolve to localhost rather than raising.
      assert AshClickhouse.Repo.config_to_conn_opts(EmptyConfigRepo)[:url] ==
               "http://localhost:8123"

      assert_raise AshClickhouse.Error.ConfigurationError, fn ->
        AshClickhouse.Repo.config_to_conn_opts(Repo)
      end
    end
  end

  describe "when the repo is configured" do
    test "returns the configured keyword list" do
      config = [url: "http://clickhouse.internal:8123", database: "logs_db"]
      Application.put_env(:clickhouse_ex_logger, Repo, config)

      assert Repo.config() == config
    end

    test "an empty keyword list is still a valid configuration" do
      Application.put_env(:clickhouse_ex_logger, Repo, [])

      assert Repo.config() == []
    end
  end

  describe "when the repo is configured with something other than a keyword list" do
    test "a map raises rather than being read as a config" do
      Application.put_env(:clickhouse_ex_logger, Repo, %{url: "http://localhost:8123"})

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      assert Exception.message(error) =~ "keyword list"
    end

    test "nil raises rather than falling back to a default connection" do
      Application.put_env(:clickhouse_ex_logger, Repo, nil)

      # `Application.get_env/2` cannot tell an unset key from a key set to nil,
      # so this is the case a presence check written with `get_env` would miss.
      assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end
    end
  end

  describe "credentials" do
    # The URL is where the credentials have to go, and that is not a choice this
    # library made: `AshClickhouse.Repo.config_to_conn_opts/1` forwards `:url` and
    # drops `:username`/`:password`, and `ClickHouse.Interface.HTTP.Client`'s
    # `@opts_schema` has no credential key — it would reject one rather than
    # honour it. hackney turns a URL's userinfo into `basic_auth` and nothing else
    # supplies one, so a configured password that never reached the URL was
    # silently discarded and every request arrived as `default`.
    test "a username and password are composed into the URL" do
      configure(url: "http://clickhouse.internal:8123", username: "writer", password: "s3cret")

      assert %URI{userinfo: "writer:s3cret"} = composed_url()
    end

    test "a password with no username authenticates as the server's default user" do
      configure(url: "http://clickhouse.internal:8123", password: "s3cret")

      assert %URI{userinfo: "default:s3cret"} = composed_url()
    end

    # A server can protect `default` and leave an application account
    # password-less. Sending no credentials there authenticates as `default` and
    # is rejected, so the username alone has to be enough.
    test "a non-default username with an empty password still authenticates" do
      configure(url: "http://clickhouse.internal:8123", username: "writer", password: "")

      assert %URI{userinfo: "writer:"} = composed_url()
    end

    test "the documented default configuration composes to no credentials at all" do
      # What every existing host has configured. Composing here would start
      # authenticating all of them against a password-less local server, which
      # they never asked for.
      configure(url: "http://clickhouse.internal:8123", username: "default", password: "")

      assert %URI{userinfo: nil} = composed_url()
    end

    test "a URL with no credentials configured sends no credentials" do
      configure(url: "http://clickhouse.internal:8123")

      assert %URI{userinfo: nil} = composed_url()
    end

    test "a URL that already carries userinfo is used verbatim" do
      url = "http://embedded:secret@clickhouse.internal:8123"

      configure(url: url, username: "writer", password: "s3cret")

      # Verbatim, not re-derived: the host wrote those credentials into the one
      # string they control, and overriding them would break the host that
      # already built its URL this way to work around the gap.
      assert Repo.config()[:url] == url
    end

    test "credentials are percent-encoded so they cannot move the host or port" do
      configure(
        url: "http://clickhouse.internal:8123",
        username: "user name",
        password: "p@ss:w/rd #1"
      )

      uri = composed_url()

      assert uri.host == "clickhouse.internal"
      assert uri.port == 8123
      # `nil` rather than `""` for a URL with no path: what matters is that the
      # password's `/` did not become one.
      assert uri.path in [nil, ""]
      assert URI.decode(uri.userinfo) == "user name:p@ss:w/rd #1"
    end

    test "a non-ASCII credential survives as itself" do
      configure(url: "http://clickhouse.internal:8123", username: "café", password: "naïve")

      uri = composed_url()

      assert URI.decode(uri.userinfo) == "café:naïve"
      assert uri.host == "clickhouse.internal"
    end

    test "the composed URL is what the connection layer receives" do
      configure(url: "http://clickhouse.internal:8123", username: "writer", password: "s3cret")

      # The seam the whole design rests on. `config_to_conn_opts/1` is what
      # `child_spec/1`, the supervised connection, and both of the migration's
      # connections read their `:url` from, so this is what hackney is handed.
      conn_opts = AshClickhouse.Repo.config_to_conn_opts(Repo)

      assert %URI{userinfo: "writer:s3cret"} = URI.parse(conn_opts[:url])
    end

    test "a username that is not a string is rejected rather than dropped" do
      configure(url: "http://clickhouse.internal:8123", username: :writer, password: "s3cret")

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      assert Exception.message(error) =~ ":username"
    end

    test "a password that is not a string is rejected rather than dropped" do
      configure(url: "http://clickhouse.internal:8123", username: "writer", password: 12_345)

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      assert Exception.message(error) =~ ":password"
    end

    test "a URL with no host is rejected, though it parses" do
      # `URI.parse("localhost:8123")` succeeds and reads the port as a scheme.
      # Accepting it would produce a request that fails later as an unreachable
      # server, which is the diagnosis the other checks here exist to prevent.
      configure(url: "localhost:8123", username: "writer", password: "s3cret")

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      assert Exception.message(error) =~ ":url"
    end

    test "a URL that is not a string is rejected" do
      configure(url: :localhost, username: "writer", password: "s3cret")

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      assert Exception.message(error) =~ ":url"
    end

    test "a config that names no URL is left without one" do
      # `config/0` reports what the host wrote. The default belongs to
      # `config_to_conn_opts/1`, which is where a host that omitted `:url` has
      # always got it, and giving this function the same fallback would make the
      # two disagree about a config the host never wrote.
      configure(username: "default", password: "")

      refute Keyword.has_key?(Repo.config(), :url)
    end

    test "the composed URL is not reported through the configuration error" do
      # The error names the option; it must not echo the value, because the value
      # carries the password and this library reports its failures through the
      # logger it is logging to.
      configure(url: "http://clickhouse.internal:8123", password: 12_345)

      error = assert_raise AshClickhouse.Error.ConfigurationError, fn -> Repo.config() end

      refute Exception.message(error) =~ "12_345"
    end
  end

  defp configure(config) do
    Application.put_env(:clickhouse_ex_logger, Repo, config)
  end

  defp composed_url do
    config = Repo.config()

    # `:url` is what the data layer reads, so that is what is parsed here rather
    # than the host's `:url`, which may legitimately have been replaced.
    config |> Keyword.fetch!(:url) |> URI.parse()
  end
end
