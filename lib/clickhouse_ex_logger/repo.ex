defmodule ClickhouseExLogger.Repo do
  @moduledoc """
  ClickHouse connection configuration for log inserts.

  Configure it under your application's config:

      config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
        url: "http://localhost:8123",
        username: "default",
        password: "",
        database: "my_app"

  That is the whole setup. `ClickhouseExLogger.Application` supervises this repo
  and `ClickhouseExLogger.HandlerInstaller` attaches the handler when your
  application starts, so there is nothing to add to your supervision tree and
  nothing to call.

  Set `config :clickhouse_ex_logger, auto_start: false` if you would rather
  supervise it yourself — and then add `ClickhouseExLogger.Repo` to your children
  and call `ClickhouseExLogger.Handler.install/2` once it is up. Do one or the
  other, not both: a ClickHouse client keeps a globally named ETS table per
  connection, so a second one cannot be started in the same VM and your supervisor
  will fail with `ArgumentError: table name already exists`.

  The supported keys are those of `AshClickhouse.Repo`: `:url`, `:username`,
  `:password`, `:database`, `:pool_size`, and `:ipv4_only`. See
  `AshClickhouse.Repo` for their defaults.

  ## Credentials

  `:username` and `:password` authenticate the connection. Set them and this is
  the whole of it:

      config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
        url: "http://clickhouse.internal:8123",
        username: "writer",
        password: System.get_env("CLICKHOUSE_PASSWORD"),
        database: "my_app"

  No URL-manipulation code. Earlier versions accepted these two keys and threw
  them away — the data layer forwards only `:url`, and the client beneath it has
  no credential option — so a password-protected server answered every request
  with `Code: 194 ... Authentication failed`, which reads exactly like an
  outage. They are honoured now.

  Three rules:

    * A URL that already carries credentials of its own
      (`http://user:pass@host:8123`) is used verbatim, and `:username`/`:password`
      have no effect on it. That is the escape hatch if you need to pin the old
      behaviour.

    * A password-less configuration sends no credentials at all. The documented
      `username: "default", password: ""` is a password-less local server, not a
      request to authenticate, so it behaves exactly as it always has.

    * A `:username` that is not `"default"` is enough on its own. A server can
      protect `default` and leave an application account password-less, and
      sending nothing there would authenticate as `default` and be refused.

  The password is percent-encoded into the URL, so one containing `@`, `:` or `/`
  is transmitted as itself rather than moving the request to another host. It is
  never logged: this library reports its own failures through the logger it is
  logging to.

  A `:username`, `:password` or `:url` the system cannot use — one that is not a
  string, or a URL with no host in it — raises at configuration time naming that
  key, rather than being dropped and surfacing later as a delivery failure.

  Every connection is authenticated this way from this one configuration,
  including the ones `mix clickhouse_ex_logger.migrate` and
  `ClickhouseExLogger.Utils.migrate/1` open. There is no second connection that
  authenticates differently.

  ## Missing configuration is an error, not a default

  AshClickhouse's own `config/0` callback returns `[]` when the application
  environment has no entry for this repo, and `config_to_conn_opts/1` then
  fills in `url: "http://localhost:8123"`. That default would let a host that
  misconfigured the key start cleanly and write to whatever ClickHouse happens
  to be on localhost, or report every flush as lost — which reads as an outage
  rather than the configuration mistake it is.

  So `config/0` is overridden here to raise when this repo is not configured.
  The one thing this library's failure modes are not is a wrong destination
  chosen silently, and "ClickHouse is unreachable" is precisely the symptom that
  already means everything else in this pipeline.
  """

  use AshClickhouse.Repo, otp_app: :clickhouse_ex_logger

  # The same values `AshClickhouse.Repo.config_to_conn_opts/1` falls back to, so
  # reading this config before the data layer does not change which destination a
  # host that omitted these keys gets.
  @default_url "http://localhost:8123"
  @default_username "default"

  @impl AshClickhouse.Repo
  @spec config() :: keyword()
  def config do
    case Application.fetch_env(:clickhouse_ex_logger, __MODULE__) do
      {:ok, config} when is_list(config) ->
        case compose_url(config) do
          # Untouched, so that a configuration without `:url` still reads back as
          # the host wrote it. `config_to_conn_opts/1` supplies the default, and
          # this function is not the place to change what a host that omitted the
          # key gets.
          :unchanged ->
            config

          url ->
            Keyword.put(config, :url, url)
        end

      {:ok, other} ->
        raise AshClickhouse.Error.ConfigurationError,
              "Expected the :clickhouse_ex_logger config for #{inspect(__MODULE__)} " <>
                "to be a keyword list, got: #{inspect(other)}"

      :error ->
        raise AshClickhouse.Error.ConfigurationError,
              "ClickhouseExLogger.Repo is not configured.\n\n" <>
                "Add this to your application's config:\n\n" <>
                "    config :clickhouse_ex_logger, ClickhouseExLogger.Repo,\n" <>
                "      url: \"http://localhost:8123\",\n" <>
                "      username: \"default\",\n" <>
                "      password: \"\",\n" <>
                "      database: \"my_app\"\n"
    end
  end

  # The only authentication this connection stack honours is the URL's userinfo.
  #
  # `AshClickhouse.Repo.config_to_conn_opts/1` forwards `:url` and drops
  # `:username`/`:password`, and `ClickHouse.Interface.HTTP.Client` has no
  # credential option at all — its `@opts_schema` would reject one. So the two
  # keys are composed into the URL here, in the one function every connection is
  # built from, rather than in each of the places that opens one.
  #
  # hackney reads `#hackney_url.user` and turns a non-empty user into
  # `basic_auth`, percent-decoding both fields. Encoding here is the exact
  # inverse, which is why a password holding `@` or `:` cannot move the host or
  # the port.
  #
  # Never logged. `config/0` has no logger of its own and nothing downstream
  # prints the value it returns, and it must stay that way: the URL carries the
  # password in recoverable form, and this library reports its own failures
  # through the logger it is logging to.
  defp compose_url(config) do
    url = Keyword.get(config, :url, @default_url)

    unless is_binary(url) do
      raise AshClickhouse.Error.ConfigurationError,
            "Expected :url in the :clickhouse_ex_logger config for " <>
              "#{inspect(__MODULE__)} to be a string, got: #{inspect(url)}"
    end

    uri = URI.parse(url)

    # Checked for a host rather than for having parsed: `URI.parse("localhost:8123")`
    # succeeds and reads the port as a scheme, leaving no host. Accepting that
    # would produce a request that fails later as an unreachable server, which
    # is the one diagnosis this config's other checks exist to prevent.
    unless is_binary(uri.host) and uri.host != "" do
      raise AshClickhouse.Error.ConfigurationError,
            "Expected :url in the :clickhouse_ex_logger config for " <>
              "#{inspect(__MODULE__)} to be a URL with a host, such as " <>
              "\"http://localhost:8123\", got: #{inspect(url)}"
    end

    cond do
      # A URL that brings its own credentials is used verbatim. The host wrote
      # them into the one string they control, and re-deriving them here would
      # mean parsing a secret this library did not write.
      uri.userinfo not in [nil, ""] ->
        url

      not credential_configured?(config) ->
        # Nothing to compose, so do not rewrite what the host wrote. Only a
        # config that actually names `:url` can be given one.
        if Keyword.has_key?(config, :url), do: url, else: :unchanged

      true ->
        %{uri | userinfo: encode_credentials(config)} |> URI.to_string()
    end
  end

  # Only compose something when the host asked for a credential. Injecting on
  # presence instead would start authenticating every existing host, whose
  # documented `username: "default", password: ""` is a password-less local
  # server and not a request for credentials.
  #
  # `:username` alone is enough, because a server can protect `default` and leave
  # an application account password-less; sending no credentials there would
  # authenticate as `default` and be rejected.
  #
  # A non-string counts as configured, so it reaches `encode_credentials/1` and is
  # rejected there rather than being read as "no credential" and silently dropped.
  defp credential_configured?(config) do
    password = Keyword.get(config, :password)
    username = Keyword.get(config, :username)

    blank?(password) == false or
      (blank?(username) == false and username != @default_username)
  end

  defp encode_credentials(config) do
    user = Keyword.get(config, :username) || @default_username
    password = Keyword.get(config, :password) || ""

    [assert_string!(:username, user), assert_string!(:password, password)]
    |> Enum.map_join(":", &encode_component/1)
  end

  # Stricter than hackney's own decoder, and deliberately so. Encoding a
  # character hackney would have accepted literally is harmless; the failure that
  # matters is the reverse — a value encoded too little, which would let a `@` in
  # a password move the host — and unreserved-only cannot produce that.
  defp encode_component(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp assert_string!(_option, value) when is_binary(value), do: value

  defp assert_string!(option, value) do
    raise AshClickhouse.Error.ConfigurationError,
          "Expected #{inspect(option)} in the :clickhouse_ex_logger config for " <>
            "#{inspect(__MODULE__)} to be a string, got: #{inspect(value)}"
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
