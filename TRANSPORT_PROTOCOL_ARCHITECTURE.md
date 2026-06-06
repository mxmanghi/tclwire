# Transport and Protocol Architecture

## Feasibility

A separation between Transport and Protocol is possible, and the proposed
two-tier request-processing design is coherent.

The critical design rule is:

> Only the component that owns a Tcl channel may perform channel operations.
> Other components communicate with it by messages.

A thread identifier does not grant access to a connection. It identifies the
thread to which commands concerning that connection must be dispatched.

## Proposed Component Model

```text
Listener
   |
   v
Connection/Transport Agent  <-->  Protocol Processor
                                      |
                                      v
                              Application Dispatcher
                                      |
                                      v
                               Application Worker
                                      |
                                      v
                              Response description
                                      |
                                      v
Connection/Transport Agent
```

## Transport Agent

A **Transport Agent** owns exactly one accepted connection, or a controlled set
of accepted connections managed by one event-loop thread.

Its responsibilities are limited to:

- owning the TCP or TLS channel;
- performing nonblocking byte reads and writes;
- maintaining input and output buffers;
- enforcing flow control and backpressure;
- handling connection timeouts;
- performing orderly shutdown;
- reporting EOF and I/O errors;
- preserving response ordering;
- exposing a message-oriented interface to the Protocol Processor.

A Transport Agent should not understand:

- HTTP methods;
- HTTP headers;
- FTP commands;
- routing;
- virtual hosts;
- application behavior.

## Protocol Processor

A **Protocol Processor** interprets bytes according to a specific application
protocol.

For HTTP, its responsibilities include:

- parsing the request line;
- parsing and validating headers;
- determining message boundaries;
- enforcing request and header size limits;
- validating `Content-Length`;
- validating `Transfer-Encoding`;
- detecting request completion;
- selecting a virtual host from the `Host` header;
- constructing an immutable request description;
- generating protocol-error responses;
- assigning a transaction sequence number.

For FTP, a Protocol Processor instead maintains FTP session state and
interprets command lines.

HTTP and FTP can share the same architectural boundary between Transport and
Protocol, but they do not necessarily need to implement the same detailed
protocol API.

## Application Dispatcher

The **Application Dispatcher** maps a validated request to an application pool.

For HTTP, an application-selection key could include:

```text
(local endpoint, normalized Host value, path prefix)
```

The dispatcher should distinguish among:

- an unknown virtual host;
- a known virtual host with no applicable route;
- a known application whose worker pool is unavailable;
- an overloaded application pool;
- invalid routing configuration.

Application determination can therefore be bound naturally to the HTTP `Host`
header. Different virtual hosts may be assigned to different application
worker pools.

## Application Worker

An **Application Worker** is a thread and interpreter running an application
instance.

It receives an information-rich request object or dictionary containing only
validated protocol and application information.

The worker should return a semantic response description rather than directly
accessing the client channel.

For example:

```tcl
dict create \
    connection_id 42 \
    transaction_id 7 \
    status 200 \
    reason OK \
    headers {...} \
    body {...}
```

The response is returned to the connection-owning execution context, where it
is encoded and transmitted.

## Connection Handles and Channel Ownership

The transport channel should not normally be handed to an Application Worker.

Transferring the channel to the Application Worker would introduce several
problems:

- the Protocol Processor could no longer continue reading the connection;
- request pipelining would stop during application execution;
- channel ownership would repeatedly move between threads;
- response ordering would become harder to enforce;
- defective application code could corrupt protocol framing;
- keep-alive lifecycle decisions would become distributed;
- transport errors would cross architectural boundaries.

Instead, the Application Worker should receive a **connection handle**, not a
connection object or channel.

A connection handle could contain:

```text
connection_id
transport_thread_id
transaction_id
reply_command
```

This handle is a routing capability for returning a result to the
connection-owning thread. It does not provide direct channel access.

## Two-Tier Request Processing

The request-processing pipeline consists of two principal stages.

### Tier 1: Protocol Processing

