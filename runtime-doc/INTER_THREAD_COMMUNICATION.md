# Inter-Thread Communication

This document summarizes the current TclWire thread relations and message
passing pathways implemented under `tcl/`.

The central rule is that TclOO objects and channels are interpreter-local.
Threads exchange Tcl values and commands with `thread::send`; they do not share
live object instances. A thread identifier is a routing endpoint, not authority
to use another thread's channels or objects.

## Thread Roles

```text
Runtime / main event loop
    |
    +-- Logging Agent thread
    |
    +-- Thread-Pool Broker Agent (TPBA) thread
    |       |
    |       +-- connection-agent worker pools
    |       |
    |       +-- application Content Generator Agent pools
    |
    +-- Transport Reactor objects
    |
    +-- Console Reactor object
```

### Runtime Thread

The runtime thread starts and stops the infrastructure:

- `::tclwire::logger::start` creates the Logging Agent thread.
- `::tclwire::tpba::start` creates the TPBA thread.
- `TransportReactor` instances create listener sockets for HTTP, HTTPS, FTP,
  FTPS, and proxy services.
- `ConsoleReactor` owns the Unix-domain console listener.

The runtime thread stores infrastructure endpoints in the shared Tcl thread
variable array `tclwire`, notably `tpba_thread_id`, `logger_thread_id`, and
`logger_levels`.

### TPBA Thread

The Thread-Pool Broker Agent owns the pool registry. Callers send synchronous
requests to it through:

```tcl
::tclwire::tpba request $command_dict
```

That API performs:

```tcl
thread::send $tpba_thread_id \
    [list ::tclwire::tpba::agent_execute_command $command_dict]
```

The request dictionary contains an `operation`, such as `create_pool`,
`pool_key`, `acquire_worker`, `release_worker`, `remove_worker`,
`thread_workload_changed`, `resize_pool`, `pool_status`, `pool_thread_ids`,
`list_pools`, `shutdown_pool`, or `destroy_pool`. The response is a dictionary with `ok`,
`correlation_id`, `result` on success, or `error` and `errorcode` on failure.

The TPBA thread owns `ThreadMaster` objects. Each `ThreadMaster` owns the
policy and lifecycle for one worker pool and starts workers with
`thread::create`.

Workers do not call `ThreadMaster` directly. When a worker observes a workload
transition it calls:

```tcl
::tclwire::tpba notify_workload_transition $pool_key $transition_id
```

The client-side helper sends this TPBA command:

```tcl
dict create \
    operation thread_workload_changed \
    notification [list [::thread::id] $pool_key $transition_id]
```

The notification is strictly `{thread_id pool_key transition_id}`. The TPBA
validates that the pool exists and that the reporting thread is owned by that
pool before forwarding the transition to the pool's `ThreadMaster`.

### Connection-Agent Workers

Each accepted service connection is assigned to a connection-agent worker from
a TPBA-managed pool.

The worker owns the accepted client channel and the connection-affine TclOO
agent object:

- `HttpConnectionAgent`
- `FtpConnectionAgent`
- `ProxyConnectionAgent`

The base `ConnectionAgent` handles channel configuration, readable events,
timeouts, close notification, and the generic completion callback.

### Application Workers

HTTP requests are dispatched to Content Generator Agent (CGA) workers from
application-specific pools. A CGA constructs an application object and an
`HttpRequest` wrapper around a copied request descriptor.

Application workers never own the client channel. They send ordered output
events back to the connection-agent thread.

### Logging Agent

Any thread can enqueue log lines by calling the logger client API. The client
looks up `logger_thread_id` from shared state and sends asynchronous write
commands to the Logging Agent.

### Console Reactor

The console reactor runs in the runtime thread. Console connections are
handled by `ConsoleConnectionAgent` objects in that same interpreter rather
than through TPBA worker pools. Console commands inspect shared accounting
state and can schedule runtime shutdown with `after idle`.

## Shared State

The `tclwire` thread-shared variable array is initialized by
`tcl/shared_state.tcl`. It is used for small pieces of shared coordination
state:

