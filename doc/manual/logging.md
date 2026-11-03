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

## External process resource monitoring

`utils/monitor_process.py` is a Linux-only, standard-library Python 3 collector.
It reads `/proc` from a separate process and does not depend on TclWire's event
loop, broker, shared accounting locks, or logger. Bash could collect these files
too; Python handles parsing, interval calculations, JSON output, and rotation
without launching several commands per sample.

Run it as the same user as TclWire, using the **server PID**, not the PID of a
shell wrapper. For a systemd service, `systemctl show --property MainPID --value
tclwire.service` can supply that PID; check that your unit's main process is
actually TclWire. Replace `12345` below with the verified PID:

```sh
python3 utils/monitor_process.py 12345 \
    --output /tmp/tclwire-resources.jsonl --interval 5
```

For a collector that survives logout:

```sh
nohup python3 utils/monitor_process.py 12345 \
    --output /tmp/tclwire-resources.jsonl --interval 5 \
    > /tmp/tclwire-monitor.out 2>&1 &
```

Use a persistent directory owned by the service user instead of `/tmp` if the
records must survive reboot or temporary-file cleanup. The output directory must
already exist. Newly created logs have owner-only permissions; existing files
retain their permissions. The collector records neither process arguments nor
environment variables.

Every sample is one JSON object on its own line, with a UTC timestamp. It contains:

- Process CPU percentage, user/system CPU ticks, state, and start-time identity.
- Resident and virtual memory, peak resident memory, anonymous/file-backed
  resident memory, and swap, where exposed by the kernel. Memory units are bytes.
- Open file-descriptor count, thread count, and cumulative minor/major faults.
- Cumulative I/O counters and interval rates. `read_bytes`/`write_bytes` describe
  storage I/O accounting; `rchar`/`wchar` also include cached read/write activity.
- Per-thread CPU usage, state, wait channel, faults, and context-switch counters.
  Status counters at process level describe the main thread; per-thread records
  provide the other threads' context-switch counts.
- Explicit errors for unavailable readings, including permission restrictions
  and threads that disappear during collection.

CPU usage uses one logical CPU as 100%, so a process can exceed 100%. The first
sample has a null CPU percentage and no I/O rates because there is no preceding
measurement. Thread IDs and start times identify individual thread incarnations.
Wait channels such as `futex_wait_queue` can suggest sleeping on a synchronization
primitive; they do not establish a deadlock or replace native stack traces. A
wait channel of `0` may indicate unavailable information rather than activity.

Reads are sequential, so a sample is not an atomic snapshot. Kernel memory
accounting can also be approximate. The collector does not include child-process
resource use, network traffic totals, disk free space, or native stack traces.

The default rotation keeps the active file plus five backups, each approximately
20 MiB (a single oversized record can exceed the limit). Use `--max-mib` and
`--backups` to adjust retention; the number of retained days depends on thread
count and interval. `--no-threads` reduces log volume and overhead. Each record
is flushed to the OS, but not fsynced to storage. Disk-write failures terminate
the collector with a nonzero exit status and a message on stderr.

The collector writes a final stop record when the process exits, becomes a
zombie, or its PID is reused. It also stops cleanly on SIGINT/SIGTERM. **Restart
the collector with the new PID whenever TclWire restarts.** It deliberately does
not follow a process by name. For a short capture, use `--count 12` to take twelve
samples. Run `python3 utils/monitor_process.py --help` for all options.

The in-process `diagnostics_enabled` setting complements this collector with
TclWire pool and heartbeat information; it does not enable OS resource sampling
or periodically persist normal diagnostic snapshots.

## Source Material

- `runtime-doc/CONFIGURATION_OPTIONS.md`
- `tcl/logger_agent.tcl`
- `tcl/logger_client.tcl`
- `tcl/logger_control.tcl`
