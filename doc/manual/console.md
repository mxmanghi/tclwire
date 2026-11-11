# Console

This chapter will describe TclWire's Unix-domain inspection and control socket.

## Scope

- Console socket configuration.
- Console client usage.
- Process and thread inspection.
- Connection inspection.
- Log rotation.
- Shutdown.

## Service status

Enter `status` (commands are case-insensitive) for a summary of the running
TclWire instance. For a one-shot query:

```sh
tclsh utils/tclwire_console.tcl --command STATUS
```

The summary shows the process PID, uptime formatted as `12d 07:02:03`, configured
service count, total application threads, connection agents, and connection
worker threads. Uptime starts when runtime startup succeeds and resets on stop.

The table lists each configured application and its virtual-host aliases,
including applications with zero workers. `Threads` counts created, idle,
allocated, and running workers; `Busy` counts allocated and running workers.
Terminating workers are excluded. Aliases share an application pool and are
listed together, so their worker counts are not added more than once.

Connection agents are open or closing protocol-agent objects. Console clients,
pending accepts without an agent, and retained closed/failed records are excluded.
Connection workers are the threads hosting those agents; one worker can host
several agents. These are runtime accounting counts, not OS process thread counts.

`STATUS` accepts no arguments. Its JSON response uses the usual table format,
with columns `application_id`, `hosts`, `threads`, and `busy_threads`, plus a
`summary` object. Snapshots are collected sequentially and can overlap connection
or thread turnover. The command queries the pool broker synchronously, so it is
an inspection command, not an independent watchdog for a blocked broker.

## Source Material

- `runtime-doc/CONSOLE.md`
- `utils/tclwire_console.tcl`
- `tcl/console_reactor.tcl`
- `tcl/console_connection_agent.tcl`
