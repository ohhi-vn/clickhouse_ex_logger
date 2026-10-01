defmodule ClickhouseLogger.LogEntry do
  @moduledoc """
  One row in the `logs` table.

  `ClickhouseLogger.Handler` and `ClickhouseLogger.Buffer` write these for you;
  you only need this resource when you want to read log rows back through Ash.

  ## Column layout

  | Attribute   | ClickHouse type | Meaning                                  |
  | ----------- | --------------- | ---------------------------------------- |
  | `id`         | `UUID`          | Unique identifier for this row            |
  | `timestamp`  | `DateTime64(6)` | When the event was logged (UTC)           |
  | `level`      | `String`        | Erlang severity, e.g. `"info"`           |
  | `message`    | `String`        | The rendered log message                  |
  | `module`     | `String`        | Calling module, or `nil`                 |
  | `file`       | `String`        | Calling file, or `nil`                   |
  | `line`       | `Int64`         | Calling line, or `nil`                   |
  | `function`   | `String`        | Calling function/arity, or `nil`         |
  | `metadata`   | `Map(String, String)` | Log metadata, values stringified  |

  ## `id` is an identifier, not a uniqueness constraint

  ClickHouse does not enforce primary keys the way a relational database does;
  it deduplicates by *sorting key*. `id` is therefore here so you can
  cross-reference a specific row (from a `discarded` count, an error message,
  or your own application logs) — not so ClickHouse will reject a duplicate.
  Rows are ordered by `(timestamp, id)`, which is the ordering
  `ClickhouseLogger.Buffer` guarantees delivery in.

  ## `metadata` values are strings

  The ClickHouse column is `Map(String, String)`, so
  `ClickhouseLogger.Event` renders every metadata value as text. Compound terms
  — maps, lists, tuples, pids, structs — are stored as `inspect/1` output
  behind a `term:` marker so they can be told apart from genuine strings and
  read back with `Code.eval_string/1`.
  """

  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: ClickhouseLogger.Domain

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table("logs")
    repo(ClickhouseLogger.Repo)
    engine("MergeTree()")
    order_by("timestamp")

    # Let ClickHouse batch the insert server-side. `wait_for_async_insert: 1`
    # keeps the request blocking until the data is accepted, so a reported
    # success really does mean the rows are queryable — which the failure
    # reporting in ClickhouseLogger.Buffer depends on.
    insert_opts(async_insert: 1, wait_for_async_insert: 1)

    # Let ClickHouse batch the insert server-side. `wait_for_async_insert: 1`
    # keeps the request blocking until the data is accepted, so a reported
    # success really does mean the rows are queryable — which the failure
    # reporting in ClickhouseLogger.Buffer depends on.
  end

  # `public?: true` is required, not decorative: Ash 3 makes attributes private
  # by default, and a private attribute is not an input of any action, so
  # `:create` would reject every field.
  attributes do
    # `writable?: true` because ClickhouseLogger.Event generates the id and the
    # `:create` action accepts it; `uuid_primary_key` is read-only by default.
    uuid_primary_key(:id, public?: true, writable?: true)

    attribute(:timestamp, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:level, :atom, allow_nil?: false, public?: true)
    attribute(:message, :string, allow_nil?: false, public?: true)

    attribute(:module, :string, public?: true)
    attribute(:file, :string, public?: true)
    attribute(:line, :integer, public?: true)
    attribute(:function, :string, public?: true)

    # No Ash `default:` here on purpose: ClickHouse DDL generation only accepts
    # scalar defaults, and ClickhouseLogger.Event always sends a map — `%{}` for
    # an event with no metadata.
    attribute(:metadata, :map, allow_nil?: false, public?: true)
  end

  # No `:update` or `:destroy`: ClickHouse is append-oriented, and mutating
  # existing rows through the data layer means expensive ALTER mutations.
  # Corrections are new rows.
  actions do
    read :read do
      primary?(true)
    end

    # `accept` is required, not decorative. A public attribute is still rejected
    # by `:create` unless the action accepts it, and ClickhouseLogger.Buffer
    # writes every column.
    create :create do
      primary?(true)

      accept([
        :id,
        :timestamp,
        :level,
        :message,
        :module,
        :file,
        :line,
        :function,
        :metadata
      ])
    end
  end
end
