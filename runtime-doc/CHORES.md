# Chores

TclWire chores are periodic maintenance tasks owned by the chore scheduler.
They run in the scheduler thread. There are no per-chore worker threads:
each chore object decides whether to run on a wakeup and keeps its own status.

The implementation lives in `tcl/chore.tcl`.

## Public Surface

### `::tclwire::Chore`

Abstract TclOO base class for concrete chores.

Concrete chores must inherit from `::tclwire::Chore` and implement:

```tcl
method run {wakeup} {
    # perform the chore
}
```

Concrete chores may override:

```tcl
method should_run {wakeup} {
    return 1
}
```

The base class provides:

```tcl
method name {}
method wakeup {wakeup}
method status {}
```

`wakeup` calls `should_run`. If it returns false, the chore is skipped. If it
returns true, `wakeup` calls `run`.

The base class maintains a status dictionary:

```tcl
state idle|skipped|ran|failed
runs <count>
skips <count>
failures <count>
last_wakeup <wakeup-dict>
last_result <run-result>
last_error <error-message>
```

`last_result`, `last_error`, and `last_wakeup` appear after the corresponding
events happen.

### `::tclwire::ApplicationChore`

Concrete application chores may inherit from `::tclwire::ApplicationChore`
when they need application context. It inherits from `::tclwire::Chore` and
adds constructor support for scheduler-supplied application options.

It provides:

```tcl
method application_id {}
method application_config {}
method pool_key {}
```

### `::tclwire::ServerChore`

Concrete server chores may inherit from `::tclwire::ServerChore` when they
need the runtime configuration snapshot. It inherits from `::tclwire::Chore`
and adds constructor support for scheduler-supplied server options.

It provides:

```tcl
method server_config {}
```

`server_config` returns a registration-time serialized configuration envelope.
Plain server chores that do not need configuration should inherit directly
from `::tclwire::Chore`.

### `::tclwire::chore start config ?specs?`

Starts the scheduler thread.

`config` accepts:

```tcl
chore_interval_ms <milliseconds>
```

The interval defaults to `5000`. The minimum accepted interval is `100`.

`specs` is an optional list of chore spec dictionaries registered immediately
after the scheduler starts.

### `::tclwire::chore register specs`

Registers more chores with a running scheduler.

Each spec is a dictionary:

```tcl
name <stable-name>
package <optional-package-name>
file <optional-tcl-file>
class <optional-class-name>
args <constructor-args-list>
paths <auto-path-directories>
```

`name` is required. Either `class` or `file` is required.

If `package` is present, the scheduler runs `package require` before
constructing the chore. If `file` is present, the scheduler sources it inside
the `::tclwire::chores` namespace. A file can therefore define a chore with a
bare class name such as `oo::class create MyChore {...}`, which becomes
`::tclwire::chores::MyChore`. If `class` is omitted and the file defines
exactly one new subclass of `::tclwire::Chore`, that class is inferred. If the
file defines zero or multiple chore subclasses, registration fails unless
`class` is explicit.

`paths` entries are appended to the scheduler thread's `auto_path` before
package or file loading.

### `::tclwire::configuration tree configuration ?sink?`

Renders a configuration dictionary or envelope as a structured ASCII tree.
With no `sink`, it returns the tree text. With a `sink`, it emits each line to
the command form. If any command word contains the literal substring `%s`, that
substring is replaced with the line; otherwise the line is appended as the last
argument.

Examples:

```tcl
puts [::tclwire::configuration tree $configuration]

::tclwire::configuration tree $configuration \
    [list puts stderr]

::tclwire::configuration tree $configuration \
    [list ::tclwire::logger log_error chore %s info]

::tclwire::configuration tree $configuration \
    [list ::tclwire::io out "%s\n"]

::tclwire::configuration tree $configuration [list apply {{line} {
    ::tclwire::io out [format "%s\n" $line]
}}]
```

### `::tclwire::chore status`

Returns the scheduler status dictionary:

```tcl
running 1
thread_id <scheduler-thread-id>
interval_ms <milliseconds>
sequence <wakeup-count>
chores <list-of-chore-records>
```

Each chore record contains the public spec fields plus:

```tcl
last_status <dispatch-status>
last_wakeup <wakeup-dict>
status <chore-status-dict>
```

Object handles are scheduler-thread-local and are not returned.

### `::tclwire::chore stop`

Stops the scheduler, destroys chore objects in the scheduler thread, and
releases the scheduler thread.

### `::tclwire::chore thread_id`

Returns the scheduler thread id or an empty string when the scheduler has not
been started.

