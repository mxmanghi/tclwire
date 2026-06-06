# TclWire Application Server Specifications

## Terminological Rule

Use **class family** only for a TclOO inheritance tree. Use
**component family**, **protocol family**, or
**worker-pool key** for runtime groupings.

In particular, the current `connection_class` value is not a TclOO class.

## Existing TclOO Class Families

### Service Class Family

```text
::tclwire::service
|-- ::tclwire::http_endpoint_service
|   |-- ::tclwire::http_service
|   `-- ::tclwire::proxy_service
`-- ::tclwire::ftp_service
```
#### `::tclwire::service`

`::tclwire::service` is the abstract service base class.

It holds:

- endpoint configuration;
- the listener channel;
- logging configuration;
- a reference to a `ThreadMaster`;
- service configuration;
- the protocol name;
- the worker-pool classification;
- TLS/security settings.

Its abstract operation is `start`.

Implementation: [service_base.tcl](./service_base.tcl)

#### `::tclwire::http_endpoint_service`

`::tclwire::http_endpoint_service` is the abstract HTTP-facing endpoint
class.

It implements:

- listener startup;
- client acceptance;
- nonblocking reads;
- per-channel request accumulation;
- request-completion detection;
- HTTP error-message support;
- client-channel cleanup.

Its `handle_request` operation remains abstract.

Implementation: [http_endpoint.tcl](./http_endpoint.tcl)

#### `::tclwire::http_service`

`::tclwire::http_service` is the concrete HTTP origin protocol engine.

It implements:

- HTTP request framing;
- fixed-length and chunked request completion;
- chunked-body decoding;
- response normalization;
- response serialization;
- chunked response transmission;
- delayed and streaming response output;
- delegation to an application object.

Implementation: [http_server.tcl](./http_server.tcl)

#### `::tclwire::proxy_service`

`::tclwire::proxy_service` is the concrete HTTP proxy protocol engine.

It implements:

- proxy-target parsing;
- proxy authentication;
- upstream request forwarding;
- upstream response forwarding;
- HTTP `CONNECT` tunnels;
- bidirectional asynchronous copying.

Implementation: [proxy_server.tcl](./proxy_server.tcl)

#### `::tclwire::ftp_service`

`::tclwire::ftp_service` is the concrete FTP protocol engine.

It implements:

- FTP control sessions;
- FTP command processing;
- authentication policy;
- passive-mode listeners;
- FTP data connections;
- filesystem operations;
- session and transfer state.

Implementation: [ftp_server.tcl](./ftp_server.tcl)

### Application Class Family