The Protocol Processor:

1. receives bytes from the Transport Agent;
2. recognizes protocol message boundaries;
3. parses and validates the request;
4. checks protocol congruence;
5. emits protocol errors directly when validation fails;
6. determines the target application;
7. constructs the request representation;
8. submits the request to an Application Worker.

### Tier 2: Content Generation

The Application Worker:

1. receives the validated request representation;
2. executes application routing and business logic;
3. generates a semantic response;
4. returns the response with its connection and transaction identifiers.

While content generation is taking place, the Protocol Processor may continue
processing later requests from the same or other connections, subject to
configured concurrency and buffering limits.

## HTTP Pipelining

The proposed model permits HTTP/1.1 pipelining:

```text
request 1 parsed -> application worker A
request 2 parsed -> application worker B
request 3 parsed -> application worker C
```

Application work may execute concurrently. HTTP/1.1 responses must nevertheless
be emitted in request order:

```text
response 1, then response 2, then response 3
```

Every HTTP request therefore needs a monotonically increasing
`transaction_id` or `sequence_number`.

The connection-owning agent must retain completed out-of-order responses until
all earlier responses have been sent.

This requires explicit resource limits:

- maximum in-flight requests per connection;
- maximum buffered input per connection;
- maximum buffered completed responses;
- maximum request-header size;
- maximum request-body size;
- application execution timeout;
- connection idle timeout.

Without these limits, a slow first request can cause later completed responses
to consume unbounded memory. This is the head-of-line blocking inherent in
HTTP/1.1 pipelining.

## Request Representation

A validated HTTP request representation could contain:

```text
connection_id
transaction_id
method
target
path
query
version
headers
virtual_host
local_endpoint
remote_address
body_mode
body_descriptor
transport_thread_id
reply_command
```

The representation should be treated as immutable application input.

It should contain application-relevant information, but it should not expose
the client channel itself.

## Request Bodies

The Protocol Processor cannot always hand an Application Worker a completely
independent dictionary containing the full body. Large or streaming request
bodies require a body-access abstraction.

The supported body modes may include:

- `in_memory`;
- `spooled_file`;
- `streaming`.

### In-Memory Body

The complete body is included in, or referenced by, the request
representation.

This mode is suitable for:

- small requests;
- tests;
- simple form submissions.

### Spooled-File Body

The complete body is stored in a temporary file, and the request representation
contains a controlled file descriptor or pathname abstraction.

This mode bounds Tcl object memory use while retaining a complete-body model.

### Streaming Body

The body remains associated with the connection-owning agent and is consumed
incrementally.

This mode creates a continuing relationship between the Application Worker and
the Connection/Transport Agent. That relationship requires message-based
operations such as:

```text
body_read
body_copy
body_cancel
body_eof
```

The Transport Agent must retain ownership of the underlying client channel.

The design must also define:

- how buffered body prefixes are delivered;
- how read demand is signalled;
- maximum outstanding body data;
- cancellation behavior;
- client-disconnect behavior;
- application timeout behavior;
- whether pipelining is suspended while a streaming body is incomplete.

## Response Processing

The cleanest response boundary is:

```text
Application response
    -> Protocol response encoder
    -> byte segments
    -> Transport Agent
```

The Application Worker produces a semantic response.

The Protocol Processor or a dedicated protocol encoder:

- validates the response;
- creates the protocol status line;
- validates and normalizes headers;
- selects framing;
- applies content-length or chunked encoding;
- produces ordered byte segments.

The Transport Agent writes those byte segments to the channel.

Protocol-generated errors bypass application dispatch:

```text
invalid request
    -> protocol error response
    -> Protocol response encoder
    -> Transport Agent
```

This arrangement prevents application code from directly constructing malformed
wire-protocol responses.

## Thread Topology

A complete topology could be:

```text
Main thread
    listeners
    configuration
    registries
    lifecycle supervision

Transport threads
    connection ownership
    event-driven I/O
    input and output buffering
    flow control

Protocol threads
    parsing
    validation
    framing
    virtual-host selection
    transaction ordering

Application pools
    application routing
    content generation
    business logic
```

