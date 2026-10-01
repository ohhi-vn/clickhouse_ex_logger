defmodule ClickhouseExLogger.CoverageTool do
  @moduledoc """
  The project's `:test_coverage` tool: `Mix.Tasks.Test.Coverage` plus a cleanup
  it cannot do for itself.

  Wired in through `test_coverage: [tool: __MODULE__]` in `mix.exs`. Compiled
  into the test build only (see `elixirc_paths/1`), never shipped.

  ## Why this exists

  macOS writes a 4096-byte AppleDouble stub `._name` beside any file carrying an
  extended attribute when the filesystem cannot store the attribute itself. exFAT
  and SMB volumes cannot, and this checkout lives on one, so every beam Mix writes
  arrives with a `._Elixir.<Module>.beam` beside it.

  `Mix.Tasks.Test.Coverage.beams/1` lists the compile directory and keeps every
  file whose extension is `.beam`. There is no option to exclude a name, so a
  stub reaches `:cover.compile_beam/1`, which aborts the whole run:

      ** (exit) an exception was raised:
          ** (CaseClauseError) no case clause matching:
          {:error, :beam_lib,
           {:not_a_beam_file, ".../ebin/._Elixir.ClickhouseExLogger.Insert.beam"}}

  Nothing upstream of that helps. Cleaning `_build` before `mix test` is too
  early — compiling then writes the beams *and* their stubs again — and
  `elixirc_paths/1` is irrelevant, because `Path.wildcard/2` defaults to
  `match_dot: false` and already skips the `._*.ex` files beside the sources.

  ## Why the tool is the right seam

  `Mix.Tasks.Test` calls `tool.start(compile_path, opts)` after compiling and
  immediately before `:cover` looks at the directory, so this is the last point
  at which the stubs can still be removed. Everything else is either too early or
  out of reach.

  On a filesystem that does not write sidecars the walk finds nothing and this is
  a plain delegation.
  """

  @doc """
  Removes AppleDouble stubs from the build tree, then delegates to
  `Mix.Tasks.Test.Coverage.start/2`.

  Returns whatever that returns: `nil`, or a zero-arity function to run after the
  suite finishes.
  """
  @spec start(Path.t(), keyword()) :: (-> any()) | nil
  def start(compile_path, opts) do
    compile_path
    |> stubs()
    |> Enum.each(&File.rm/1)

    Mix.Tasks.Test.Coverage.start(compile_path, opts)
  end

  defp stubs(compile_path) do
    # `match_dot: true` is the whole trick. `Path.wildcard/2` skips dot-prefixed
    # names by default — the same default that keeps `elixirc_paths/0` from
    # compiling `._*.ex` — so a plain `**/._*` pattern matches nothing at all and
    # this silently cleans up zero files.
    compile_path
    |> Path.dirname()
    |> Path.join("**/._*")
    |> Path.wildcard(match_dot: true)
  end
end