| Key | Purpose |
| --- | --- |
| `tpba_thread_id` | Current TPBA thread endpoint. |
| `logger_thread_id` | Current Logging Agent thread endpoint. |
| `logger_levels` | Global, service, and host log level configuration. |
| `accounting` | Thread lifecycle ledger keyed by Tcl thread id. |
| `connections` | Active connection ledger keyed by connection key. |
| `timestamp` | Shared-state lifecycle marker. |

Access to shared state goes through `tsv::lock` in the accounting and shared
state APIs. Larger request and response payloads are passed as Tcl values in
`thread::send` messages instead of being stored in shared mutable state.

## Message Pathways

### Infrastructure Startup

```text
runtime thread
    |
    | thread::create
    v
TPBA thread
    |
    | thread::send package/source/init commands
    v
::tclwire::tpba::agent_initialize

runtime thread
    |
    | thread::create
    v
Logging Agent thread
    |
    | thread::send source/init commands
    v
::tclwire::logger::agent_initialize
```

Startup uses synchronous `thread::send` calls so initialization errors are
reported to the caller before the endpoint id is published in shared state.

### Pool Control

```text
caller thread
    |
    | synchronous thread::send
    v
TPBA thread
    |
    | ThreadMaster method call
    v
pool registry / worker lifecycle
```

Pool control is request/response oriented. `TransportReactor` uses it to create
and destroy connection-agent pools and to acquire or release connection-agent
workers. `ApplicationDispatcher` uses it to derive application pool keys,
create application pools, destroy them, and acquire CGA workers.

Workers also send request/response messages to the TPBA, but only for worker
lifecycle and workload notifications:

```text
worker thread
    |
    | ::tclwire::tpba notify_workload_transition $pool_key $transition_id
    v
TPBA thread
    |
    | validate {thread_id pool_key transition_id}
    v
ThreadMaster thread_workload_changed
```

These messages update pool workload accounting and can return a worker to the
idle set. They do not carry accepted channels, request descriptors, response
data, or application output.

### Accepted Transport Connection

```text
TransportReactor listener callback
    |
    | after idle
    v
TransportReactor dispatch_accept
    |
    | ::tclwire::tpba request {operation acquire_worker ...}
    v
connection-agent worker id
    |
    | thread::detach channel
    | synchronous thread::send $worker {thread::attach channel}
    | asynchronous thread::send $worker {start_connection_agent ...}
    v
ConnectionAgent object in worker thread
```

The accepted channel is detached from the listener interpreter and attached in
the worker interpreter before the connection agent starts. After this handoff,
only the worker thread performs I/O on that channel.

The startup command also sends a completion callback route:

```tcl
[list [self] connection_finished $pool_key]
```

plus the listener/runtime thread id. The connection-agent worker stores both
values and uses them when the connection closes.

After the connection agent is constructed, the worker reports:

```tcl
::tclwire::tpba notify_workload_transition $pool_key connection-open
```

If startup fails before the agent is ready, its completion callback identifies
that no connection was opened. The reactor then reports
`connection-reservation-cancelled` to release the reserved capacity.

### Connection Completion

```text
ConnectionAgent close
    |
    | ::tclwire::connection_agent_closed
    v
connection-agent worker thread
    |
    | ::tclwire::tpba notify_workload_transition $pool_key connection-closed
    v
TPBA routes workload change to the connection pool metric
    |
    | asynchronous thread::send listener_thread callback
    v
TransportReactor connection_finished
    |
    | removes connection from per-worker maps
    | fallback connection-closed if an established connection did not report release
    | connection-reservation-cancelled if startup never opened the connection
    |
    | ::tclwire::tpba request {operation release_worker ...}
    v
TPBA release boundary
```

