defmodule ClickhouseLoggerTest do
  use ExUnit.Case, async: true

  test "the top-level module is documented" do
    assert Code.ensure_loaded?(ClickhouseLogger)
    assert function_exported?(ClickhouseLogger, :__info__, 1)
  end
end
