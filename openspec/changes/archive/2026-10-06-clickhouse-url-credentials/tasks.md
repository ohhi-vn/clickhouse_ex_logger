# Tasks

## 1. Compose the credentialed URL

- [x] 1.1 In `ClickhouseExLogger.Repo.config/0`, keep the existing missing-keyword-list and non-keyword-list branches unchanged, and add URL composition to the `{:ok, config}` branch: verify `mix test test/clickhouse_ex_logger/repo_config_test.exs` still passes for those two cases.
- [x] 1.2 Add a private composition step that returns the `:url` verbatim when `URI.parse/1` reports a non-empty `userinfo`: verify a test asserting `Repo.config()[:url] == configured_url` for `http://u:p@ch:8123` with `username:`/`password:` also configured.
- [x] 1.3 Add the injection rule — non-empty `:password`, or a `:username` that is present and not `"default"` — writing the credential as `URI.encode(&1, &URI.char_unreserved?/1)` joined by `:` into the URL's `userinfo`: verify tests for "password only, no username" (resolves to `default`), "username and password", "username with empty password", and "username `default` with empty password" (composes to nothing).
- [x] 1.4 Percent-encode both values so a credential containing `@`, `:`, `/`, or a space cannot alter the URL's host, port, or path, and so a non-ASCII value survives: verify a test asserting the parsed result's host and port are unchanged and its `userinfo` decodes back to the original strings.
- [x] 1.5 Raise `AshClickhouse.Error.ConfigurationError` naming `:username` or `:password` when either is present and not a binary, and naming `:url` when it does not parse to a URL carrying a binary host (`URI.parse("localhost:8123")` parses but has no host — verify a test asserts that case is rejected, not accepted): verify each error message names its option.
- [x] 1.6 Assert the composed URL is what the connection layer receives: add a test that `AshClickhouse.Repo.config_to_conn_opts(ClickhouseExLogger.Repo)[:url]` carries the userinfo, which is the seam hackney and `ipv4_only` both depend on.

## 2. Documentation

- [x] 2.1 Rewrite the `@moduledoc` of `ClickhouseExLogger.Repo`: state that `:username` and `:password` are honoured, that the URL's own userinfo wins, that a password-less configuration sends no auth, and that an unusable value fails naming the option. Verify the missing-configuration message still names the config key and does not print a value.
- [x] 2.2 Update `README.md`'s setup section to show that `username:`/`password:` authenticate as written, with no URL-manipulation code, and add the upgrade note that these keys were previously discarded so a host pinning the old behaviour can embed credentials in its URL.
- [x] 2.3 Correct `test/support/test_container.ex`'s "Credentials" note, which currently states that a password-protected ClickHouse cannot be authenticated against through this library, and record that the container stays password-less deliberately: verify the note no longer claims an inability the library no longer has.
- [x] 2.4 Add a `CHANGELOG.md` entry under the unreleased heading recording that `:username`/`:password` now authenticate.

## 3. Verification

- [x] 3.1 Run `mix test test/clickhouse_ex_logger/repo_config_test.exs` and `mix test test/clickhouse_ex_logger/repo_config_test.exs --only clickhouse` is not applicable — confirm the module still passes without a container engine, as its `@moduledoc` claims.
- [x] 3.2 Run the full suite (`mix test`) and confirm no existing test changed behaviour: the suite's container is configured with `username: "default", password: ""`, which under the rule in 1.3 composes to no userinfo, so its requests must be byte-identical to before.
- [x] 3.3 Run `mix format --check-formatted` and `mix compile --warnings-as-errors`, and confirm both are clean. `mix.exs` defines no lint or dialyzer alias, so these are the whole verification surface.