defmodule ClickhouseExLogger.Domain do
  @moduledoc """
  The Ash domain holding `ClickhouseExLogger.LogEntry`.

  You do not need to do anything with this domain, and in particular you do not
  need to add it to your `:ash_domains`. `ClickhouseExLogger.Buffer` writes
  through the resource directly, and the resource names this domain, so as long
  as `clickhouse_ex_logger` is a dependency the write path resolves on its own.

  You only need it if you want to `Ash.read/1` log rows through Ash, which this
  library's own docs show at `ClickhouseExLogger.LogEntry`.
  """

  # `validate_config_inclusion?: false` because this domain is not the host's to
  # register. Ash's check asks whether `ClickhouseExLogger.Domain` appears in the
  # *compiling* project's `:ash_domains`, which for a host adding this package is
  # always `[]` — so the host's build would carry a warning it has no way to
  # resolve, about a domain that belongs to a dependency. The check is read at
  # compile time from the app env, so nothing set at runtime can silence it; this
  # option is the supported way for the module itself to answer it.
  #
  # Scoped to this module on purpose. `config :ash, validate_domain_config_inclusion?: false`
  # would also stop reporting the host's own domains, which is a loss to the host
  # and not this library's decision.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ClickhouseExLogger.LogEntry)
  end
end
