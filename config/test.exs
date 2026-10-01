import Config

config :clickhouse_logger, ClickhouseLogger.Repo,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  username: System.get_env("CLICKHOUSE_USER", "default"),
  password: System.get_env("CLICKHOUSE_PASSWORD", ""),
  database: System.get_env("CLICKHOUSE_TEST_DATABASE", "clickhouse_logger_test")

config :logger, level: :info
