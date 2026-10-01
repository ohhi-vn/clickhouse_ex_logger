alias ClickhouseExLogger.TestContainer

# The suite's ClickHouse is a container, started here rather than in a test
# module, so all of it shares one server. Five modules need ClickHouse; booting
# one per module would cost five ClickHouse startups per run.
#
# This is also where the suite stops tolerating a missing database. The old
# harness excluded `:clickhouse` tests when no server answered and reported
# green — which is precisely how a test that exists to prove the pipeline
# survives a stalled ClickHouse could end up never running. Failing here is the
# point. The four modules that need no database still run without an engine.
TestContainer.start()

Application.put_env(:clickhouse_ex_logger, ClickhouseExLogger.Repo, TestContainer.repo_config())

# The schema goes through the same code path a host application runs, so the
# suite keeps covering `mix clickhouse_ex_logger.migrate`'s target rather than a
# parallel one.
{:ok, _summary} = ClickhouseExLogger.Migration.setup()

ExUnit.start()

ExUnit.after_suite(fn _results ->
  IO.puts(TestContainer.cleanup_hint())
end)
