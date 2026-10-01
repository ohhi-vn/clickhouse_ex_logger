ExUnit.start()

# ClickHouse-backed tests are tagged `:clickhouse`.
#
# With no server reachable, exclude them and say why, rather than reporting
# dozens of connection failures. With a server reachable, create the test schema
# through the same code path a host application uses, so the suite is
# self-contained.
#
# This is test *setup*, not application boot — `clickhouse_logger` itself never
# creates ClickHouse schema at runtime. See `ClickhouseLogger.NoSchemaAtBootTest`.
alias ClickhouseLogger.TestServer

if TestServer.available?() do
  {:ok, _summary} = ClickhouseLogger.Migration.setup()
  ExUnit.configure(exclude: [])
else
  IO.puts("""

  Skipping :clickhouse tests — #{TestServer.unavailable_message()}

  """)

  ExUnit.configure(exclude: [clickhouse: 1])
end
