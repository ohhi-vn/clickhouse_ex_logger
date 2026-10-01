import Config

config :ash, default_string_length_count: :codepoints

config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
  url: "http://localhost:8123",
  username: "default",
  password: "",
  database: "clickhouse_ex_logger_dev"

config :logger, level: :info

# `ClickhouseExLogger.Handler` writes through the resource's own domain, so
# registering it here is only needed for tooling that enumerates configured
# domains. It also silences Ash's domain-inclusion warning.
config :clickhouse_ex_logger, ash_domains: [ClickhouseExLogger.Domain]

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
