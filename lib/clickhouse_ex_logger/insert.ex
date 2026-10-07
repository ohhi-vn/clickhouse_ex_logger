defmodule ClickhouseExLogger.Insert do
  @moduledoc """
  Writes a batch of rows to ClickHouse through `Ash.bulk_create/4`.

  ## Why this is a module and not a single `Ash.bulk_create/4` call

  It uses the data layer's bulk create — the resource remains the single source of
  truth for the table, its columns, their order, and the value encoding. What it
  adds is a chunk loop, and the loop is an accounting requirement, not a
  workaround: `AshClickhouse.DataLayer.can?(:bulk_create_with_partial_success)` is
  `false`, and the data layer's own chunked `bulk_create/3` returns only an error
  when a later chunk fails. One `Ash.bulk_create/4` over a whole flush would
  therefore lose the count of rows an earlier chunk already committed, and
  `ClickhouseExLogger.Buffer` credits `delivered` from exactly that count. Calling
  `Ash.bulk_create/4` once per 1000-row chunk keeps the count in this module's
  hands.

  A flush is chunked at 1000 rows and stops at the first chunk that fails.
  Chunks before it are already in ClickHouse and cannot be taken back, so
  `insert/1` returns how many rows were committed alongside any error. `Buffer`
  uses it to keep `delivered` and `lost` honest.

  Each chunk is all-or-nothing: `Ash.bulk_create/4` is called with
  `stop_on_error?: true`, which aborts on the first row the resource rejects
  before the data layer is called, and a data layer error fails the whole
  `INSERT`. So a chunk either commits every row in it or none, and `committed` is
  the sum of the fully-successful chunks before the failure.

  Every batch this module writes goes through the resource's `:create` action, so
  a row malformed for the resource — a non-UUID `id`, a missing `timestamp` — is
  rejected by the resource's own validation and reported here as a failed chunk,
  rather than being sent to ClickHouse.
  """

  alias ClickhouseExLogger.LogEntry

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
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, committed} ->
      case Ash.bulk_create(chunk, LogEntry, :create, bulk_opts()) do
        %Ash.BulkResult{status: :success} ->
          {:cont, {:ok, committed + length(chunk)}}

        %Ash.BulkResult{errors: errors} ->
          {:halt, {{:error, describe(errors)}, committed}}
      end
    end)
    |> case do
      {{:error, message}, committed} -> {:error, message, committed}
      result -> result
    end
  end

  # `return_records?: false` skips building records nobody reads, and
  # `return_errors?: true` is what makes a reason available for the report.
  # `stop_on_error?: true` is what makes a chunk all-or-nothing: without it Ash
  # writes the rows it can and reports the rest as errors, which would leave
  # committed rows uncounted. `batch_size` matches this module's chunk size so
  # one call here is one data layer batch.
  defp bulk_opts do
    [
      batch_size: @chunk_size,
      return_records?: false,
      return_errors?: true,
      stop_on_error?: true
    ]
  end

  # The reason an operator reads. `Ash.bulk_create/4` reports failures as Ash
  # error classes, which wrap the server's or the client's own sentence one or
  # more levels down, so the useful text is the leaf `:message`, not the
  # container's. Walking `:errors` before `:message` is what keeps a ClickHouse
  # outage from being reported as an opaque inspection of an internal struct —
  # and a connection failure is the failure a host most needs to read.
  defp describe(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(&messages/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> case do
      [] -> "ClickHouse rejected the insert"
      messages -> Enum.join(messages, "; ")
    end
  end

  defp messages(%{errors: errors} = error) when is_list(errors) and errors != [] do
    case Enum.flat_map(errors, &messages/1) do
      [] -> leaf_message(error)
      messages -> messages
    end
  end

  defp messages(error), do: leaf_message(error)

  defp leaf_message(%{message: message} = error) when is_binary(message) do
    case Map.get(error, :field) do
      field when is_atom(field) and not is_nil(field) -> ["#{field} #{message}"]
      field when is_binary(field) -> ["#{field} #{message}"]
      _missing -> [message]
    end
  end

  defp leaf_message(message) when is_binary(message), do: [message]
  defp leaf_message(error) when is_exception(error), do: [Exception.message(error)]
  defp leaf_message(other), do: [inspect(other)]
end