## Colocation Versus Separate Protocol Threads

Placing the Transport Agent and Protocol Processor in separate threads is
possible, but it introduces messaging for every input fragment and every output
segment.

Potential costs include:

- repeated byte copying;
- additional thread scheduling;
- more complex flow control;
- more complex connection shutdown;
- additional ordering and cancellation races;
- increased latency for small requests.

A practical initial design is to separate Transport and Protocol as classes and
contracts while colocating their instances in the same thread:

```text
Transport thread
    Connection Agent
        owns the channel and buffers

    Protocol Processor
        owns protocol state and parsing
```

Application execution would still occur in separate application worker pools.

This preserves the architectural boundary and makes both components
independently testable without immediately paying the inter-thread messaging
cost for every network read.

The Protocol Processor can later move to a dedicated protocol thread if
measurement demonstrates that the additional execution separation is useful.

## Object and Thread Terminology

Avoid the expression **Protocol class thread**.

Use these terms instead:

- **protocol-processor class**: the TclOO class defining protocol behavior;
- **protocol-processor instance**: one interpreter-local TclOO object;
- **protocol thread**: the thread and interpreter hosting protocol processors;
- **connection agent**: the object owning one accepted connection;
- **transport thread**: a thread hosting one or more connection agents;
- **application worker**: a thread and interpreter running application code;
- **request handoff**: submission of validated request information to an
  Application Worker;
- **response completion message**: the result returned by an Application
  Worker;
- **connection handle**: identifiers and commands allowing an Application
  Worker to route a result back to the connection owner.

Objects have interpreter and thread affinity. Threads do not become classes,
and TclOO objects are not shared merely because the same class is loaded in
multiple interpreters.

## Required State Ownership

The specification should assign ownership explicitly.

### Transport Agent State

- client channel;
- TLS state;
- read buffer;
- write queue;
- connection timeout;
- EOF and transport-error state;
- current channel-owner identity.

### Protocol Processor State

- parser state;
- protocol session state;
- request sequence counter;
- in-flight transaction table;
- response-ordering queue;
- protocol limits;
- virtual-host selection state.

### Application Dispatcher State

- virtual-host registry;
- route-to-application mapping;
- application-pool registry;
- overload policy;
- unavailable-application policy.

### Application Worker State

- application instance;
- application-local caches;
- request execution state;
- content-generation resources.

## Error Ownership

Error handling should follow the component boundary:

- the Listener handles accept failures;
- the Transport Agent handles TCP, TLS, channel, EOF, and write failures;
- the Protocol Processor handles malformed protocol messages and framing
  errors;
- the Application Dispatcher handles unknown or unavailable applications;
- the Application Worker handles application failures;
- the connection-owning execution context decides whether the connection can
  continue or must close.

Protocol validation errors should normally produce protocol-compliant error
responses without entering an Application Worker.

Application failures should be converted into semantic error responses and
returned through the normal response-completion path.

## Control Plane and Internal Services

The same agent-oriented architecture can be extended to internal services,
particularly thread-pool management and logging.

This creates a distinction between the server's control plane and execution
plane:

```text
Control plane
|-- Runtime Supervisor
|-- Thread-Pool Broker Agent
|-- Pool and Thread Registries
|-- Configuration Registry
`-- Logging Agent

Execution plane
|-- Transport Agents
|-- Protocol Processors
`-- Application Workers
```

The control plane creates, supervises, classifies, and observes execution
resources. The execution plane performs connection handling, protocol
processing, and application work.

## Runtime Supervisor

The **Runtime Supervisor** is the main-thread lifecycle authority.

It should:

- create and supervise the Thread-Pool Broker Agent;
- create and supervise the Logging Agent;
- publish internal-service endpoints;
- detect internal-service failure;
- restart internal services where policy permits;
- coordinate orderly server shutdown.

The Thread-Pool Broker Agent and Logging Agent should not supervise themselves.

