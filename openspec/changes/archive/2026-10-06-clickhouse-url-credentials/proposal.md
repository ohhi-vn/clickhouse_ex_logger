# Proposal

## Why

A host cannot authenticate this library against a password-protected ClickHouse
today. `AshClickhouse.Repo.config_to_conn_opts/1` forwards only `:url` and drops
`:username`/`:password`, and the `clickhouse` client has no credential options of
its own — hackney derives basic auth solely from the URL's userinfo. So the
documented configuration keys are accepted and then silently discarded: every
request arrives as `default`, and a server that protects that user answers
`Code: 194 ... Authentication failed`.

The symptom is indistinguishable from an outage. Delivery failures are reported
and counted as lost, exactly as they are when ClickHouse is down, so a
misconfiguration looks like an infrastructure problem. The only working setup
today is for the host to compose the credentialed URL itself in
`config/runtime.exs` — twenty lines of URI surgery that every host has to
rediscover and re-maintain.

## What Changes

- `ClickhouseExLogger.Repo.config/0` composes the effective URL: when the
  configured `:url` carries no userinfo and credentials are configured, the
  username and password are percent-encoded into the URL's userinfo, which is the
  one place the data layer and the client underneath it both honour.
- A URL that already carries userinfo is left verbatim, so a host pointing at a
  server whose URL embeds its own credentials keeps working without this parsing
  or overriding them.
- Credentials are injected only when a non-default username or a non-empty
  password is configured. A host on `username: "default", password: ""` — the
  documented default — sees no change on the wire.
- An option present but not a string, or a `:url` that is not a parseable URL, is
  reported as an error naming that option rather than producing a URL that fails
  later during event delivery.
- The composed URL is reported nowhere: it is derived inside `config/0` and never
  logged, so a password cannot reach a log file through this path.
- `ClickhouseExLogger.Repo`'s documentation, the README's setup and configuration
  sections, and the test container's note are corrected to state that `:username`
  and `:password` are honoured and how.

Not breaking: no configuration key changes name, meaning, or default, and no
host's requests change unless it configures credentials that were previously
discarded.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. The change is additive within `clickhouse-log-handler`: nothing an existing
host observes changes unless it configures credentials, which today do nothing.

### Existing capability gaining a requirement

- `clickhouse-log-handler`: a new requirement that the configured credentials
  reach the server as HTTP basic auth, that a URL carrying its own userinfo is
  left alone, and that an unusable credential value is reported as an error
  naming the option.

## Impact

- `lib/clickhouse_ex_logger/repo.ex` — `config/0` composes the URL; the missing
  and non-keyword-list checks stay as they are.
- `test/clickhouse_ex_logger/repo_config_test.exs` — covers composition,
  precedence, and the invalid-value errors. Runs without a container engine, like
  the module it tests.
- `README.md`, and the `@moduledoc` of `ClickhouseExLogger.Repo` — the documented
  contract.
- `test/support/test_container.ex` — its credentials note currently says a
  password-protected ClickHouse cannot be authenticated against; that becomes
  false.
- No new dependency, no schema change, no change to the migration entry points:
  they read the same `config/0`, so both the supervised connection and the
  migration's bootstrap connection gain the credentials from one place.