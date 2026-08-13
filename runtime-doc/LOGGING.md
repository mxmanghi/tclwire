# Logging API

This document describes the logging facility available to TclWire application
code. It is deliberately separate from the logger control API: applications
produce log messages; runtime startup, shutdown, and rotation are owned by the
runtime supervisor.

## Getting the Current Logger

Each Content Generator Agent (CGA) creates one logger client when the worker
starts. Application code running in a request can retrieve that client with:

```tcl
set logger [::tclwire::logger::getlogger]
```

The client is already associated with the selected application id. Do not
create a `::tclwire::logger::Client` per request or per message.

`getlogger` is only valid while TclWire has an active application/CGA logger.
It reports `no TclWire logger client is active` outside that context.

## Writing Messages

Use `log_error` for diagnostic and application-error messages:

```tcl
$logger log_error application "unable to open cache entry" warn
```

Its arguments are:

```tcl
$logger log_error <source> <message> ?<level>? ?<context>?
```

`source` identifies the emitting component (for example `application`,
`authentication`, or `database`). `level` defaults to `error`. The resulting
line is written to the error-log stream and has the form:

```text
<timestamp> <source> level=<level> <message>
```

For compatibility, application code may call the equivalent convenience
command:

```tcl
::tclwire::logger::log_error application "unable to open cache entry" warn
```

It delegates to the active logger returned by `getlogger`.

Use `log` for a message on the access-log stream:

```tcl
$logger log "cache_refresh=completed entries=42" info
```

Its arguments are:

```tcl
$logger log <message> ?<level>? ?<context>?
```

The client id is prepended to an access-log message. `write` and `write_error`
are lower-level alternatives that write directly to the access and error
streams respectively; they do not apply log-level filtering. Prefer `log` and
`log_error` in application code.

## Levels and Filtering

The accepted levels, from least to most severe, are:

```text
trace8 trace7 trace6 trace5 trace4 trace3 trace2 trace1
debug info notice warn error crit alert emerg
```

TclWire writes a message only when its severity is at least the effective
threshold. The threshold is selected from global `tclwire.log_level`, then a
service or application override, then a matching host override. In normal CGA
use the logger supplies the application context automatically. The optional
`context` argument is a dictionary and is useful only to runtime components
that need explicit `service_id`, `application_id`, or `host` routing context.

## Output Routing and Delivery

The selected application id routes messages to that application's `logfile`
and `logerr` paths. Paths not configured by the application inherit the global
`tclwire.logfile` and `tclwire.logerr` values.

Writes are queued asynchronously to the Logging Agent. A successful logger
method call means the message was accepted for enqueueing; it does not wait for
disk I/O. If the Logging Agent is not running, a write reports an error instead
of silently discarding the message.

## Boundaries

Applications must not call `::tclwire::logger::start`, `stop`, `reset`, or
`rotate`. Those are lifecycle/control operations for the runtime supervisor
(with rotation exposed through the console's `LOGROTATE` command).

## Related Material

- `tcl/logger_client.tcl` — application and producer-side API.
- `tcl/logger_agent.tcl` — Logging Agent stream and file handling.
- `tcl/logger_control.tcl` — lifecycle and per-client file mapping.
- `runtime-doc/CONFIGURATION_OPTIONS.md` — logging configuration keys.
- `runtime-doc/INTER_THREAD_COMMUNICATION.md` — cross-thread delivery model.