A suitable ownership hierarchy is:

```text
Runtime Supervisor
|-- Thread-Pool Broker Agent
|   |-- transport pools
|   |-- protocol pools
|   `-- application pools
`-- Logging Agent
```

## Thread-Pool Broker Agent

The global thread-pool management service is the **Thread-Pool Broker Agent**,
abbreviated **TPBA**.

Its thread identifier may be published in shared state:

```tcl
tsv::set tclwire tpba_thread_id $thread_id
```

The stored value is a broker endpoint identifier, not an object handle. A
caller still communicates with the broker through `thread::send`.

The TPBA should be the sole authority for:

- creating and destroying worker pools;
- growing and shrinking pools;
- creating and retiring worker threads;
- assigning and releasing workers;
- enforcing pool limits;
- supervising worker health;
- applying worker restart policy;
- maintaining pool lifecycle state;
- reporting pool availability.

The TPBA should not execute transport, protocol, application, or logging work.

### Pool Identity

Pool identity should be structured rather than encoded only in opaque strings
such as `connection-http-production`.

A **pool descriptor** is the structured semantic identity of a pool:

```tcl
dict create \
    kind protocol \
    protocol http \
    application {} \
    instance default
```

Example descriptors include:

```tcl
dict create kind transport endpoint http-main
dict create kind protocol protocol http
dict create kind application application shop virtual_host shop.example
dict create kind application application admin virtual_host admin.example
dict create kind internal service logging
```

A canonicalized descriptor may be converted into a stable **pool key** for
registry lookup. The registry should retain the descriptor fields rather than
retaining only the serialized key.

Use these terms:

- **pool descriptor**: structured semantic identity;
- **pool key**: canonical registry key;
- **pool instance**: one managed collection of workers;
- **worker role**: transport, protocol, application, logging, or internal.

### Broker API

The TPBA should expose a message-oriented API with operations equivalent to:

```text
create_pool descriptor policy
destroy_pool pool_key
acquire_worker pool_key reply_target correlation_id
release_worker pool_key worker_id
resize_pool pool_key limits
pool_status pool_key
list_pools
shutdown_pool pool_key
shutdown_all
```

Requests should be asynchronous. Each request requiring a response should
contain:

- a correlation identifier;
- a reply target;
- the requested operation;
- the applicable pool key or descriptor;
- operation-specific arguments.

Callers should not block the broker while waiting for worker execution.

## Thread and Pool Registries

The current term `accounting` is too narrow once the database contains worker
identity, classification, lifecycle, activity, and pool information.

The architecture should distinguish three logical stores.

### Thread Registry

The **Thread Registry** contains relatively stable worker identity and
classification:

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

The `protocol`, `application`, and `virtual_host` fields apply only when
relevant to the worker role.

### Worker State Store

The **Worker State Store** contains rapidly changing operational state:

```text
status
current_connection_id
current_transaction_id
current_command
started_at
last_activity_at
completed_jobs
failed_jobs
```

### Pool Registry

The **Pool Registry** contains pool-level configuration and state:

```text
pool_key
descriptor
minimum_workers
maximum_workers
current_workers
idle_workers
queued_jobs
lifecycle_state
worker_script
restart_policy
```

These stores may physically use the same `tsv` namespace, but they should have
separate logical schemas, ownership rules, and update operations.

### Registry Authority

Shared state should primarily provide discovery and observation. It should not
be the mechanism through which arbitrary threads perform worker lifecycle
transitions.

The governing rule is:

> The TPBA owns pool and worker lifecycle transitions; shared registries
> publish the resulting state.

Worker allocation, release, termination, and reclassification should therefore
be requested through TPBA messages rather than performed through direct
modification of shared records.

This avoids races in which several threads attempt to allocate or change the
same worker concurrently.

## Worker Lifecycle

A worker should follow an explicitly defined state machine:

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

The states have these meanings:

- `creating`: the worker thread is being allocated;
- `starting`: its interpreter and runtime are being initialized;
- `idle`: it can accept work;
- `reserved`: it has been allocated but has not started the assigned job;
- `running`: it is executing assigned work;
- `draining`: it accepts no new work but may finish existing work;
- `terminating`: shutdown has been requested;
- `terminated`: its lifecycle has completed;
- `failed`: it exited or became unusable unexpectedly.

The `reserved` state closes the interval between allocation and job start. The
`draining` state supports pool reduction and orderly shutdown without
interrupting active work.

## Central Logging Agent

A dedicated **Logging Agent** thread provides the central logging facility.

Log producers should send structured events asynchronously:

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

- log files and output channels;
- event formatting;
- serialization of writes;
- log rotation;
- flushing;
- severity and component filtering;
- output destinations;
- shutdown draining.

Transport, protocol, and application workers should not share or directly
write the Logging Agent's channels.

### Logging Backpressure

The Logging Agent's input queue must be bounded. Logging must not become a
global synchronization bottleneck or indefinitely block request processing.

The overload policy should define how to:

- drop low-severity events;
- aggregate repeated messages;
- count and report dropped events;
- preserve warnings and errors where possible;
- limit producer-side waiting;
- flush queued critical events during orderly shutdown.

The Logging Agent should publish queue depth, dropped-event counts, and output
failure state for operational observation.

## Internal-Service Discovery

Internal-service thread identifiers may be published in shared state:

```tcl
tsv::set tclwire tpba_thread_id $tpba_thread_id
tsv::set tclwire logging_thread_id $logging_thread_id
```

These values are **internal-service endpoint identifiers**.

Consumers must account for:

- an identifier not yet being published;
- the referenced thread having terminated;
- an agent being restarted with a new identifier;
- requests sent during restart being lost;
- orderly shutdown making the service unavailable.

Where stronger delivery guarantees are required, messages should include
correlation identifiers, acknowledgements, deadlines, and retry policy.

## Internal-Service Failure and Restart

The architecture must define:

- who creates each internal service;
- who monitors its liveness;
- whether and how it is restarted;
- how its new endpoint identifier is published;
- whether pending requests survive restart;
- how callers detect unavailability;
- which state is reconstructed after restart;
- shutdown ordering.

The TPBA is a lifecycle authority and the Logging Agent is an output authority,
so both are important infrastructure services. Neither should be treated as
infallible.

The shared registries should contain enough generation and ownership
information to distinguish current worker records from stale records left by a
previous TPBA instance.

## Internal-Service Terminology

Use the following terms in specifications:

- **Runtime Supervisor**: main-thread lifecycle authority;
- **Thread-Pool Broker Agent**: authority for pool and worker management;
- **Pool Registry**: published pool metadata and state;
- **Thread Registry**: published worker identity and classification;
- **Worker State Store**: published current worker activity;
- **Logging Agent**: asynchronous centralized log consumer;
- **Infrastructure Service**: TPBA, logging, metrics, configuration, or another
  internal control-plane service;
- **Execution Service**: transport, protocol, or application processing;
- **internal-service endpoint identifier**: a thread identifier used to route
  commands to an infrastructure agent.

## Assessment

The proposed architecture is viable and improves:

- virtual-host application selection;
- isolation of protocol validation;
- application-specific worker pools;
- concurrent content generation;
- clarity of channel ownership;
- independent testing of protocol processing;
- isolation of application failures from transport handling;
- centralized worker-pool policy;
- structured worker and pool classification;
- serialized, asynchronous logging.

The principal recommendation is to keep channel ownership permanently with the
Connection/Transport Agent and give Application Workers only connection
handles, request data, and asynchronous reply commands.

Transport and Protocol should first be separated by responsibility and
interface. They may initially remain colocated in the same thread. Separate
execution contexts should be introduced only when their scheduling,
parallelism, or isolation benefits justify the added messaging and state
coordination.

The TPBA should remain the sole authority for worker and pool lifecycle
transitions. Shared `tsv` state should publish registries for discovery and
observation rather than serving as an unrestricted lifecycle-control API.