```text
::tclwire::CApplication
|-- ::tclwire::CTestApplication
`-- ::tclwire::CMockUpApplication
```

#### `::tclwire::CApplication`

`::tclwire::CApplication` is the HTTP origin application base class.

It:

- parses and interprets HTTP requests;
- parses request lines and headers;
- extracts request bodies;
- selects routes;
- provides common response helpers;
- implements static-file handling;
- produces response descriptions.

Although the source comments describe it as an abstract model, it is
technically instantiable and provides default static-file and `404` behavior.

Implementation: [http_application.tcl](./http_application.tcl)

#### `::tclwire::CTestApplication`

`::tclwire::CTestApplication` is the concrete TclCurl test application.

It contains the route-specific behavior required by the TclCurl test suite,
including redirects, authentication, cookies, range responses, request
inspection, compression, chunking, and delayed responses.

Implementation: [http_test_application.tcl](./http_test_application.tcl)

#### `::tclwire::CMockUpApplication`

`::tclwire::CMockUpApplication` is an experimental thread/application fixture.
It is not currently part of the active server architecture.

It is defined in:

- [mockup_application.tcl](./mockup_application.tcl)
- [thread_base.tcl](./thread_base.tcl)

### Standalone Classes

#### `::tclwire::ThreadMaster`

`::tclwire::ThreadMaster` is the worker-pool manager and lifecycle authority.

It owns:

- worker thread identifiers;
- the maximum pool size;
- worker allocation policy;
- worker creation;
- command dispatch;
- worker status transitions;
- stale-worker detection;
- worker termination.

It does not inherit from `::tclwire::service`.

Implementation: [thread_master.tcl](./thread_master.tcl)

#### `::tclwire::logger`

`::tclwire::logger` is a logging adapter used by `ThreadMaster` and
experimental thread code.

Implementation: [logger.tcl](./logger.tcl)

## Runtime Roles of Service Objects

A current concrete service class has two separate runtime roles.

### Listener-Side Service Instance

A listener-side service instance is created in the main interpreter for one
configured bind endpoint.

It:

- opens and owns the listening socket;
- accepts client connections;
- obtains a worker from a `ThreadMaster`;
- records the accepted connection;
- transfers the accepted channel to the selected worker;
- asynchronously dispatches the worker command.

Listener-side instances are created by `create_service` in
[tclwire.tcl](./tclwire.tcl).

### Worker-Side Protocol-Engine Instance

A worker-side protocol-engine instance is lazily created inside each worker
interpreter.

It:

- receives transferred client channels;
- configures those channels;
- executes protocol-specific connection handling;
- performs request or command processing;
- sends responses;
- closes the connection or completes the protocol session;
- reports completion to the main interpreter;
- returns the worker to the idle state.

A worker-side instance is retained by its worker interpreter and reused
sequentially for later connections assigned to that worker.

Worker-side instances are created by the procedures in
[service_thread.tcl](./service_thread.tcl).

### Required Terminological Distinction

The listener-side and worker-side objects are different objects in different
interpreters, even though they are instances of the same TclOO class.

Therefore, specifications should avoid the unqualified expression
**service object**.

Use:

- **listener-side service instance** for the main-interpreter object;
- **worker-side protocol-engine instance** for the worker-interpreter object.

## Recommended Glossary

### Server Runtime

The **server runtime** is the main interpreter executing:

- command-line processing;
- configuration construction;
- service startup and shutdown;
- worker-pool construction and shutdown;
- request logging;
- global connection accounting.

### Service Endpoint

A **service endpoint** is one configured combination of:

```text
(protocol, local address, local port, security mode)
```

For example:

```text
(http, 127.0.0.1, 8990, cleartext)
```

A service endpoint is represented at runtime by a listener-side service
instance.

### Listener

A **listener** is the listening channel owned by a service endpoint.

It accepts new transport connections. It is not itself a client connection,
session, or request handler.

### Accepted Connection

An **accepted connection** is one client TCP or TLS connection produced by a
listener.

The accepted channel initially belongs to the main interpreter. Its ownership
is subsequently transferred to a worker interpreter.

### Connection Handler

A **connection handler**, also called a **protocol engine**, is the worker-side
component that owns an accepted connection and executes the applicable
protocol behavior.

For HTTP, it handles HTTP framing and transactions. For FTP, it handles the
stateful FTP control session. For the proxy, it handles forwarding or
tunneling.

### Worker Thread

A **worker thread** is one Tcl thread with:

- its own Tcl interpreter;
- its own TclOO objects;
- its own event loop;
- a worker-side protocol-engine instance;
- ownership of at most the connections assigned to it.

### Worker Pool

A **worker pool** is the set of worker threads managed by one `ThreadMaster`.

The `ThreadMaster` owns pool policy and worker lifecycle. The shared accounting
namespace exposes worker status but does not own pool policy.

### Worker-Pool Key

A **worker-pool key** is the classification used to select which worker pool
handles a protocol.

The current implementation stores this value under the name
`connection_class`. Typical values are:

- `http`;
- `ftp`;
- `proxy`.

The term **worker-pool key** should be preferred in new specifications because
the value does not identify a TclOO class.

### Application

An **application** is HTTP origin business and routing logic represented by
`CApplication` or one of its subclasses.

The term should not be used for:

- `proxy_service`;
- `ftp_service`;
- a listener-side service instance;
- a worker pool;
- the complete server process.

### HTTP Transaction

An **HTTP transaction** is exactly one HTTP request and its corresponding HTTP
response.

A persistent HTTP connection may contain multiple sequential HTTP
transactions. Therefore, an HTTP transaction and an HTTP connection must not
be treated as synonyms.

### FTP Session

An **FTP session** is the complete stateful lifetime of an FTP control
connection.

It may contain:

- multiple FTP commands;
- authentication state;
- current-directory state;
- multiple passive listeners;
- multiple FTP data connections;
- multiple data transfers.

An FTP command is not a session, and an FTP data connection is not the control
session.

### Connection Record

A **connection record** is the dictionary stored by
`record_connection_opened`.

It records:

- the connection identifier;
- protocol;
- channel name;
- peer address;
- service endpoint;
- worker thread identifier;
- timestamps;
- connection status;
- errors.

It is accounting data, not a connection object and not the connection itself.

### Request Representation

The current **request representation** is a fully buffered byte string.

It is not currently:

- a request object;
- a stream;
- a request-body object;
- an immutable request value type.

Future specifications should explicitly distinguish a request representation
from a request context and from a request-body abstraction.

### Response Representation

The current **response representation** is a Tcl dictionary containing fields
such as:

- status;
- reason;
- headers;
- body;
- transfer encoding;
- streaming chunks.

It is not currently a response object or a response writer.

## Protocol and Worker-Pool Classification

The registered protocol names are:

- `http`;
- `https`;
- `ftp`;
- `ftps`;
- `proxy`.

The current `connection_class` field groups these protocols for worker-pool
selection:

```text
http  ---+
         +--- worker-pool key: http
