# Architecture Discussion Summary

Date: 2026-06-07

## Purpose

This document summarizes the architectural conclusions reached while
discussing the evolution of TclWire into a highly threaded application server.

The discussion focused on:

- Separating Transport from Protocol processing;
- Delegating content generation to specialized application pools;
- Preserving Tcl channel ownership rules;
- Supporting HTTP virtual hosts and pipelining;
- Centralizing thread-pool management;
- Extending the shared thread-status database;
- Centralizing logging;
- Dynamically releasing idle worker resources.

## Current Implementation Versus Future Architecture

In the current implementation, listener-side and worker-side service objects
are different TclOO objects in different Tcl interpreters, although they may be
instances of the same TclOO class.

This is a description of the current implementation, not a required property
of the future architecture.

TclOO objects are interpreter-local. Equivalent objects loaded in multiple
interpreters are not shared objects. The substantial resource cost comes
primarily from:

- Operating-system threads;
- Tcl interpreters;
- Loaded packages and class definitions;
- Application state and caches;
- Connection and request buffers.

The presence of a protocol object in a thread does not imply that the thread
must remain dedicated to one request for the complete request lifetime.

## Transport and Protocol Separation

A separation between Transport and Protocol is feasible.

### Transport Agent

A **Connection/Transport Agent** owns the Tcl channel and performs:

- TCP or TLS channel ownership;
- Nonblocking reads and writes;
- Input and output buffering;
- Flow control and backpressure;
- Connection timeout handling;
- EOF and transport-error handling;
- Orderly connection shutdown.

The Transport Agent should not parse HTTP requests, interpret FTP commands,
select applications, or execute application behavior.

### Protocol Processor

A **Protocol Processor** interprets the byte stream according to a protocol.

For HTTP, it performs:

- request-line parsing;
- header parsing and validation;
- protocol-congruence checks;
- request-completion detection;
- message-framing validation;
- request-size enforcement;
- virtual-host determination from the `Host` header;
- protocol-error response generation;
- creation of an information-rich request representation.

For FTP, the corresponding processor maintains FTP session state and interprets
FTP commands.

## Channel Ownership

Only the Tcl interpreter that owns a channel may perform operations on it.

A thread identifier is not a channel handle and does not grant channel access.
It identifies the execution context to which commands must be sent.

The preferred architecture keeps channel ownership with the Transport Agent.
Application Workers receive a **connection handle** containing routing
information rather than the channel itself.

Such a handle may contain:

```text
connection_id
transport_thread_id
transaction_id
reply_command
```

This allows an Application Worker to return its result without directly
accessing or corrupting transport or protocol state.

## Two-Tier Request Processing

Request processing is divided into two principal stages.

### Tier 1: Protocol Processing

The Protocol Processor:

1. receives bytes from the Transport Agent;
2. recognizes and validates a complete request;
3. responds directly when protocol validation fails;
4. identifies the target virtual host and application;
5. builds a validated request object or dictionary;
6. dispatches it asynchronously to an Application Worker.

### Tier 2: Content Generation

The Application Worker:

1. receives the validated request representation;
2. executes routing and application logic;
3. generates a semantic response;
4. returns the response with its connection and transaction identifiers.

After dispatching a request, the Protocol Processor thread may process later
requests or other connections while content generation proceeds in an
application pool.

Therefore, a Protocol Processor thread is an event-driven execution context,
not necessarily a request-dedicated worker.

## Application-Specific Pools

HTTP application selection can be based on a key such as:

```text
(local endpoint, normalized Host value, path prefix)
```

Different applications or virtual hosts may have different worker pools.

This permits independent resource policies for applications with different:

- latency;
- CPU requirements;
- blocking behavior;
- database dependencies;
- concurrency limits;
- isolation requirements.

Delegating content generation does not necessarily reduce the total number of
threads. Instead, it distributes threads according to workload:

```text
total threads =
    transport/protocol execution contexts
    + application pool 1
    + application pool 2
    + other specialized pools
```

