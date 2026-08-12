# Configuration

This chapter will explain TclWire configuration as a user-facing model.

## Scope

- Configuration precedence: built-in defaults, TOML, and command-line options.
- Global `[tclwire]` options.
- Service tables for HTTP, HTTPS, FTP, FTPS, and proxy listeners.
- HTTP and HTTPS application tables.
- Environment configuration tables.
- Path resolution rules.
- TLS certificate and key settings.
- Upload and request-body limits.
- Logging and console socket settings.

## Source Material

- `runtime-doc/CONFIGURATION_OPTIONS.md`
- `tclwire.toml.example`
- `tcl/application_configuration.tcl`

## Application Aliases

`aliases` can be configured globally under `[tclwire]` or per application under
`[http.<application>]` and `[https.<application>]`. The value is multiline; each
nonblank line is either `URL-path local-path` or `Alias URL-path local-path`.
Relative local paths are resolved under the selected application's `docroot`.
Application aliases are searched before inherited aliases, so applications can
override or extend global/default rules.

## Environment Configuration

Environment configuration is declared separately from global runtime
configuration:

```toml
[env.stdchans]
capture_stderr = true
auto_chunked_on_flush = true

[env.rivet]
UploadMaxSize = 10485760
BeforeScript = "rivet/before.tcl"
```

Each `[env.<name>]` table is an environment-owned dictionary. TclWire does not
validate environment-specific option names, and global `[tclwire]` values are
not copied into environment configuration.

For the `stdchans` environment, `auto_chunked_on_flush = true` lets an
explicit `flush stdout` request chunked HTTP streaming when the response has
not already committed fixed-length headers. The `rivet` environment enables
this `stdchans` behavior by default for Rivet-compatible streaming output;
an explicit `[env.stdchans] auto_chunked_on_flush = false` disables it.

Applications that declare `environment = "..."` carry the effective
environment configuration into their worker-pool configuration. Application
code reads it through
`::tclwire::app::environment_configuration ?environment? ?key?`.

Inside a running application or application environment:

```tcl
set all_environment_config [::tclwire::app::environment_configuration]
set rivet_config [::tclwire::app::environment_configuration rivet]
set upload_limit [::tclwire::app::environment_configuration rivet UploadMaxSize]
```

Calling the command with no arguments returns the current application's full
environment configuration repository. Passing an environment name returns that
environment's effective dictionary. Passing an environment name and key returns
one value from that dictionary. Missing environment names return an empty
dictionary; missing keys in an existing environment configuration are errors.

## Console Socket Access

The console socket normally retains the ownership and mode created under the
runtime process umask. For a systemd service whose operators belong to `adm`,
set its group and permissions explicitly:

```toml
[tclwire]
unix_socket = "/run/tclwire/console.sock"
unix_socket_group = "adm"
unix_socket_permissions = "0660"
```

The account in the unit must be permitted to change a file's group to `adm`.
For a non-root service, add `SupplementaryGroups=adm` to the unit. Ensure the
socket directory is traversable by the intended users as well.
