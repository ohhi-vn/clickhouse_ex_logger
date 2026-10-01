import Config

config :ash, default_string_length_count: :codepoints

config :clickhouse_logger, ClickhouseLogger.Repo,
  url: "http://localhost:8123",
  username: "default",
  password: "",
  database: "clickhouse_logger_dev"

config :logger, level: :info

# `ClickhouseLogger.Handler` writes through the resource's own domain, so
# registering it here is only needed for tooling that enumerates configured
# domains. It also silences Ash's domain-inclusion warning.
config :clickhouse_logger, ash_domains: [ClickhouseLogger.Domain]

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
