defmodule ClickhouseExLogger.Event do
  @moduledoc """
  Turns a `:logger` event into a `ClickhouseExLogger.LogEntry` row map.

  Called from `ClickhouseExLogger.Handler`'s `:logger` callback, which runs **in the
  process that logged**. It therefore does no I/O and never raises: a log statement
  must not be able to take down the code that made it.

  ## Message rendering

  Erlang's `:logger` handlers never receive a bare string. The message arrives
  as `{:string, rendered}` when the handler has a formatter configured (the
  `Logger.Formatter` registered alongside the handler in the README — this is
  the normal case, and `rendered` is the text you would see in your console),
  as `{:string, chardata}` when it does not, and as `{:report, report}` for a
  structured message with no formatter. Chardata is rendered with
  `IO.chardata_to_string/1`; anything else — a keyword-list report, a map, a
  struct — is rendered with `inspect/1`, matching what Elixir's own console
  handler does for structured logs.

  Chardata that `IO.chardata_to_string/1` refuses is inspected instead of raised
  on: bytes that are not a valid character sequence, and lists that are not
  well-formed chardata at all. `row/2` does not raise, so a message it cannot
  turn into text is still a row.

  ## Metadata rendering

  The `metadata` column is a ClickHouse `Map(String, String)`, so every value is
  rendered as text:

    * a binary is stored as-is;
    * any other scalar (number, atom, `DateTime`, `Decimal`, …) is stored via
      `to_string/1`;
    * a compound term (map, list, tuple, pid, reference, struct, function) is
      stored as `inspect/1` output behind a `"term:"` marker.

  The marker matters. Without it, a genuine string `"[1, 2]"` and an inspected
  list `[1, 2]` would be indistinguishable when reading logs back. Strip the
  marker and evaluate the remainder to recover the term:

      iex> "term:#{inspect([1, 2])}" |> String.replace_prefix("term:", "") |> Code.eval_string()
      {1, 2}, [1, 2]

  ## Where event fields live

  Depending on the OTP version, `:logger` puts the event's metadata either at the
  top level (`%{mfa: ..., file: ..., line: ...}`) or nested under `:meta`
  (OTP 27+, which is what you get today). Both shapes are handled; `:meta` wins
  when both carry a key.

  ## Reserved metadata keys

  Erlang's own event fields (`:mfa`, `:file`, `:line`, `:time`, `:report_level`,
  …) are lifted into dedicated columns and deliberately left out of the metadata
  map, so a metadata query never duplicates them. `:module` and `:function` are
  derived from `:mfa`, which is what Elixir's `Logger` already documents.

  `:domain` is on that list too. Elixir sets it on every message it logs
  (`[:elixir]`), so it is not user-supplied data, and storing it would add the
  same constant `term:[:elixir]` entry to every row in the table.

  ## The node name does not come from the event

  The `node` column is read from `node/0` — the running system — not from the
  event's metadata, and `:node` is deliberately **not** in the reserved-key list.

  That is a choice about user data. `Logger.info("hi", node: "eu-west")` is a
  user supplying a metadata key, and it keeps landing in the `metadata` map
  exactly as it did before this column existed. Reserving the key would silently
  change what that call does, and would make the column's meaning depend on
  whether some caller happened to set it.
  """

  @typedoc """
  A row shaped like `ClickhouseExLogger.LogEntry`.

  `:node` is `nil` when the system is not distributed, or when a host disabled
  node capture with `:include_node`.
  """
  @type row :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          level: atom(),
          message: String.t(),
          module: String.t() | nil,
          file: String.t() | nil,
          line: integer() | nil,
          function: String.t() | nil,
          metadata: %{optional(String.t()) => String.t()},
          node: String.t() | nil
        }

  @typedoc "The event map `:logger` hands to a handler."
  @type event :: %{required(:mfa) => {module(), atom(), arity()}, optional(atom()) => term()}

  # Erlang's event keys, in the order the OTP documents them. Everything here is
  # represented by its own row column (or derived), so it is not duplicated into
  # metadata.
  @event_keys ~w(
    time gl pid mfa module function file line application domain
    meta ansi_color crash_reason initial_call registered_name
    report report_level time_usec
  )a

  @doc """
  The metadata keys that are stored as their own columns.

  Anything else in an event's metadata is user data and lands in the `metadata`
  map.
  """
  @spec reserved_keys() :: [atom()]
  def reserved_keys, do: @event_keys

  @doc """
  Converts a `:logger` event into a row map.

  Never raises. A value it cannot make sense of is rendered rather than dropped,
  because losing a log row is worse than losing a field.

  ## Options

    * `:include_node` — whether to record the node name. Defaults to `true`.
      See `row/2`.
  """
  @spec row(event(), map() | keyword()) :: row()
  def row(event, opts \\ [])

  def row(event, opts) when is_map(event) do
    {module, function} = source_location(event)

    %{
      id: Ash.UUID.generate(),
      timestamp: timestamp(event),
      level: level(event),
      message: message(event),
      module: module,
      file: string_or_nil(field(event, :file)),
      line: integer_or_nil(field(event, :line)),
      function: function,
      metadata: metadata(event),
      node: node_name(include_node(opts))
    }
  end

  # `node/0` is a plain read of an already-loaded atom — no message, no
  # allocation, no I/O — so it cannot slow the process that logged down or fail it.
  #
  # `:nonode@nohost` is reported as no value rather than stored as a string: it is
  # what an undistributed system (a local `iex`, this test suite) reports, and a
  # stored `nonode@nohost` is indistinguishable from a real host at a glance.
  # Absence also makes distributed rows filterable with `WHERE node IS NOT NULL`.
  defp node_name(false), do: nil

  defp node_name(_include),
    do: if(node() == :nonode@nohost, do: nil, else: Atom.to_string(node()))

  # `row/2` takes either a keyword list or a map, matching `Handler.validate/1`,
  # so both call shapes are supported. Only `false` disables capture: `row/2` is
  # public and callable without `Handler.install/2`'s validation in front of it.
  defp include_node(opts) when is_list(opts), do: Keyword.get(opts, :include_node, true)
  defp include_node(opts) when is_map(opts), do: Map.get(opts, :include_node, true)

  @doc """
  Whether an event should be dropped instead of buffered.

  `ClickhouseExLogger.Buffer` reports its own failures through `Logger`, and those
  reports come back through this handler. The marker lets the handler recognise
  and skip them, so a ClickHouse outage cannot feed itself.
  """
  @spec internal?(event()) :: boolean()
  def internal?(event) when is_map(event) do
    match?({:ok, true}, fetch_meta(event, :clickhouse_ex_logger_internal))
  end

  @doc """
  Renders one metadata value as a string.

  See the module doc for why compound terms get a `"term:"` marker.
  """
  @spec stringify(term()) :: String.t()
  def stringify(value) when is_binary(value), do: value
  def stringify(value) when is_atom(value) or is_number(value), do: to_string(value)
  def stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def stringify(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def stringify(%Date{} = value), do: Date.to_iso8601(value)
  def stringify(%Time{} = value), do: Time.to_iso8601(value)
  def stringify(value) when is_struct(value), do: term(value)
  def stringify(value), do: term(value)

  # --- event fields ------------------------------------------------------

  # Depending on the OTP version, an event carries its metadata either at the
  # top level (`%{mfa: ..., file: ...}`, as the OTP docs describe) or nested
  # under `:meta` (what OTP 27+ actually delivers, and what Elixir's
  # `Logger.metadata/1` values become). Read `meta` first and fall back, so the
  # mapping works on both.
  defp field(event, key) do
    case Map.get(event, :meta) do
      %{^key => value} -> value
      _other -> Map.get(event, key)
    end
  end

  defp timestamp(event) do
    case field(event, :time) do
      usec when is_integer(usec) -> DateTime.from_unix!(usec, :microsecond)
      %DateTime{} = datetime -> datetime
      _other -> DateTime.utc_now()
    end
  end

  # `level` is what the row stores; Erlang always supplies it as one of the
  # eight syslog atoms, but a hand-built event might not, so fall back rather
  # than fail.
  defp level(%{level: level}) when is_atom(level), do: level
  defp level(_event), do: :info

  defp message(event), do: render(Map.get(event, :msg))

  # With a formatter configured (which the handler registration in the README
  # does), `:logger` hands over the *already rendered* message as a binary.
  defp render({:string, message}) when is_binary(message), do: message

  # Without one, an unstructured message arrives as chardata.
  #
  # `row/2` never raises, so both ways this can go wrong are handled here rather
  # than left to the caller: chardata that is not valid Unicode, and chardata
  # that is not a list at all. `IO.chardata_to_string/1` raises
  # `UnicodeConversionError` for the former — notably *not* an `ArgumentError`,
  # which is what this used to rescue and so could never fire.
  defp render({:string, chardata}) when is_list(chardata) do
    if chardata?(chardata) do
      IO.chardata_to_string(chardata)
    else
      inspect(chardata)
    end
  rescue
    UnicodeConversionError -> inspect(chardata)
  end

  # A structured message with no formatter: a keyword list, a map, a struct.
  defp render({_kind, term}), do: inspect(term)
  defp render(nil), do: ""
  defp render(term), do: inspect(term)

  # `IO.chardata_to_string/1` treats any integer >= 0 as a codepoint and any
  # negative integer as a byte. A *report* (keyword list, map) is also a list of
  # terms, so distinguish the two before rendering: only genuine iodata reaches
  # the chardata path.
  #
  # Total over any list, including an improper one: `Enum.all?/2` raises
  # `FunctionClauseError` on `[1 | 2]`, and that raise would escape `row/2`
  # before the rescue above is ever in scope. Walking the cons cells directly
  # keeps a malformed message a rendered message.
  defp chardata?([]), do: true
  defp chardata?([head | tail]), do: chardata_element?(head) and chardata?(tail)
  defp chardata?(_improper_tail), do: false

  defp chardata_element?(element) when is_integer(element), do: true
  defp chardata_element?(element) when is_binary(element), do: true
  defp chardata_element?(element) when is_list(element), do: chardata?(element)
  defp chardata_element?(_element), do: false

  defp source_location(event) do
    case field(event, :mfa) do
      {module, function, arity} when is_atom(module) and is_atom(function) ->
        {inspect(module), format_mfa({module, function, arity})}

      _other ->
        # `Logger.bare_log/3` and translated OTP reports may carry `:module` and
        # `:function` without an `:mfa`. Prefer them, then give up.
        {string_or_nil(field(event, :module)), string_or_nil(field(event, :function))}
    end
  end

  defp format_mfa({_module, function, arity}) when is_atom(function) and is_integer(arity) do
    "#{function}/#{arity}"
  end

  defp format_mfa(_mfa), do: nil

  defp metadata(event) do
    user_meta = Map.get(event, :meta) || %{}

    user_meta
    |> Map.drop(@event_keys)
    |> Map.new(fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp fetch_meta(event, key) do
    case Map.get(event, :meta) do
      %{^key => value} -> {:ok, value}
      _other -> :error
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value) when is_atom(value) and not is_nil(value), do: inspect(value)
  # `:logger` delivers `:file` as a charlist.
  defp string_or_nil(value) when is_list(value),
    do: if(charlist?(value), do: List.to_string(value), else: inspect(value))

  defp string_or_nil(_value), do: nil

  defp charlist?(list) do
    list != [] and Enum.all?(list, &(&1 >= 0 and &1 <= 0x10FFFF))
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp term(value), do: "term:" <> inspect(value, limit: :infinity)
end
