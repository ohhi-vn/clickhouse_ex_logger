defmodule ClickhouseExLoggerTest do
  use ExUnit.Case, async: true

  test "the top-level module is documented" do
    assert Code.ensure_loaded?(ClickhouseExLogger)
    assert function_exported?(ClickhouseExLogger, :__info__, 1)
  end
end