Transport and protocol processing are normally short and event-driven, so
their pools may remain smaller than application pools.

## HTTP Pipelining

The two-tier design permits a Protocol Processor to dispatch several HTTP
requests before earlier content generation has completed.

For example:

```text
request 1 -> application worker A
request 2 -> application worker B
request 3 -> application worker C
```

HTTP/1.1 responses must still be transmitted in request order:

```text
response 1
response 2
response 3
```

Each transaction therefore requires a monotonically increasing sequence number
or transaction identifier.

The connection-owning context must retain:

- an in-flight transaction table;
- response-ordering state;
- completed responses waiting for earlier responses;
- configured backpressure limits.

Required limits include:

- maximum in-flight requests per connection;
- maximum buffered input;
- maximum buffered responses;
- request and body size limits;
- application timeouts;
- connection idle timeouts.

## Request Bodies

Request-body handling may use:

- `in_memory`;
- `spooled_file`;
- `streaming`.

In-memory and spooled bodies can be handed to an Application Worker as complete
request data or descriptors.

A streaming body requires continuing coordination between the Application
Worker and Transport Agent. The underlying channel should remain owned by the
Transport Agent.

Possible body operations include:

```text
body_read
body_copy
body_cancel
body_eof
```

## Response Processing

Application code should produce a semantic response rather than raw
wire-protocol bytes.

The preferred path is:

```text
Application response
    -> Protocol response encoder
    -> ordered byte segments
    -> Transport Agent
```

Protocol validation failures bypass application dispatch:

```text
invalid request
    -> protocol error response
    -> Protocol response encoder
    -> Transport Agent
```

This keeps application code from producing malformed protocol framing.

## Control Plane and Execution Plane

The proposed architecture distinguishes:

```text
Control plane
|-- Runtime Supervisor
|-- Thread-Pool Broker Agent
|-- Shared registries
`-- Logging Agent

Execution plane
|-- Transport Agents
|-- Protocol Processors
`-- Application Workers
```

The control plane creates, supervises, classifies, and observes execution
resources. The execution plane performs network, protocol, and application
work.

## Thread-Pool Broker Agent

A single global **Thread-Pool Broker Agent**, abbreviated **TPBA**, should
manage generic worker pools.

Its thread identifier may be published through:

```tcl
tsv::set tclwire tpba_thread_id $thread_id
```

This value is an internal-service endpoint identifier, not an object handle.

The TPBA should be the sole authority for:

- creating and destroying pools;
- creating and retiring worker threads;
- allocating and releasing workers;
- growing and shrinking pools;
- enforcing pool limits;
- supervising worker health;
- applying restart policy;
- recording lifecycle transitions.

## Pool Descriptors

Pools should be identified by structured descriptors instead of opaque names.

Examples:

```tcl
dict create kind transport endpoint http-main
dict create kind protocol protocol http
dict create kind application application shop virtual_host shop.example
dict create kind application application admin virtual_host admin.example
```

The terminology is:

- **pool descriptor**: structured semantic identity;
- **pool key**: canonical registry key derived from a descriptor;
- **pool instance**: one managed collection of workers;
- **worker role**: transport, protocol, application, logging, or internal.

## Shared Thread Status

Worker threads register their state in the existing thread-shared storage:

```text
::tsv tclwire accounting
```

The existing name `accounting` may become too narrow as the stored data grows.
The information should be separated logically into:

### Thread Registry

Relatively stable identity and classification:

```text
thread_id
pool_key
worker_role
protocol
application
virtual_host
created_at
owner_broker_id
generation
```

### Worker State

Rapidly changing execution observations:

```text
execution_status
current_connection_id
current_transaction_id
current_command
job_started_at
last_activity_at
completed_jobs
failed_jobs
```

### Pool Registry

Pool configuration and aggregate state:

```text
pool_key
descriptor
minimum_workers
maximum_workers
minimum_idle
maximum_idle
idle_timeout
current_workers
idle_workers
queued_jobs
lifecycle_state
restart_policy
```

These schemas may continue to share the same physical `tsv` namespace.

