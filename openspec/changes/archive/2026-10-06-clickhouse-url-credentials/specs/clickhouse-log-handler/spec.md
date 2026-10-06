# Spec Delta

## ADDED Requirements

### Requirement: Configured credentials reach the server

The system SHALL authenticate to ClickHouse with the credentials the host
configures. It SHALL do so by placing them where the connection stack honours
them — in the URL the requests carry — because no layer beneath it accepts a
credential of its own, and SHALL do so internally rather than requiring the host
to compose the URL. A host that configures a username and password SHALL NOT have
to write URL-manipulation code to authenticate.

Credentials SHALL be composed into the URL by percent-encoding each value, so a
password containing characters that are meaningful in a URL — `@`, `:`, `/`, a
space — SHALL be transmitted as that password rather than altering the URL's
host, port, or path. A username or password carrying a non-ASCII character SHALL
be transmitted as that character.

A configured username with no password SHALL authenticate as that user with an
empty password, rather than falling back to the server's own default user. The
system SHALL NOT treat a passwordless configuration as a request to send no
credentials at all: on a server whose default user is protected, sending none is
how a host is silently authenticated as the wrong identity.

The system SHALL NOT alter a URL that already carries a userinfo. A host pointing
`CLICKHOUSE_URL` at a server whose URL embeds its own credentials SHALL have that
URL used verbatim, so that the credentials already in the URL win over the
separate username and password options and are not parsed, overridden, or
doubled.

The system SHALL send no credential header at all when no credential is
configured, so that a password-less local server is not sent an
authentication the host did not ask for.

Every connection the system opens — the supervised one, the one the migration
entry points open, and the one they open with no database bound — SHALL be
authenticated the same way from the same configuration. A host SHALL NOT be able
to migrate against a server its logging cannot reach, or reach it the other way
round.

The composed URL SHALL NOT be reported anywhere the host did not ask for it. It
SHALL NOT be written to a log, an error message, or reported statistics, because
it carries the password in recoverable form, and this system reports its own
failures through the logger it is logging to.

An option that is present but holds a value the system cannot use — a username or
password that is not a string, a URL that is not a URL — SHALL cause the
connection's configuration to fail with an error naming that option, rather than
being silently ignored or producing a request the server rejects much later with
a reason the host cannot connect to their configuration.

#### Scenario: Password-protected server accepts the configured credentials

- **WHEN** a host configures a username and a password for a ClickHouse server
  that requires them, and delivers an event
- **THEN** the request carries those credentials as HTTP basic authentication, and
  the server accepts it rather than answering with an authentication failure

#### Scenario: Password contains characters that are meaningful in a URL

- **WHEN** a host configures a password containing `@`, `:`, `/`, or a space
- **THEN** the request authenticates as that password, and the request still
  reaches the configured host and port rather than a host or path derived from
  the password

#### Scenario: Password contains a non-ASCII character

- **WHEN** a host configures a username or password containing a non-ASCII
  character
- **THEN** the server receives that exact character as the credential, not a
  percent-escaped or mangled form of it

#### Scenario: Username with no password

- **WHEN** a host configures a username and leaves the password empty, against a
  server where that user has no password
- **THEN** the request authenticates as that username rather than as the
  server's default user

#### Scenario: URL already carries its own credentials

- **WHEN** a host configures a URL whose userinfo holds credentials, and also
  configures a separate username and password
- **THEN** the request uses the URL exactly as configured, and the separate
  username and password have no effect on it

#### Scenario: No credentials configured

- **WHEN** a host configures only a URL, with no username and no password
- **THEN** the request carries no authentication header, so a password-less local
  server is not sent credentials the host did not configure

#### Scenario: Migration entry point authenticates identically

- **WHEN** a host runs the migration entry point against a password-protected
  server, including from a release
- **THEN** the migration's connections authenticate with the configured
  credentials, and it succeeds rather than failing with an authentication failure

#### Scenario: Composed URL is not reported

- **WHEN** the system composes a credentialed URL and then reports a failure
  through the logger or reports its statistics
- **THEN** neither output contains the password or any part of the credentialed
  URL

#### Scenario: Credential value is not a string

- **WHEN** a host configures a username or a password that is not a string, such
  as a number or an atom
- **THEN** the configuration fails with an error naming that option, rather than
  dropping the credential and authenticating as the default user

#### Scenario: URL cannot be parsed

- **WHEN** a host configures a `:url` that is not a parseable URL, such as a bare
  hostname with no scheme
- **THEN** the configuration fails with an error naming `:url`, rather than
  producing a request that fails later with a reason the host cannot trace to
  their configuration