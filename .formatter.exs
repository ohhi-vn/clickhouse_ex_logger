# Used by "mix format"
#
# The input list is computed rather than globbed because this project lives on a
# volume that recreates AppleDouble (`._*`) sidecar files next to everything it
# writes. Those files match `{config,lib,test}/**/*.{ex,exs}`, are not UTF-8, and
# make `mix format` die with UnicodeConversionError.
#
# Each pattern is expanded separately, through `Enum.flat_map/2`. `Path.wildcard/1`
# does **not** take a list of patterns to expand: it takes a single pattern or a
# charlist, so handing it a list of three binaries returns `[]` — silently, with no
# error. The result was an empty `:inputs`, and a `mix format` with no file
# arguments formatted nothing and reported success, so the gate passed on every
# run while `lib/clickhouse_ex_logger/handler.ex` sat unformatted in the repository.
# `test/mix_project_test.exs` asserts the list is non-empty so that cannot come
# back unnoticed.
# `.formatter.exs` is named explicitly rather than reached through a brace group:
# `Path.wildcard/2` defaults to `match_dot: false`, so a `{mix,.formatter}.exs`
# pattern matches `mix.exs` and silently skips the dotfile. The formatter's own
# file should be checked by the formatter like everything else.
inputs =
  [
    ".formatter.exs",
    "mix.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/**/*.exs"
  ]
  |> Enum.flat_map(&Path.wildcard/1)
  |> Enum.reject(&(Path.basename(&1) =~ ~r/^\._/))

[
  inputs: inputs
]