### `::tclwire::chore is_running`

Returns true when the scheduler thread exists.

## Wakeup Dictionary

Every scheduler tick sends this dictionary to each registered chore:

```tcl
sequence <monotonic-wakeup-number>
now_ms <clock-milliseconds>
interval_ms <scheduler-interval>
scheduler_thread_id <thread-id>
```

Chores should use this clock data for their internal run/refusal policy. This
keeps timing decisions tied to the scheduler rather than each chore creating
its own timer.

## Configuration Scopes

TclWire has two configuration scopes for chores:

- server chores, registered once for the runtime;
- application chores, registered once for one application descriptor.

Server chores are for runtime-wide maintenance. Application chores are for
work that is meaningful only in the context of one configured application.

### Server Chores

The `[tclwire]` stanza can register a server chore:

```toml
[tclwire]
chore = "examples/five_minute_chore.tcl"
chore_class = "FiveMinuteLogChore"
```

The server chore path is searched as:

1. current run directory
2. configuration file directory
3. global `libdir`, when configured
4. TclWire project root

The runtime registers the chore with the stable name `server:default`.

Server chores that need configuration should inherit from
`::tclwire::ServerChore`. The scheduler passes a copied configuration envelope
to those classes:

```tcl
type tclwire.server_configuration
version 1
values <normalized-server-config-without-applications>
server_chores <server-chore-specs-without-runtime-context>
application_configs <dict-of-serialized-ApplicationConfiguration-envelopes>
```

This is a snapshot taken when the chore is registered. It is intentionally not
stored as the authoritative configuration in `tsv`; `tsv` remains better
suited for live shared state, counters, and snapshots. A server chore can still
store derived data such as a configuration hash in `tsv` if other threads need
to inspect it.

### Application Chores

Application stanzas can register an application chore with the `chore`
parameter:

```toml
[http."example.test"]
class = "::example::Application"
package = "example::application"
docroot = "www"
libdir = "lib"
chore = "application_maintenance_chore.tcl"
```

The chore path is resolved like application files:

1. run directory
2. application `docroot`
3. effective `libdir`
4. TclWire project root

If the file defines exactly one new `::tclwire::Chore` subclass, the class is
inferred. Otherwise specify:

```toml
chore_class = "ApplicationMaintenanceChore"
```

Application chores automatically start the chore scheduler even when
`chores_enabled` is false.

Application chore inheritance is intentionally restricted. A chore configured
on the default application applies to that default application only; it is not
silently copied to virtual hosts that inherit the rest of the default
descriptor. Configure `chore` in each application stanza that should own an
application chore.

Application chores that need the application context should inherit from
`::tclwire::ApplicationChore`, which itself inherits from `::tclwire::Chore`.
It accepts the scheduler-supplied constructor options and exposes:

```tcl
method application_id {}
method application_config {}
method pool_key {}
```

`application_config` returns a serialized immutable
`::tclwire::ApplicationConfiguration` envelope. Chores that need the object
form can deserialize it inside the scheduler thread.

## Example: Five-Minute Error-Log Chore

The repository includes this example as `examples/five_minute_chore.tcl`:

```tcl
package require tclwire::chore 0.1
package require tclwire::configuration_tree 0.1
package require tclwire::logger::client 0.1

oo::class create FiveMinuteLogChore {
    superclass ::tclwire::ServerChore

    variable every_ms last_run_ms

    constructor args {
        next {*}$args
        set every_ms 300000
        set last_run_ms 0
        catch {
            ::tclwire::configuration tree [my server_config] \
                [list ::tclwire::logger log_error chore %s info]
        }
    }

    method should_run {wakeup} {
        set now [dict get $wakeup now_ms]
        return [expr {$last_run_ms == 0 || ($now - $last_run_ms) >= $every_ms}]
    }

    method run {wakeup} {
        set last_run_ms [dict get $wakeup now_ms]
        ::tclwire::logger log_error chore \
            "five_minute_chore name=[my name] sequence=[dict get $wakeup sequence]" \
            info
        return [dict create logged 1 at_ms $last_run_ms]
    }
}
```

Register it from the `[tclwire]` stanza as a server chore:

```toml
[tclwire]
chore = "examples/five_minute_chore.tcl"
chore_class = "FiveMinuteLogChore"
```

The runtime starts the chore scheduler, sources the chore file in the scheduler
thread under `::tclwire::chores`, constructs
`::tclwire::chores::FiveMinuteLogChore`, and calls it on every scheduler
wakeup. The chore runs only when at least five minutes have elapsed according
to the scheduler's `now_ms` clock.