## State Authority

Workers publish observed execution state. The TPBA remains authoritative for
pool and worker lifecycle decisions.

To avoid competing writers for a single status field, the model may distinguish:

```text
execution_status
lifecycle_status
```

or:

```text
reported_status
desired_status
```

Examples:

- a worker reports that it has become `idle`;
- the TPBA reserves it for a job;
- the TPBA marks it `draining`;
- the worker acknowledges termination;
- the TPBA records final termination.

Shared state is principally a registry and observability mechanism. Arbitrary
threads should not allocate, terminate, or reclassify workers by directly
editing it.

## TPBA as Pool Watcher

A separate watcher thread is unnecessary.

Because workers publish their state in shared storage, the TPBA can also
perform the **Pool Watcher** role.

The TPBA periodically:

1. reads a consistent snapshot of thread and pool state;
2. reconciles missing, failed, or stale workers;
3. calculates capacity for each pool;
4. satisfies queued demand and minimum-idle policy;
5. identifies excess idle capacity;
6. selects retirement candidates;
7. marks selected workers as draining;
8. sends termination commands;
9. publishes updated pool statistics.

This control loop may run through `after` callbacks in the TPBA event loop.

## Dynamic Pool Resizing

Pool resource policy may consider:

- idle-worker count;
- queued-job count;
- worker idle duration;
- recent request rate;
- execution latency;
- memory consumption;
- CPU utilization;
- worker age;
- completed-job count;
- failure rate;
- application-specific limits.

The scale-down lifecycle is:

```text
idle -> draining -> terminating -> terminated
```

Only idle workers should normally terminate immediately. A running worker may
enter `draining`, reject new work, complete its current assignment, and then
exit.

Policies require stability controls:

- minimum pool size;
- idle grace period;
- scale-down cooldown;
- scale-up threshold;
- hysteresis;
- maximum retirements per evaluation;
- recent-demand window;
- shutdown timeout.

These controls prevent repeated thread creation and destruction during small
load fluctuations.

## Worker Lifecycle

A useful state model is:

```text
creating
    -> starting
    -> idle
    -> reserved
    -> running
    -> idle

idle or running
    -> draining
    -> terminating
    -> terminated

any live state
    -> failed
```

`reserved` covers the interval between allocation and actual job execution.
`draining` prevents new assignments while permitting current work to finish.

## Central Logging Agent

A dedicated **Logging Agent** thread should receive structured log events
asynchronously.

Example:

```tcl
dict create \
    timestamp [clock microseconds] \
    severity info \
    component protocol \
    thread_id [thread::id] \
    pool_key $pool_key \
    connection_id $connection_id \
    transaction_id $transaction_id \
    message "request validated"
```

The Logging Agent owns:

- output files and channels;
- formatting;
- serialized writes;
- rotation;
- flushing;
- filtering;
- output destinations;
- orderly shutdown draining.

The logging queue must be bounded. Its overload policy should define:

- dropping low-severity events;
- aggregation of repeated messages;
- dropped-event counters;
- preservation of warnings and errors where possible;
- producer waiting limits;
- shutdown flushing.

Logging must not become a global request-processing bottleneck.

## Final Architectural Position

The resulting architecture follows these rules:

1. Transport Agents permanently own client channels.
2. Protocol Processors validate requests and maintain protocol state.
3. Protocol threads are event-driven and are not dedicated to one request.
4. Validated requests are dispatched asynchronously to application-specific
   pools.
5. Application Workers return semantic responses through connection handles.
6. Connection and protocol state preserve response ordering and backpressure.
7. The TPBA is the sole pool and worker lifecycle authority.
8. Workers publish execution observations through shared `tsv` state.
9. The TPBA also acts as the logical watcher for every pool.
10. A centralized Logging Agent serializes asynchronous structured logging.

This design may use more specialized pools than the current implementation,
but it allows each pool to be sized and controlled according to its actual
workload. It separates protocol latency from content-generation latency while
retaining clear channel ownership and centralized resource policy.
