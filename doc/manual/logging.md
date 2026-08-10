# Logging

This chapter will describe TclWire logging behavior.

## Scope

- Access log and error log files.
- Log levels.
- Global, service, and application logging configuration.
- Logging agent behavior.
- Log rotation through the console.
- Diagnostic logging options.

## Routing

The logger agent receives structured messages keyed by client id and stream
type. HTTP and HTTPS access records use the selected application id after host
dispatch; FTP, FTPS, and proxy access records use the concrete service id such
as `ftp:2121` or `proxy:8992`. If a service or application does not configure
`logfile` or `logerr`, it inherits the global `[tclwire]` paths.

When multiple ids share the same path, the logger opens that file once and
maps each id to the same channel. `LOGROTATE` closes and reopens each unique
filename once, then refreshes all id-to-channel mappings.

## Application API

Application code can continue to log errors with:

```tcl
::tclwire::logger::log_error application "message" warn
```

Inside a Content Generator Agent this uses the logger client created when the
CGA starts; it does not allocate a logger object per call. Applications that
need direct access to the object can use:

```tcl
set logger [::tclwire::logger::getlogger]
$logger log_error application "message" warn
```

## Source Material

- `runtime-doc/CONFIGURATION_OPTIONS.md`
- `tcl/logger_agent.tcl`
- `tcl/logger_client.tcl`
- `tcl/logger_control.tcl`
