# TclWire Console

TclWire starts a Unix-domain console socket for runtime inspection and control.
The global configuration key is `unix_socket`; it defaults to
`/tmp/tclwire.sock`.

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

### `CONN`

Returns active connection accounting data from the shared connection store.
Closed connections are removed from this store. Console socket connections are
recorded with protocol `console`, so they appear in this output while active.

Arguments:

- none: return all connection records;
- `-port <portn>`: return connections for a listener port;
- `-remote <remote-ip>`: return connections for a remote address.

### `LOGROTATE`

Asks the logger agent to close and reopen the configured access and error log
files. This is intended for use after an external log rotation tool has renamed
the active files.

Arguments: none.

### `SHUT`

Requests an orderly runtime shutdown.

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

It uses `tclreadline` for the prompt and Tcllib `report` for tabular output.
Use `EXIT` or Ctrl-D to leave the interactive client.
Single commands can be sent non-interactively:

```sh
tclsh utils/tclwire_console.tcl --command PS
tclsh utils/tclwire_console.tcl --command "CONN -port 8990"
tclsh utils/tclwire_console.tcl PS
tclsh utils/tclwire_console.tcl CONN -port 8990
tclsh utils/tclwire_console.tcl LOGROTATE
tclsh utils/tclwire_console.tcl SHUT
```
