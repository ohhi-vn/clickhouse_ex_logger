# Used by "mix format"
#
# The input list is computed rather than globbed because this project lives on a
# volume that recreates AppleDouble (`._*`) sidecar files next to everything it
# writes. Those files match `{config,lib,test}/**/*.{ex,exs}`, are not UTF-8, and
# make `mix format` die with UnicodeConversionError.
inputs =
  ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "priv/**/*.exs"]
  |> Path.wildcard()
  |> Enum.reject(&Path.basename(&1) =~ ~r/^\._/)

[
  inputs: inputs
]