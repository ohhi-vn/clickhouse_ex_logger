defmodule ClickhouseExLogger.Microbenchmark do
  @moduledoc """
  Times a callable, for the tests that assert a cost budget.

  ## Why the mean and not the fastest run

  A budget asserted on a single call's duration cannot be kept honest in CI. A
  single scheduler preemption, a GC pass, or an unlucky page fault costs far more
  than the work being measured, so the assertion would fail on unchanged code — or
  pass a regression by accident. Neither outcome tells a maintainer anything.

  Averaging over many iterations does not remove that noise, it **dilutes** it: the
  occasional expensive iteration moves the mean by a fraction of itself instead of
  deciding it. Repeated measurements of one unchanged function on this repository's
  suite have varied by about 5% over 50,000 iterations, which leaves room for a
  budget set with real headroom over the expected value.

  So `mean_micros/2` is the only measure this module offers. A caller wanting a
  maximum would be measuring the scheduler.

  ## What the warm-up is for

  The first iterations of any timed function pay costs that are not the function's:
  lazily-loaded code, the first call into a module that has not been resolved yet,
  and the allocator's first passes over fresh memory. Left in, they are amortized
  over a large `iterations` and so contribute a small, constant, one-sided bias.

  The warm-up is small by default — a tenth of the iterations — because a
  disproportionately large warm-up is itself a cost on the test suite's runtime, and
  the bias it is correcting is already small.

  ## What a number from here means, and does not

  It is a **relative** measure: useful for saying that one implementation is cheaper
  than another, or that neither has drifted. It is not a claim about absolute
  microseconds on any machine but this one. A budget derived from a number measured
  elsewhere is arbitrary, which is why the cost tests derive their thresholds the
  same way in the same run — see `ClickhouseExLogger.CostTest`.
  """

  @default_iterations 10_000

  @typedoc "Options accepted by `mean_micros/2`."
  @type options :: [iterations: pos_integer(), warmup: non_neg_integer()]

  @doc """
  Returns the mean wall-clock cost of `fun`, in microseconds per call.

  `fun` is called `iterations` times after being called `warmup` times, and the
  timed region excludes the warm-up. The return value is a float: it does not round
  to zero for a callable that does any work at all, and it does not round to an
  integer, so a caller cannot accidentally compare a truncated value against a
  budget.

  ## Example

      mean_micros(fn -> ClickhouseExLogger.Event.row(event, %{}) end, iterations: 50_000)

  Read as: about 2.5 microseconds per call on the machine that ran it.
  """
  @spec mean_micros((-> any()), options()) :: float()
  def mean_micros(fun, opts \\ []) when is_function(fun, 0) do
    iterations = Keyword.get(opts, :iterations, @default_iterations)
    warmup = Keyword.get(opts, :warmup, max(div(iterations, 10), 1))

    repeat(fun, warmup)
    {elapsed_micros, _result} = :timer.tc(fn -> repeat(fun, iterations) end)

    elapsed_micros / iterations
  end

  # `Enum.each/2` over a descending range iterates. `1..0` is `[1, 0]`, not empty, so
  # a caller passing `:warmup, 0` — or `iterations: 1`, whose default warm-up
  # truncates to 1 — would silently time setup iterations it asked not to run.
  defp repeat(_fun, count) when count <= 0, do: :ok
  defp repeat(fun, count), do: Enum.each(1..count, fn _ -> fun.() end)
end
