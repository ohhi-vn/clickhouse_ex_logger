import Config

# The suite gets its ClickHouse from a container started by
# `ClickhouseExLogger.TestContainer`, so these values are only a fallback for the
# four modules that never touch a database. `test/test_helper.exs` overwrites
# them with the container's real host and port before any test runs.
config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  username: System.get_env("CLICKHOUSE_USER", "default"),
  password: System.get_env("CLICKHOUSE_PASSWORD", ""),
  database: System.get_env("CLICKHOUSE_TEST_DATABASE", "clickhouse_ex_logger_test")

config :logger, level: :info

# `podman machine` forwards its API socket into a per-machine directory under the
# system temp dir, which differs per machine and per macOS release.
# `testcontainer_ex` scans a fixed list of socket paths and does not look there,
# so it needs to be told. This has to happen here, in config, because Mix loads
# config before it starts any application — `test/test_helper.exs` runs after
# `:testcontainer_ex` has already booted and failed to find an engine.
#
# An explicit `CONTAINER_ENGINE_HOST` or `DOCKER_HOST` always wins, so a
# developer who already exports one is never overridden.
case {System.get_env("CONTAINER_ENGINE_HOST"), System.get_env("DOCKER_HOST")} do
  {nil, nil} ->
    socket =
      try do
        {path, 0} =
          System.cmd("podman", [
            "machine",
            "inspect",
            "--format",
            "{{.ConnectionInfo.PodmanSocket.Path}}"
          ])

        path = String.trim(path)
        if File.exists?(path), do: path
      rescue
        _no_podman -> nil
      end

    if socket, do: System.put_env("CONTAINER_ENGINE_HOST", "unix://#{socket}")

  _already_set ->
    :ok
end
