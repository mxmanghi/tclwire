# TclWire Console

TclWire starts a Unix-domain console socket for runtime inspection and control.
The global configuration key is `unix_socket`; it defaults to
`/tmp/tclwire.sock`.
The global configuration key `debug_connection` defaults to `false`. When it
is `true`, closed connection records are retained in the shared accounting
store for diagnostic console output.

The same value can be set from the command line:

```sh
tclsh tcl/tclwire.tcl --unix-socket /tmp/tclwire.sock
```

The console protocol is line-oriented. A client writes one command line and
receives one newline-terminated JSON response.

## Commands

### `PS`

Returns thread accounting data from the shared accounting store.

Arguments: none.

### `SERVICES`

Returns the configured running services with their service id, protocol, port,
and service description.

Arguments: none.

### `CONN`

Returns active connection accounting data from the shared connection store.
Closed connections are removed from this store unless `debug_connection` is
enabled. Console socket connections are recorded with protocol `console`, so
they appear in this output while active.

Arguments:

- none: return all connection records;
- `-port <portn>`: return connections for a listener port;
- `-remote <remote-ip>`: return connections for a remote address.

When `debug_connection` is enabled by configuration, the response includes
retained closed or failed rows and the close diagnostics `closed_at`,
`close_reason`, and `transport_error`. Table responses also include a
`configuration` object containing `debug_connection`, so clients can infer the
shape from the server-provided configuration metadata.

### `CWORK`

Returns connection worker thread workload rows. This is a connection-focused
view over thread accounting and connection accounting.

Arguments: none.

Columns:

- `worker_id`: connection worker thread id;
- `connection_state`: `active` when at least one live connection is assigned
  to the worker, otherwise `idle`;
- `family`: protocol family, such as `http`, `ftp`, or `proxy`;
- `active_connections`: live connection records currently assigned to the
  worker;
- `cumulative_connections`: accepted connection count since worker creation;
- `combined_workload`: current CWI used by pool selection;
- `connection_keys`: space-separated accounting keys for those live
  connections.

### `CONF`

Returns the effective runtime configuration as a table. Rows use `scope` to
separate global values from `service:<id>` and `host:<host>` values.

Arguments: none.

### `LOGROTATE`

Asks the logger agent to close and reopen the configured access and error log
files. This is intended for use after an external log rotation tool has renamed
the active files.

Arguments: none.

### `SHUT`

Requests an orderly runtime shutdown.

Arguments: none.

### `HELP`

Lists the available commands with a brief description. `HELP` is handled by
the client and does not require a connection to the server.

Arguments: none.

## JSON Responses

Table-style inspection commands return:

```json
{
  "ok": true,
  "type": "table",
  "command": "PS",
  "columns": ["thread_id", "status"],
  "rows": [
    {"thread_id": "tid0x...", "status": "idle"}
  ]
}
```

Successful control commands return:

```json
{
  "ok": true,
  "type": "ok",
  "command": "LOGROTATE",
  "message": "logs reopened"
}
```

Errors return:

```json
{
  "ok": false,
  "type": "error",
  "command": "CONN",
  "error": {
    "code": "bad_arguments",
    "message": "CONN accepts no arguments, '-port <portn>', or '-remote <remote-ip>'"
  }
}
```

## Client

The interactive client is:

```sh
tclsh utils/tclwire_console.tcl --unix-socket /tmp/tclwire.sock
```

It uses `tclreadline` for the prompt and renders tabular output with
CRT-style ASCII borders.
Interactive command history is loaded from and saved to `~/.tclwire-history`;
the file is trimmed to the most recent 200 commands.
Use `HELP` to list commands and `EXIT` or Ctrl-D to leave the interactive client.
Single commands can be sent non-interactively:

```sh
tclsh utils/tclwire_console.tcl --command PS
tclsh utils/tclwire_console.tcl --command "CONN -port 8990"
tclsh utils/tclwire_console.tcl --command CWORK
tclsh utils/tclwire_console.tcl PS
tclsh utils/tclwire_console.tcl CONN -port 8990
tclsh utils/tclwire_console.tcl CWORK
tclsh utils/tclwire_console.tcl LOGROTATE
tclsh utils/tclwire_console.tcl SHUT
```
