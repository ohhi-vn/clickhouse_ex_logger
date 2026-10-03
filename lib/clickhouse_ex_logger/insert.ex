defmodule ClickhouseExLogger.Insert do
  @moduledoc """
  Writes a batch of rows to ClickHouse.

  ## Why this exists instead of `Ash.bulk_create/4`

  The design calls for the data layer's batched insert, and this module uses the
  data layer's own building blocks for it — but it cannot use
  `Ash.bulk_create/4`, because in `ash_clickhouse` 0.7.3 that path does not work.
  Two separate defects stand in the way, both verified against the installed
  versions (`ash_clickhouse` 0.7.3, `clickhouse` 0.32.0, ClickHouse 26.9):

  1. **`Insert.insert_opts/2` leaks Ash's internal options into the client.**
     `DataLayer.bulk_create/4` computes its client options with
     `Insert.insert_opts(resource, opts)`, which `Keyword.merge`s Ash's bulk
     options (`select:`, `upsert?:`, `return_records?:`, `tenant:`, …) into the
     keyword list handed to `ClickHouse.query/4`. That function validates the
     list and rejects anything it does not know, so every `Ash.bulk_create/4`
     fails with `Invalid keyword given ... upsert?: ["is not a valid key"]`.
     This is client-side and independent of the ClickHouse server version.

  2. **`encode_datetime/2` overflows `DateTime64(6)`.** It converts a `DateTime`
     to an integer count of *microseconds*; the JSON input path reads that as
     *seconds*, so `Numeric value is out of range for DateTime64`.

  This module therefore keeps the data layer responsible for everything
  structural — the qualified table name, the column list and its order, and the
  value encoding — and works around exactly the two points above. The second is
  worked around in `normalize/1`, below.

  ## What that gives up, and what it does not

  Lost: Ash's changeset machinery. That is inert for these rows —
  `ClickhouseExLogger.Event` produces every column from a `:logger` event, the row
  shape is fixed, and there is nothing to coerce, validate, or merge.

  Kept: the resource is still the single source of truth. Column names, column
  order, table qualification, UUID encoding and map encoding all come from
  `ClickhouseExLogger.LogEntry` via the data layer, so the wire format cannot
  drift from the resource definition.

  ## Partial success is reported, not hidden

  A flush is chunked at 1000 rows. When a chunk fails the ones before it are
  already in ClickHouse and cannot be taken back, so `insert/1` returns how many
  rows were committed alongside any error. `ClickhouseExLogger.Buffer` uses it to
  keep `delivered` and `lost` honest.

  ## When to delete this

  If `Insert.insert_opts/2` stops leaking Ash's internal options, and datetime
  encoding matches the server, this module collapses to `Ash.bulk_create/4`.
  Isolating the call here is what makes that a one-place change.
  """

  alias AshClickhouse.DataLayer
  alias AshClickhouse.DataLayer.Dsl
  alias AshClickhouse.DataLayer.Insert, as: DataLayerInsert
  alias ClickhouseExLogger.LogEntry

  # `AshClickhouse.DataLayer` chunks its own inserts at 1000 rows; match it so
  # one buffer flush does not turn into an unexpectedly large single statement.
  @chunk_size 1_000

  @doc """
  Inserts `rows` (row maps shaped like `ClickhouseExLogger.Event.row/2`).

  Returns `{:ok, committed}` or `{:error, message, committed}`, where `committed` is
  how many rows ClickHouse accepted.

  That count is not decoration. One flush is chunked at `#{@chunk_size}` rows and
  stops at the first chunk that fails, but the chunks before it are already
  committed — there is no way to un-insert them. Reporting only `:ok` or
  `{:error, message}` would force the caller to assume a failed flush wrote
  nothing, and it would be wrong by exactly the rows that landed.

  `committed` is always present, including for a failure, and is `0` for a flush
  that failed on its first chunk. There is deliberately no two-element
  `{:error, message}` shape: `ClickhouseExLogger.Buffer` tallies a result against
  these two clauses, and a shape it has no clause for raises inside the only
  process that writes logs.

  Later chunks are not attempted once one fails.
  """
  @spec insert([ClickhouseExLogger.Event.row()]) ::
          {:ok, non_neg_integer()} | {:error, String.t(), non_neg_integer()}
  def insert([]), do: {:ok, 0}

  def insert(rows) when is_list(rows) do
    resource = LogEntry

    # `build_insert_rows/2` looks values up by *string* key
    # (`Map.fetch(row, to_string(name))`), so hand it string keys or every column
    # encodes as nil. It then does the encoding itself, with one exception:
    # timestamps, below.
    {fields, encoded} =
      rows
      |> Enum.map(&normalize/1)
      |> DataLayerInsert.build_insert_rows(resource)

    statement =
      resource
      |> DataLayer.qualified_table()
      |> DataLayerInsert.insert_statement(fields)

    opts = Dsl.insert_opts(resource)

    encoded
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, committed} ->
      case ClickhouseExLogger.Repo.insert_rows(statement, chunk, opts) do
        {:ok, _result} ->
          {:cont, {:ok, committed + length(chunk)}}

        {:error, reason} ->
          {:halt, {{:error, describe(reason)}, committed}}
      end
    end)
    |> case do
      {{:error, message}, committed} -> {:error, message, committed}
      result -> result
    end
  end

  # Workaround 1 is the option-list leak; this covers it plus workaround 2 —
  # string keys, and the timestamp as an ISO-8601 UTC string, which ClickHouse
  # parses at full microsecond precision. Pre-encoding it here means
  # `build_insert_rows/2` sees a binary and passes it through untouched.
  defp normalize(row) do
    row
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update!("timestamp", fn
      %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
      other -> other
    end)
  end

  # `AshClickhouse.Connection.insert_rows/4` wraps only an exception it rescued. When
  # the client *returns* an error — the ordinary path for an unreachable server or a
  # rejected statement — the raw `ClickHouse` error struct comes through
  # unnormalised, so these are the shapes that actually reach here. Every one of them
  # carries the server's or the client's own sentence in `:message`.
  #
  # Extracting that field is what turns
  # `%ClickHouse.DatabaseError{code: "81", message: "…", meta: %{summary: "…"}}` into
  # a line an operator can act on. The whole struct also *contains* the server's text,
  # so anything that only matches on that text cannot tell the two apart — and a
  # connection failure is the failure a host most needs to read.
  defp describe(%{message: message}) when is_binary(message), do: String.trim(message)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
