# Manual Overview

This manual is the user-facing guide to TclWire. It is intentionally separate
from the existing reference notes so that the project can keep accurate
implementation documents while gradually building a coherent manual.

## Intended Audiences

- Operators running TclWire services.
- Application authors writing TclOO applications for TclWire.
- Maintainers working on TclWire internals.

## Manual Map

- [Getting Started](getting-started.md): install assumptions, first run, first
  request, and a minimal service.
- [Configuration](configuration.md): TOML files, command-line overrides,
  service tables, application tables, and TLS settings.
- [Running TclWire](running.md): service startup, runtime files, shutdown, and
  operational behavior.
- [Writing Applications](applications.md): application classes,
  `handle_request`, static files, development reloading, and package loading.
- [Application Environments](environments.md): environment contracts,
  worker-scoped command setup, and a minimal custom environment.
- [Request API](request-api.md): `HttpRequest` methods and request-body access.
- [Response API](response-api.md): response construction, helpers, files,
  redirects, ranges, and output behavior.
- [Console](console.md): Unix-domain control socket and administrative
  commands.
- [Logging](logging.md): access logs, error logs, levels, diagnostics, and log
  rotation.
- [FTP and FTPS](ftp.md): FTP service configuration and behavior.
- [Proxy Service](proxy.md): proxy listener configuration and behavior.
- [Architecture](architecture.md): runtime, reactors, agents, TPBA, workers,
  and message passing.
- [Internals](internals.md): internal descriptors, event dictionaries, shared
  state, and unstable implementation details.
- [Testing and Development](testing.md): test runner, test layout, diagnostics,
  and contribution workflow.
- [Glossary](glossary.md): project terminology.

## Drafting Policy

Manual pages should distinguish stable public behavior from implementation
detail. Existing reference documents can be linked directly while chapters are
still skeletal, then folded into the manual where a narrative explanation is
more useful.