The connection-agent worker removes its local descriptor, reports
`connection-closed`, then reports completion to the listener with a flag saying
whether the workload slot was released and whether startup completed. The
listener-side reactor callback owns the live connection map and uses those
values to avoid double-decrementing normal closes while explicitly cancelling
startup-failure reservations. The TPBA's
concurrent-connection metric decrements the worker's running workload and
returns the worker to the idle set when no connections remain. The callback
also logs the close snapshot and calls `release_worker` as an idempotent pool
release boundary.

### HTTP Request Dispatch

```text
HttpConnectionAgent
    |
    | parse complete request bytes
    | build request descriptor
    v
ApplicationDispatcher
    |
    | ::tclwire::tpba request {operation acquire_worker pool_key app:*}
    v
CGA worker id
    |
    | asynchronous thread::send $worker {::tclwire::cga::execute ...}
    v
Content Generator Agent
```

The request descriptor is a Tcl dictionary copied to the CGA thread. It
contains protocol fields, connection metadata, transaction id, the connection
thread id, and the connection-agent object command name as routing metadata.

The object command name is valid only in the connection-agent interpreter. The
CGA does not invoke it directly; it sends it back to the owning thread as data.

### HTTP Application Output Return Path

```text
CGA / application code
    |
    | ::tclwire::io response/header/out/flush/complete/close_connection/fail
    v
::tclwire::io send_event
    |
    | asynchronous thread::send connection_thread_id
    v
::tclwire::route_application_output agent_id transaction_id event
    |
    v
HttpConnectionAgent application_output
    |
    | encode/write response bytes on owned client channel
    v
client
```

Application output events are ordered dictionaries:

| Field | Meaning |
| --- | --- |
| `type` | Event kind: `response`, `http_header`, `output`, `flush`, `no_body`, `complete`, `close_connection`, or `error`. |
| `transaction_id` | HTTP transaction handled by the connection agent. |
| `output_sequence` | Monotonic sequence number starting at 1. |
| `stream` | Currently `stdout`. |
| `data` | Event payload, if any. |
| `flags` | Event-specific metadata. |

The connection agent rejects out-of-order events by comparing
`output_sequence` with the transaction's expected next value. This preserves
response ordering even though delivery is asynchronous.

For non-chunked responses, the connection agent accumulates output until
`complete`, then serializes and closes the connection. For chunked responses,
it commits headers and writes chunks as output events arrive.
The `close_connection` event skips response serialization and closes the
client channel.

### Application Worker Release

```text
CGA finally block
    |
    | ::tclwire::tpba notify_workload_transition $pool_key request-processed
    v
TPBA thread
    |
    v
ThreadMaster records workload and returns worker to idle state
```

The CGA reports `request-processed` in a `finally` block after ending the
output transaction and destroying request/application objects. The TPBA's plain
workload metric increments cumulative workload, clears running workload, and
returns the worker to the idle set.

Application and connection worker scripts also report `thread-exit` before
removing their accounting record during interpreter shutdown. Application
workers additionally request `remove_worker` so their pool no longer retains a
stale owned-thread entry.

### Logging

```text
producer thread
    |
    | logger client method call
    v
logger client
    |
    | asynchronous thread::send logger_thread_id
    v
Logging Agent thread
```

Content Generator Agents create one `::tclwire::logger::Client` during worker
initialization and expose it to application code through
`::tclwire::logger::getlogger`. The compatibility application call
`::tclwire::logger::log_error` delegates to that active CGA logger.

Log writes are fire-and-forget. Log level configuration is read from shared
state before the asynchronous write is enqueued.

Log rotation and logger shutdown are control operations and use synchronous
`thread::send` from the logger control API.

### Shutdown

Shutdown is a mix of synchronous control and asynchronous worker requests:

- Runtime shutdown calls stop methods on reactors and control agents.
- `TransportReactor stop` sends `::tclwire::stop_connection_agent`
  asynchronously to active connection-agent workers, then waits briefly for
  completion callbacks.
- TPBA pool destruction sends `demand_thread_exit` asynchronously to workers
  through their `ThreadMaster`.
- TPBA and logger agent shutdown use synchronous `thread::send` to run their
  shutdown procedures, then wait until the target thread exits.

