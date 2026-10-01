defmodule ClickhouseExLogger.LogEntry do
  @moduledoc """
  One row in the `logs` table.

  `ClickhouseExLogger.Handler` and `ClickhouseExLogger.Buffer` write these for you;
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
  | `node`       | `Nullable(String)` | Node that handled it, or `nil`      |

  ## `node` is absent for a system that is not distributed

  The value is the full node name — `my_app@10.0.0.5` — read from `node/0` while
  the row is built, so two applications sharing one host stay distinguishable.

  It is `nil` in two cases, deliberately. A system that is not distributed
  (`:nonode@nohost`, as in a local `iex` or the test suite) has no host to
  report, and a stored `nonode@nohost` is indistinguishable from a real host name
  at a glance. A host that disabled capture with `:include_node` also has no
  value, but the **column still exists** — the schema is the same either way, so
  a query written against it keeps working and re-enabling capture needs no
  migration.

  Absence is what makes distributed rows filterable in one step:
  `WHERE node IS NOT NULL`.

  ## `id` is an identifier, not a uniqueness constraint

  ClickHouse does not enforce primary keys the way a relational database does;
  it deduplicates by *sorting key*. `id` is therefore here so you can
  cross-reference a specific row (from a `discarded` count, an error message,
  or your own application logs) — not so ClickHouse will reject a duplicate.
  Rows are ordered by `(timestamp, id)`, which is the ordering
  `ClickhouseExLogger.Buffer` guarantees delivery in.

  ## `metadata` values are strings

  The ClickHouse column is `Map(String, String)`, so
  `ClickhouseExLogger.Event` renders every metadata value as text. Compound terms
  — maps, lists, tuples, pids, structs — are stored as `inspect/1` output
  behind a `term:` marker so they can be told apart from genuine strings and
  read back with `Code.eval_string/1`.
  """

  use Ash.Resource,
    data_layer: AshClickhouse.DataLayer,
    domain: ClickhouseExLogger.Domain

  import AshClickhouse.DataLayer.Dsl.Macros

  clickhouse do
    table("logs")
    repo(ClickhouseExLogger.Repo)
    engine("MergeTree()")
    order_by("timestamp")

    # Let ClickHouse batch the insert server-side. `wait_for_async_insert: 1`
    # keeps the request blocking until the data is accepted, so a reported
    # success really does mean the rows are queryable — which the failure
    # reporting in ClickhouseExLogger.Buffer depends on.
    insert_opts(async_insert: 1, wait_for_async_insert: 1)

    # Let ClickHouse batch the insert server-side. `wait_for_async_insert: 1`
    # keeps the request blocking until the data is accepted, so a reported
    # success really does mean the rows are queryable — which the failure
    # reporting in ClickhouseExLogger.Buffer depends on.
  end

  # `public?: true` is required, not decorative: Ash 3 makes attributes private
  # by default, and a private attribute is not an input of any action, so
  # `:create` would reject every field.
  attributes do
    # `writable?: true` because ClickhouseExLogger.Event generates the id and the
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
    # scalar defaults, and ClickhouseExLogger.Event always sends a map — `%{}` for
    # an event with no metadata.
    attribute(:metadata, :map, allow_nil?: false, public?: true)

    # Declared **last** on purpose. `AshClickhouse.Migration.alter_table_cql/2`
    # appends new columns, so a table migrated from an older schema ends up with
    # `node` after `metadata` — exactly this order. Declaring it anywhere else
    # would give a freshly created table a different column order from a migrated
    # one, which is invisible in named `SELECT`s but shows up in `SELECT *` output.
    #
    # No `allow_nil?: false`: the value is genuinely absent for a system that is
    # not distributed (`:nonode@nohost`) and for a host that disabled capture via
    # `:include_node`. `allow_nil?: true` is what makes this `Nullable(String)`,
    # matching `module`, `file`, and `function`.
    attribute(:node, :string, public?: true)
  end

  # No `:update` or `:destroy`: ClickHouse is append-oriented, and mutating
  # existing rows through the data layer means expensive ALTER mutations.
  # Corrections are new rows.
  actions do
    read :read do
      primary?(true)
    end

    # `accept` is required, not decorative. A public attribute is still rejected
    # by `:create` unless the action accepts it, and ClickhouseExLogger.Buffer
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
        :metadata,
        :node
      ])
    end
  end
end
