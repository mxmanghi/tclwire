# Configuration

This chapter will explain TclWire configuration as a user-facing model.

## Scope

- Configuration precedence: built-in defaults, TOML, and command-line options.
- Global `[tclwire]` options.
- Service tables for HTTP, HTTPS, FTP, FTPS, and proxy listeners.
- HTTP and HTTPS application tables.
- Path resolution rules.
- TLS certificate and key settings.
- Upload and request-body limits.
- Logging and console socket settings.

## Source Material

- `runtime-doc/CONFIGURATION_OPTIONS.md`
- `tclwire.toml.example`
- `tcl/application_configuration.tcl`
