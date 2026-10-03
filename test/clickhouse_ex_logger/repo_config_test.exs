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
end
