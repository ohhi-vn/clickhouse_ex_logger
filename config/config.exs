import Config

config :ash, default_string_length_count: :codepoints

config :clickhouse_ex_logger, ClickhouseExLogger.Repo,
  url: "http://localhost:8123",
  username: "default",
  password: "",
  database: "clickhouse_ex_logger_dev"

config :logger, level: :info

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
