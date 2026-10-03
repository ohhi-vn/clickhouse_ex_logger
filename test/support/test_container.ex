defmodule ClickhouseExLogger.TestContainer do
  @moduledoc """
  Provisions the ClickHouse the test suite runs against.

  Compiled into the test build only (see `elixirc_paths/1` in `mix.exs`), never
  shipped in the hex package.

  One container is started for the whole suite, from `test/test_helper.exs`.
  That is a deliberate trade: `TestcontainerEx.ExUnit.container/3` with
  `shared: true` would give one container per test *module*, and five modules
  need ClickHouse, so that is five boots per run. The suite already shares a
  database and truncates per test, so one container suits it and costs nothing
  in per-test isolation.

  The container is left running after the suite, and reused by the next one, so
  the suite does not pay ClickHouse's boot on every run. `cleanup_hint/0` says
  how to remove it.

  Note that the `Config` struct this module gets back from `start_container/2`
  reports `reuse: false` even on a run that reused an existing container — the
  engine does not echo that flag — so the harness records the URL itself rather
  than asking the struct.

  The image is pinned to the `26.9` line rather than `latest` because
  `ClickhouseExLogger.Insert` documents itself as verified against that server
  version; `latest` would let the claim rot with no test failing.

  ## Credentials

  The container's `default` user is left password-less, and `repo_config/0`
  says so explicitly.

  That is not an oversight so much as a match for what the library can actually
  do. `ClickhouseExLogger.Migration` builds its connections from
  `AshClickhouse.Repo.config_to_conn_opts/1`, and that function does not carry
  `:username` or `:password` through — so a password-protected ClickHouse cannot
  be authenticated against through this library today, whatever `config` says.
  Giving the container a password would only produce an authentication failure
  that has nothing to do with what these tests are checking.
  """

  @image "clickhouse/clickhouse-server:26.9"
  @database "clickhouse_ex_logger_test"
  @user "default"
  @password ""
  @http_port 8123
  @native_port 9000

  # ClickHouse is not instant. This is the ceiling on how long the suite waits
  # for it, not how long it expects to wait.
  @wait_timeout 120_000

  @doc """
  Starts the container and returns its HTTP URL.

  Fails the calling process rather than returning an error the caller would have
  to interpret: without a ClickHouse there is no suite, and the point of this
  module is that the suite says so instead of quietly skipping.
  """
  @spec start() :: String.t()
  def start do
    export_podman_socket()
    ensure_started()
    engine = select_engine()

    case TestcontainerEx.start_container(config()) do
      {:ok, container} ->
        url = url(container)

        :persistent_term.put(__MODULE__, %{container: container, url: url, engine: engine})
        url

      {:error, reason} ->
        raise """
        could not start the ClickHouse test container (#{@image}).

        #{describe(reason)}

        The suite needs a running container engine. Check:

            podman machine list     # or: docker info
            mix testcontainer_ex.run status
        """
    end
  end

  @doc """
  The container's HTTP URL, as the suite is configured to reach it.
  """
  @spec url() :: String.t()
  def url, do: started().url

  @doc """
  The `:clickhouse_ex_logger, ClickhouseExLogger.Repo` configuration for the container.

  Applied by `test/test_helper.exs` before `ClickhouseExLogger.Migration.setup/1`,
  which reads application env when it builds the connection.
  """
  @spec repo_config() :: keyword()
  def repo_config do
    [url: url(), username: @user, password: @password, database: @database]
  end

  @doc """
  The database name the container serves and the suite writes to.
  """
  @spec database() :: String.t()
  def database, do: @database

  @doc """
  Freezes the container's processes, leaving its network connections open.

  This is what makes a *stalled* ClickHouse reachable from a test. A stopped
  container refuses connections and fails instantly; a paused one accepts them
  and never answers, so each insert blocks until the client's `recv_timeout`.
  That is the condition the batching design claims to survive, and the only way
  to produce it.

  Driven through the engine CLI rather than `TestcontainerEx.container_pause/1`:
  that call reaches the engine over an HTTP request whose URL is
  `http+unix://…` for a Podman machine socket, and Finch rejects that scheme
  outright. The same breakage takes down `TestcontainerEx.Engine.Status.status/0`.
  """
  @spec pause() :: :ok
  def pause, do: engine!("pause")

  @doc """
  Resumes a paused container.
  """
  @spec unpause() :: :ok
  def unpause, do: engine!("unpause")

  defp engine!(action) do
    {cli, id} = engine_cli()

    case System.cmd(cli, [action, id]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        # `unpause` on a container that was never paused is not an error worth
        # failing a test over; anything else is.
        if action == "unpause" do
          :ok
        else
          raise "#{cli} #{action} #{id} failed (#{status}): #{String.trim(output)}"
        end
    end
  rescue
    error ->
      raise "could not run the container engine CLI for #{action}/0: #{inspect(error)}"
  end

  defp engine_cli do
    cli =
      case started().engine do
        e when e in [:docker, :podman] -> Atom.to_string(e)
        _auto -> System.find_executable("podman") || "docker"
      end

    {cli, container_id()}
  end

  @doc """
  The container id, for diagnostics.
  """
  @spec container_id() :: String.t()
  def container_id, do: started().container.container_id

  @doc """
  What to tell a developer about the container the suite left behind.
  """
  @spec cleanup_hint() :: String.t()
  def cleanup_hint do
    "ClickHouse test container #{container_id()} is still running.\n" <>
      "It is reused between runs (see .testcontainer_ex.properties), so this is\n" <>
      "expected. Remove it with:\n\n" <>
      "    podman rm -f #{container_id()}\n"
  end

  # Built by hand rather than through `TestcontainerEx.ClickHouseContainer`,
  # whose wait strategy shells out to `clickhouse-client --port 8123`.
  # `clickhouse-client` speaks the native protocol, so pointing it at the HTTP
  # port fails with `UNEXPECTED_PACKET_FROM_SERVER` and the container never
  # reports ready — verified against this image, where `GET /ping` answers `Ok.`
  # within seconds. The HTTP interface is what this library actually speaks.
  defp config do
    alias TestcontainerEx.Container.Config

    Config.new(@image)
    |> Config.with_exposed_ports([@http_port, @native_port])
    |> Config.with_environment(:CLICKHOUSE_DB, @database)
    |> Config.with_environment(:CLICKHOUSE_USER, @user)
    |> Config.with_environment(:CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT, "1")
    |> Config.with_reuse(true)
    |> Config.with_waiting_strategy(
      TestcontainerEx.HttpWaitStrategy.new("/ping", @http_port,
        timeout: @wait_timeout,
        status_code: 200
      )
    )
  end

  defp url(container) do
    "http://#{TestcontainerEx.get_host(container)}:#{mapped_http_port(container)}"
  end

  defp mapped_http_port(container),
    do: TestcontainerEx.Container.Config.mapped_port(container, @http_port)

  defp started, do: :persistent_term.get(__MODULE__, nil) || raise(not_started())

  defp not_started do
    "the ClickHouse test container has not been started; " <>
      "test/test_helper.exs starts it before the suite runs"
  end

  defp ensure_started do
    case Application.ensure_all_started(:testcontainer_ex) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "could not start :testcontainer_ex: #{inspect(reason)}"
    end
  end

  # `podman machine` forwards its API socket into a per-machine directory under
  # the system temp dir, which moves between machines and macOS releases. The
  # library scans fixed socket paths and will not find it there, so ask Podman
  # where it put this one and export it before anything connects.
  #
  # An explicit `CONTAINER_ENGINE_HOST` always wins, so a developer who knows
  # better is never overridden.
  defp export_podman_socket do
    with nil <- System.get_env("CONTAINER_ENGINE_HOST"),
         nil <- System.get_env("DOCKER_HOST"),
         socket when is_binary(socket) <- podman_socket(),
         true <- File.exists?(socket) do
      System.put_env("CONTAINER_ENGINE_HOST", "unix://#{socket}")
    end

    :ok
  end

  defp podman_socket do
    case System.cmd("podman", [
           "machine",
           "inspect",
           "--format",
           "{{.ConnectionInfo.PodmanSocket.Path}}"
         ]) do
      {path, 0} -> String.trim(path)
      _other -> nil
    end
  rescue
    _error -> nil
  end

  # Auto-detection picks whichever engine binary it finds first, so on a machine
  # with both Docker and Podman installed it can settle on the one whose daemon
  # is not running. Prefer Podman, fall back to auto-detection so a contributor
  # with only Docker is not locked out, and let `CONTAINER_ENGINE` override both.
  defp select_engine do
    if TestcontainerEx.connected?() do
      TestcontainerEx.Server.get_engine(TestcontainerEx)
    else
      requested =
        case System.get_env("CONTAINER_ENGINE") do
          nil -> nil
          name -> String.to_existing_atom(name)
        end

      case connect(requested || :podman) do
        {:ok, engine} -> engine
        {:error, podman_reason} when is_nil(requested) -> fall_back(podman_reason)
        {:error, reason} -> raise no_engine_message(reason)
      end
    end
  end

  defp fall_back(podman_reason) do
    case connect(:auto) do
      {:ok, engine} -> engine
      {:error, _auto_reason} -> raise no_engine_message({:podman, podman_reason})
    end
  end

  # The application may already have started the server — successfully, or in the
  # disconnected mode it falls back to when no engine is up. Either way this has
  # to work, so start it if it is absent and re-point it if it is there.
  #
  # Returns the engine actually connected through, which is not always the one
  # asked for: `:auto` resolves to whatever it finds.
  defp connect(engine) do
    case TestcontainerEx.start_link(engine: engine) do
      {:ok, _pid} -> {:ok, engine}
      {:error, {:already_started, _pid}} -> reconnect(engine)
      {:error, reason} -> {:error, {engine, reason}}
    end
  end

  defp reconnect(engine) do
    case TestcontainerEx.reconnect(engine: engine) do
      {:ok, _resolved} -> {:ok, engine}
      {:error, reason} -> {:error, {engine, reason}}
    end
  end

  defp no_engine_message({engine, reason}) do
    """
    no reachable container engine, so there is no ClickHouse to test against.

      tried:    #{inspect(engine)}
      reason:   #{inspect(reason)}
      detected: #{engine_status()}

    The suite needs one. Start it, then run the suite again:

        podman machine start      # or start Docker Desktop
        podman machine list
        mix testcontainer_ex.run status

    If your engine's socket is somewhere this library does not look, point it
    there yourself:

        export CONTAINER_ENGINE_HOST=unix:///path/to/engine.sock
    """
  end

  defp describe(reason) do
    "reason: #{inspect(reason)}\n\ndetected: #{engine_status()}"
  end

  # A diagnostic must not be the thing that takes the suite down. `status/1`
  # pings the engine over HTTP, and Finch rejects the `http+unix://` form that
  # a Podman machine socket resolves to — so on exactly the machine most likely
  # to need this message, asking for it raises.
  defp engine_status do
    inspect(TestcontainerEx.Engine.Status.status(), pretty: true)
  rescue
    error -> "unavailable (#{inspect(error.__struct__)})"
  catch
    kind, reason -> "unavailable (#{inspect({kind, reason})})"
  end
end
