# Functional Components Terminology

This document fixes the vocabulary used for TclWire worker roles, pool
management, and connection handling. It exists because the word "agent" can
refer either to a thread role or to a TclOO object class, and those are not the
same thing in the current implementation.

## Vocabulary

| Term | Meaning |
| --- | --- |
| Worker thread | A Tcl thread/interpreter managed by a `::tclwire::ThreadMaster`. |
| Worker role | The function assigned to a worker thread, such as connection handling or content generation. |
| Connection worker | A worker thread whose role is to host connection-handling objects. |
| CGA worker | A worker thread executing content-generation work for application requests. |
| Connection agent object | A TclOO object such as `::tclwire::HttpConnectionAgent`, `::tclwire::FtpConnectionAgent`, or `::tclwire::ProxyConnectionAgent`. In the current implementation it represents one live connection/channel. |
| ThreadMaster / pool | The owner of worker lifecycle, eligibility, workload records, and worker selection policy for one pool. |
| Metric mixin | A pool-local policy mixin that interprets workload transitions and computes the combined workload index, or CWI. |
| TPBA | The Thread Pools Broker Agent. It routes pool commands and worker notifications but does not own workload policy. |
| Connection descriptor | Worker-local metadata for one live connection, keyed by the worker-side channel identifier. |

In the original functional vocabulary, a "connection agent thread" maps to what
this document calls a **connection worker**. The current TclOO
`ConnectionAgent` class hierarchy names per-connection protocol objects, not
the whole worker role.

## Current Runtime Shape

```text
TPBA
  -> ThreadMaster for connection:http:8990
       -> connection worker thread A
            -> connection_descriptors(channel_key_1)
                 agent = HttpConnectionAgent object #1
            -> connection_descriptors(channel_key_2)
                 agent = HttpConnectionAgent object #2
       -> connection worker thread B
            -> connection_descriptors(channel_key_3)
                 agent = HttpConnectionAgent object #3
```

The worker thread is not a TclOO object. It is a Tcl interpreter running the
worker script created by `TransportReactor`. Inside that thread, each accepted
connection creates one protocol-specific connection agent object.

## Routing Keys

Different layers use different identities:

| Key | Used by | Purpose |
| --- | --- | --- |
| `worker_id` | TPBA, `ThreadMaster`, `TransportReactor` | Identifies a worker thread. |
| `pool_key` | TPBA, workers, reactors | Identifies the thread pool that owns a worker. |
| `channel_key` | Connection worker | Primary key for worker-local connection descriptors. Usually the worker-side channel command name. |
| `agent` | Connection worker | TclOO object command for one connection agent object; used as completion identity. |
| `connection_id` | `TransportReactor`, callbacks | Service-local numeric connection id. |
| `connection_key` | accounting, logs, reactor | Stable accounting key, such as `http:8990#12`. |

The worker keeps the descriptor database keyed by `channel_key`:

```tcl
connection_descriptors($channel_key) -> descriptor
```

Completion arrives as an `agent` object command, so the worker also keeps a
small reverse index:

```tcl
connection_agent_channels($agent) -> $channel_key
```

The descriptor is the authoritative worker-local record. The reverse index is
only a lookup aid.

## Connection Descriptor Contract

Connection descriptors are created through `::tclwire::connection_descriptor`
and stored through `::tclwire::store_connection_descriptor`.

Current descriptor fields:

| Field | Meaning |
| --- | --- |
| `channel_key` | Worker-local channel key for this connection. |
| `agent` | TclOO connection agent object command. |
| `connection_id` | Numeric connection id assigned by the reactor. |
| `connection_key` | Accounting/logging key. |
| `finished_thread` | Reactor thread that receives completion callbacks. |
| `finished_command` | Callback command prefix used when the connection finishes. |
| `pool_key` | Owning connection-worker pool. |

Descriptor helpers:

```tcl
::tclwire::connection_descriptor
::tclwire::store_connection_descriptor
::tclwire::connection_descriptor_for_agent
::tclwire::remove_connection_descriptor
```

These helpers make the descriptor structure part of the worker's internal
contract instead of spreading parallel dictionaries across the worker code.

## Connection Flow

```text
TransportReactor
  accepts socket
  asks TPBA for a worker in the connection pool
  reserves one capacity slot with new-connection-processing
  sends the channel and connection metadata to the selected worker

Connection worker thread
  attaches the channel
  prepares transport, including TLS when configured
  creates one protocol-specific connection agent object for that channel
  stores a channel-keyed descriptor
  notifies TPBA with connection-open

Connection agent object
  owns one channel
  parses and handles protocol events for that channel
  closes the connection when protocol logic is complete

Connection worker thread
  receives connection_agent_finished $agent
  resolves $agent -> channel_key
  removes the descriptor
  notifies TPBA with connection-closed
  calls the reactor completion callback

TransportReactor
  removes the connection from its per-worker maps
  falls back to connection-closed only if the worker did not report it
  releases the worker only when that worker has no active connections left
```

## Workload Ownership

TPBA routes workload notifications but does not interpret them. The pool's
`ThreadMaster`, with its metric mixin, owns the workload database and
eligibility decisions.

Connection-worker workload transitions:

| Transition | Meaning |
| --- | --- |
| `new-connection-processing` | Reactor has synchronously reserved one worker capacity slot. |
| `connection-open` | Worker has successfully created the connection agent object. |
| `connection-closed` | One live connection has closed or one startup reservation has been released. |
| `idle-connection-agent` | Worker has no active connection role left. |
| `thread-start` | Worker thread has been created. |
| `thread-exit` | Worker thread is exiting. |

The connection metric computes:

```text
CWI = max_conn_per_thread * running_workload + cumulative_workload
```

For connection workers:

```text
running_workload    = active or reserved connections
cumulative_workload = accepted connection count
```

A connection worker remains eligible while:

```text
running_workload < max_conn_per_thread
```

## Naming Guidance

To avoid ambiguity:

- Use **worker thread** for the Tcl thread/interpreter.
- Use **worker role** for the functional responsibility assigned to that
  thread.
- Use **connection worker** for a worker thread hosting connection objects.
- Use **connection agent object** for current TclOO instances such as
  `HttpConnectionAgent`.
- Use **agent** only when referring to the existing TclOO object command or
  class names.
