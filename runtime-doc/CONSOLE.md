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

Arguments:

- none: return all thread records;
- `-family <family>`: return only one thread family.

The console client renders the PS columns with shorter labels:

- `Thread`: thread id;
- `Status`: current state;
- `Family`: protocol or execution family;
- `Workload`: current running workload;
- `Cumulative WL`: historical workload;
- `Run ms`: last completed run duration in milliseconds;
- `Last Run`: last run start time;
- `Created`: accounting record creation time;
- `Command`: current or most recent command;
- `Host`: current or most recent HTTP Host value.

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

The console client renders the CONN columns with shorter labels:

- `Connection`: connection accounting key;
- `Status`: current connection state;
- `Protocol`: protocol family;
- `Service`: service id;
- `Port`: listener port;
- `Host`: remote peer host;
- `Remote Port`: remote peer port;
- `Worker`: assigned worker thread id;
- `Last Transaction`: current or most recent transaction id;
- `Command`: current or most recent protocol command;
- `Count`: request count;
- `Input`: bytes received;
- `Output`: bytes sent;
- `Started`: connection open time.

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

Client-local command. Loads the configured TOML file and prints a configuration
as an ASCII tree.

Arguments:

- none: construct and print the selected `::tclwire::ApplicationConfiguration`;
  the selected application is `--application <id>` when supplied, otherwise the
  configured `default_application`;
- `<name>`: print the application configuration for application id `<name>`;
  if no application with that id exists, print the environment configuration
  named `<name>`.

The client accepts these options for local configuration inspection:

- `--config <path>`: TOML configuration file to load; when omitted, the client
  uses the connected server's `config_file` value when available, otherwise it
  falls back to `tclwire.toml.example`;
- `--application <id>`: application id to inspect; defaults to the configured
  `default_application`.

This command does not require a live server connection. If the client can
connect to the console socket and `--config` was not supplied, it asks the
server for `SERVERCONF` and derives the local TOML path from the server's
`global config_file` row. If the client cannot connect, it reports the
connection error and continues so `CONF`, `HELP`, and `EXIT` remain available.

Examples:

```sh
tclsh utils/tclwire_console.tcl --config tclwire.toml.example --command CONF
tclsh utils/tclwire_console.tcl --config tclwire.toml.example --application hello --command CONF
tclsh utils/tclwire_console.tcl --config tclwire.toml.example --command "CONF hello"
```

### `SERVERCONF`

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
tclsh utils/tclwire_console.tcl --command SERVERCONF
tclsh utils/tclwire_console.tcl --config tclwire.toml.example --command CONF
tclsh utils/tclwire_console.tcl PS
tclsh utils/tclwire_console.tcl CONN -port 8990
tclsh utils/tclwire_console.tcl CWORK
tclsh utils/tclwire_console.tcl SERVERCONF
tclsh utils/tclwire_console.tcl LOGROTATE
tclsh utils/tclwire_console.tcl SHUT
```
