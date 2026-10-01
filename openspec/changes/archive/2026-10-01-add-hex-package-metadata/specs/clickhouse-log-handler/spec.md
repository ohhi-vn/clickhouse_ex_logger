# Spec Delta

## ADDED Requirements

### Requirement: Published package contents

The system SHALL publish a package whose contents are sufficient for a host to
complete the whole documented setup — declare the dependency, compile, read the
introduction and the licence, and create the schema — without needing any file from
the source checkout.

The package SHALL include the versioned migration files the library applies at run
time. Those files SHALL be located through the OTP application's priv directory
rather than through a path relative to the working directory, so that they resolve
to the same files from the library's own checkout and from a host's dependency tree.

A package manifest that omits the priv directory SHALL be treated as a defect rather
than as a reduction in scope: the migration command is the only supported way for a
host to create the schema, so a release whose manifest drops the migrations is a
release whose documented first step cannot run. The build SHALL be verified against
the manifest before it is released, so that this is detected before publication
rather than by the first host that installs the package.

The package SHALL NOT include test-only sources, coverage output, container state,
or the project's planning and change records. Test-only sources compile into the
test build and are not part of the library a host consumes.

#### Scenario: Host runs the migration command from a published dependency

- **WHEN** a host application that depends on the published package runs
  `mix clickhouse_ex_logger.migrate`
- **THEN** the command locates the shipped migration files, creates the `logs` table
  described by the table contract, and reports the schema as up to date on a
  subsequent run

#### Scenario: Package manifest omits the priv directory

- **WHEN** the package manifest is inspected and the priv directory is absent from it
- **THEN** the release is rejected before publication rather than published, because
  the migration command would fail to resolve its migration files in a host's
  dependency tree

#### Scenario: Migration files resolve regardless of working directory

- **WHEN** the migration command is invoked from a directory other than the host
  application's root
- **THEN** it applies the same shipped migrations it applies when invoked from the
  host's root

#### Scenario: Consumer reads the introduction and the licence from the package

- **WHEN** a person installs the package and reads its introduction and licence
  files
- **THEN** those files are present in the installed package and contain the same
  content as the project's

#### Scenario: Manifest excludes build-only and planning content

- **WHEN** the package manifest is inspected
- **THEN** it lists the library sources and its runtime assets, and does not list the
  test-only support sources, coverage output, or the project's change records

### Requirement: Published package metadata

The package SHALL declare a description, a licence, and a set of links identifying
where the project lives, so that a person browsing the package page or the
documentation can reach the source, report a problem, and read the introduction
without knowing anything about the repository in advance.

Every link the package declares SHALL resolve to a publicly reachable location that
the project actually maintains. A link SHALL NOT be declared for a resource the
project does not publish, such as a discussion page or a hosted changelog, because
the metadata is a claim that the destination exists and a dead link is a broken
claim.

The documentation home page SHALL be the project's introduction, so that a reader
arriving at the documentation site is given the same orientation the introduction
gives.

The package SHALL NOT declare suppression for credential scanning over paths the
package does not ship. Suppression exists to keep deliberate test fixtures and
certs out of the scan report; with none such shipped, declaring it would be a
statement that the package contains credentials.

#### Scenario: Person browses the package page

- **WHEN** a person looks up the package on Hex
- **THEN** a description of what the library does and its licence are shown, and a
  link leads to the project's source repository

#### Scenario: Reader follows a source link from the documentation

- **WHEN** a reader follows a source link for a module or function in the published
  documentation
- **THEN** the link resolves to that module's or function's source in the project's
  repository

#### Scenario: Reader arrives at the documentation site

- **WHEN** a reader opens the published documentation
- **THEN** the home page is the project's introduction, including its installation
  and quick-start content

#### Scenario: Declared links are checked against what the project maintains

- **WHEN** the package's declared links are compared against the project's
  repository
- **THEN** every declared link has a corresponding location that exists, and no link
  is declared for a location the project does not host

#### Scenario: Credential scanning is not suppressed

- **WHEN** the package's metadata is inspected
- **THEN** no path is excluded from credential scanning, because the package ships
  no credentials, test fixtures, or certificates that would need excluding

### Requirement: Published package documentation

The library SHALL publish documentation to its documentation host alongside the
package, and that documentation SHALL be built from the sources in the release it
describes. Documentation describing code that was not shipped would send a reader
to functions the installed version does not have.

The documentation build SHALL be runnable from a clean checkout through the standard
Mix documentation task, so that a publisher verifies the documentation locally
before releasing instead of relying on the publishing service to report a broken
build afterwards.

The documentation tooling SHALL NOT be a runtime dependency of the library, so that a
host's compiled release does not carry a tool the host never calls.

The project SHALL state its release procedure in the repository, including how to
inspect the built package's file list before publishing, so that the manifest
requirement above is checked by a repeatable step rather than by inspection at the
moment of release.

#### Scenario: Publisher verifies documentation before releasing

- **WHEN** a publisher builds the documentation from a clean checkout
- **THEN** the documentation task completes successfully and produces a local site
  containing the library's modules and the introduction as its home page

#### Scenario: Documentation is published with the package

- **WHEN** the package is published to Hex
- **THEN** the documentation for that exact version is available on the
  documentation host without the publisher taking a separate manual step

#### Scenario: Host is not burdened by the documentation tooling

- **WHEN** a host application depends on the library
- **THEN** the documentation tooling is absent from the host's runtime dependency
  tree and from the host's release

#### Scenario: Publisher inspects the built package before publishing

- **WHEN** a publisher follows the documented release procedure
- **THEN** the procedure includes building the package, listing the files it contains,
  and confirming the priv directory's migration files are among them, before the
  publishing step is run