Worker scripts define `demand_thread_exit` locally. Connection-agent workers
first stop any active connection agent, then release their Tcl thread.

## Message Types by Direction

| From | To | Mechanism | Payload | Synchronous |
| --- | --- | --- | --- | --- |
| Runtime/control caller | TPBA | `thread::send` | TPBA command dictionary | Yes |
| Runtime/control caller | Logging Agent | `thread::send` | rotate/shutdown command | Yes |
| Logger client | Logging Agent | `thread::send -async` | write command and line | No |
| TransportReactor | Connection-agent worker | `thread::send`, `thread::send -async` | channel attach, `start_connection_agent` command | Mixed |
| Connection-agent worker | TransportReactor thread | `thread::send -async` | completion callback | No |
| HttpConnectionAgent | CGA worker | `thread::send -async` | `::tclwire::cga::execute` command and request descriptor | No |
| CGA worker | HttpConnectionAgent thread | `thread::send -async` | application output event dictionary | No |
| Connection-agent worker | TPBA | `thread::send` | `thread_workload_changed` notification: `connection-open`, `connection-closed`, `idle-connection-agent`, `thread-exit` | Yes |
| TransportReactor | TPBA | direct request | fallback `connection-closed` for an established connection, or `connection-reservation-cancelled` for failed startup/dispatch | Yes |
| CGA worker | TPBA | `thread::send` | `thread_workload_changed` notification: `request-processed`, `thread-exit`; optional `remove_worker` | Yes |
| ThreadMaster | Worker thread | `thread::send -async` | `demand_thread_exit` or submitted command | No |
| Any worker | Shared accounting | `tsv::lock` APIs | thread and connection status fields | Immediate shared-state update |

## Ownership and Lifetime Rules

- Client channels are owned by exactly one interpreter at a time.
- The listener thread owns a newly accepted channel only until it detaches the
  channel and the selected connection-agent worker attaches it.
- Connection-agent TclOO objects are invoked only in their owning worker
  interpreter.
- Application objects and `HttpRequest` wrappers are short-lived objects local
  to a CGA request execution.
- Request descriptors and output events are copied Tcl values.
- Shared accounting records are mutable shared state and must be accessed
  through the accounting API.
- Pool policy and worker ownership live in the TPBA thread, even though worker
  status is mirrored into shared accounting.
- Workers may publish observed workload transitions, but the TPBA remains the
  authority that validates ownership and applies pool lifecycle/accounting
  effects.

## Error and Backpressure Behavior

The current message-passing model is mostly asynchronous after dispatch:

- If an accepted connection cannot be assigned to a worker, the listener closes
  the accepted channel.
- If application dispatch fails, `HttpConnectionAgent` produces a `404` for an
  unknown host or `503` for pool/dispatch failure.
- If an application output event is invalid or out of order, the connection
  agent aborts the application response. If headers are still uncommitted it
  sends a `500`; otherwise it closes the connection.
- If the connection-agent thread is gone while an application tries to emit
  output, the CGA output bridge raises an error and emits failure handling in
  the CGA execution path.
- TPBA pool exhaustion is reported as an error dictionary to the synchronous
  caller.

There is no cross-thread channel sharing and no shared mutable request object.
Backpressure is therefore expressed at coarse boundaries: worker-pool
availability, connection close/error, and per-connection response ordering.

## Current HTTP End-to-End Flow

```text
client socket readable
    |
    v
HttpConnectionAgent readable
    |
    v
HttpProtocolSession parses complete request
    |
    v
HttpConnectionAgent starts TransactionDescriptor
    |
    v
ApplicationDispatcher selects application and CGA pool
    |
    v
TPBA acquires CGA worker
    |
    v
thread::send -async ::tclwire::cga::execute
    |
    v
CGA creates application and HttpRequest
    |
    v
application emits output through ::tclwire::io
    |
    v
thread::send -async ::tclwire::route_application_output
    |
    v
HttpConnectionAgent validates event sequence and writes response
    |
    v
connection closes and worker completion releases pool slot
```