https ---+

ftp   ---+
         +--- worker-pool key: ftp
ftps  ---+

proxy ------ worker-pool key: proxy
```

HTTP and HTTPS therefore share a protocol-handler family and worker pool.
FTP and FTPS likewise share a protocol-handler family and worker pool.

This grouping does not imply TclOO inheritance beyond the actual class
hierarchies documented above.

## Threading Terminology

### Ownership

**Channel ownership** identifies the Tcl interpreter in which a channel may
currently be used.

After `thread::transfer`, only the destination interpreter may use the
transferred channel.

### Affinity

**Interpreter affinity** identifies the interpreter and thread in which an
object exists and may be invoked.

TclOO objects in this architecture are interpreter-local. They are not shared
objects merely because their class definitions exist in several interpreters.

### Handoff

A **channel handoff** is the transfer of channel ownership from one interpreter
to another using `thread::transfer`.

The handoff and the asynchronous dispatch of a command are separate
operations.

### Dispatch

**Dispatch** is asynchronous command submission to another Tcl thread using
`thread::send -async`.

Dispatch does not by itself transfer a channel or any TclOO object.

### Lifetime

Specifications should explicitly distinguish these lifetimes:

- server-runtime lifetime;
- service-endpoint lifetime;
- listener lifetime;
- worker-pool lifetime;
- worker-thread lifetime;
- accepted-connection lifetime;
- protocol-session lifetime;
- HTTP-transaction lifetime;
- application-instance lifetime;
- request-context lifetime;
- request-body lifetime;
- response-writer lifetime.

### Concurrency

**Concurrency** means that multiple operations can be in progress during
overlapping time intervals.

In TclWire, concurrency may arise from:

- multiple worker threads;
- multiple interpreters;
- event-driven channel activity;
- asynchronous callbacks;
- delayed callbacks;
- asynchronous inter-thread command dispatch.

### Parallelism

**Parallelism** means that operations execute simultaneously on different
operating-system threads or CPU cores.

Concurrency does not necessarily imply parallelism.

### Event-Driven Multiplexing

**Event-driven multiplexing** means that one thread progresses multiple
channels or operations through its event loop.

This is distinct from assigning one operating-system thread to each active
operation.

### Shared State

The thread accounting data stored through `tsv` is **shared state**.

The following entities are not shared merely because equivalent instances or
definitions exist in several interpreters:

- `ThreadMaster`;
- listener-side service instances;
- worker-side protocol-engine instances;
- application instances;
- TclOO class objects;
- ordinary Tcl variables.

Any future specification must identify which state is:

- interpreter-local;
- thread-local;
- connection-local;
- transaction-local;
- explicitly shared through thread-shared storage;
- communicated by message passing.

## Specification Guidance

New threaded-server specifications should state, for every component:

1. its formal class or interface;
2. its runtime role;
3. its owning interpreter and thread;
4. its lifetime;
5. the channels and state it owns;
6. whether it is shared, copied, transferred, or recreated;
7. the messages it receives and sends;
8. the conditions under which ownership changes;
9. its error-handling responsibility;
10. its shutdown responsibility.

This vocabulary prevents several common ambiguities:

- confusing a protocol name with a TclOO class;
- confusing a worker-pool key with a class family;
- confusing a listener with an accepted connection;
- confusing a connection with one request/response transaction;
- confusing an FTP session with an FTP command or data connection;
- confusing equivalent objects in different interpreters with a shared object;
- confusing channel transfer with command dispatch;
- confusing concurrency with parallel execution.
