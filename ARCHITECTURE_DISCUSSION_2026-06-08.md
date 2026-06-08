# Architecture Discussion

Date: 2026-06-08

## Identified Inconsistency

The previous architecture assigned several responsibilities to a combined
Transport/Protocol Agent:

- owning client channels;
- reading and writing bytes;
- parsing requests;
- retaining connection and transaction state;
- dispatching requests to Content Generator Agents;
- accepting asynchronously completed responses;
- preserving response order;
- continuing to process other requests and connections.

This is technically feasible, but the term **Transport/Protocol Agent** hides
two different concepts:

1. a logical agent representing one connection and its protocol state;
2. an execution context that multiplexes many such agents through one event
   loop.

If represented as one large object or one global thread, the component becomes
overloaded and may become a scalability bottleneck.

## Necessary Persistent State

Content generation may continue after request parsing has completed. The
connection-facing side must therefore retain state until the response has been
returned and transmitted.

For an HTTP connection, this state includes:

```text
connection_id
channel
transport state
protocol parser state
next request sequence number
next response sequence number
in-flight transactions
completed responses awaiting transmission
input buffer
output queue
flow-control state
timeout state
connection-close policy
```

This state cannot be placed exclusively in a Content Generator Agent because
that agent does not own the socket and may process only one transaction from a
longer-lived connection.

## Refined Separation

The connection-facing side should be separated into three concepts:

```text
Transport Reactor
    hosts many Connection Agents

Connection Agent
    owns one accepted connection
    owns connection-local transport state

Protocol Session
    owns protocol parsing and transaction state
    is associated with one Connection Agent
```

The Protocol Session may initially be colocated with its Connection Agent.
This is an execution-placement decision, not a collapse of their interfaces.

## Transport Reactor

A **Transport Reactor** is an event-driven thread and Tcl interpreter that owns
multiple socket channels.

It:

- runs one event loop;
- registers readable and writable channel events;
- receives accepted channels assigned to its shard;
- invokes the appropriate Connection Agent;
- receives response-completion messages;
- performs queued channel writes;
- enforces transport-level backpressure and timeouts.

A Transport Reactor is not one connection and not one request. It is an
execution context hosting many logical connection agents.

Several Transport Reactors should exist:

```text
Listener or acceptor
    |
    +-- Transport Reactor 1
    |     +-- Connection Agent 1
    |     +-- Connection Agent 2
    |     `-- Connection Agent 3
    |
    +-- Transport Reactor 2
    |     +-- Connection Agent 4
    |     `-- Connection Agent 5
    |
    `-- Transport Reactor N
```

This is commonly described as a **sharded event-loop** or
**multi-reactor** architecture.

It uses multithreading across reactor shards while retaining efficient
event-driven multiplexing inside each shard.

## Connection Agent

A **Connection Agent** is a logical, connection-affine object.

It:

- represents exactly one accepted connection;
- refers to the channel owned by its Transport Reactor;
- owns connection-local buffers and timeout state;
- owns or links to one Protocol Session;
- tracks outstanding transactions;
- maps application results back to the connection;
- coordinates connection closure.

The Connection Agent is not required to have a dedicated operating-system
thread. Many Connection Agents can run in one Transport Reactor.

This distinction avoids both undesirable extremes:

- one thread for every connection;
- one monolithic object representing every connection.

## Protocol Session

A **Protocol Session** is a protocol-specific state machine associated with a
connection.

For HTTP it:

- incrementally parses request lines and headers;
- validates framing;
- detects complete requests;
- assigns transaction sequence numbers;
- determines the virtual host and application;
- constructs validated request representations;
- creates protocol-error responses;
- validates or encodes application responses;
- determines keep-alive and connection-close behavior;
- preserves HTTP response ordering.

For FTP it:

- parses commands;
- retains authentication and current-directory state;
- coordinates control and data connections;
- applies FTP command sequencing rules.

Protocol Session implementations may derive from protocol-specific classes,
but the session itself remains connection-affine.

## Content Generator Agent

A **Content Generator Agent** is an Application Worker executing application
logic for a validated transaction.

It receives:

```text
connection_id
transaction_id
application_id
validated request data
body descriptor
reply endpoint
```

It returns a semantic response through the reply endpoint. It does not own or
write the client channel.

The reply endpoint identifies the Transport Reactor or Connection Agent that
must receive the completed response.

## The Response Bridge

The bridge between Content Generator Agents and socket channels is an explicit
message path:

```text
Content Generator Agent
    |
    | response-completion message
    v
Owning Transport Reactor
    |
    v
Connection Agent
    |
    v
Protocol Session
    |
    | ordered encoded response
    v
Transport write queue
    |
    v
Client channel
```

A response-completion message should contain at least:

```text
connection_id
connection_generation
transaction_id
status
headers
body descriptor
completion status
```

`connection_generation` prevents a late response from being applied to a
different connection if identifiers are reused.

When a completion message arrives:

1. the Transport Reactor locates the Connection Agent;
2. the Connection Agent rejects the result if the connection is closed or its
   generation does not match;
3. the Protocol Session validates the transaction identifier;
4. the response is placed in the transaction-ordering queue;
5. responses that have become sendable are encoded;
6. encoded data is appended to the Transport Reactor's write queue.

This bridge is required whenever content generation executes outside the
connection-owning thread.

## Does Event-Driven Multiplexing Underuse Multithreading?

Event-driven multiplexing does not by itself prevent multithreading.

The architecture exploits concurrency at two levels:

```text
Across Transport Reactors
    multiple operating-system threads process socket events in parallel

Within each Transport Reactor
    one event loop multiplexes many mostly waiting connections

Across Application Pools
    Content Generator Agents execute application work in parallel
```

Network connections spend much of their lifetime waiting for input, output
capacity, or application results. Assigning a dedicated thread to every waiting
connection would consume more resources without producing corresponding CPU
parallelism.

The appropriate unit of transport parallelism is therefore normally a reactor
shard, not an individual connection.

## Avoiding an Overloaded Transport Reactor

The Transport Reactor should remain a thin scheduler and channel owner.

It should not contain application routing tables, content-generation logic, or
large protocol implementations directly. Those responsibilities belong to
collaborating objects:

```text
Transport Reactor
    event loop and channel operations

Connection Agent
    connection identity and lifecycle

Protocol Session
    protocol state and transaction framing

Application Dispatcher
    application and pool selection

Content Generator Agent
    application execution
```

Colocation of Connection Agent and Protocol Session objects in a Transport
Reactor thread does not mean their responsibilities are merged.

## Protocol Processing in a Separate Thread

Protocol parsing can be moved to a separate Protocol Processor pool, but doing
so requires communication for input data and parser results:

```text
Transport Reactor
    -> byte fragment
Protocol Processor
    -> bytes consumed, request completed, parser state
Transport Reactor
```

This introduces:

- byte copying between interpreters;
- scheduling for every fragment or parsing batch;
- parser-state ownership questions;
- more complex backpressure;
- more complex cancellation and connection shutdown;
- ordering races between new input and parser results.

For HTTP/1 request-line and header parsing, the additional communication may
cost more than the parsing itself.

A separate Protocol Processor pool is most justified when protocol processing
is measurably CPU-intensive, for example:

- expensive decompression;
- cryptographic message validation outside TLS;
- complex protocol transformation;
- large structured-message decoding;
- protocol inspection or filtering.

The architecture should preserve the option without requiring it for ordinary
HTTP framing.

## Recommended Initial Placement

The recommended initial topology is:

```text
Runtime Supervisor
|
|-- Listener/Acceptor
|
|-- TPBA
|
|-- Transport Reactor Pool
|     |-- Reactor 1
|     |     |-- Connection Agents
|     |     `-- colocated Protocol Sessions
|     |
|     `-- Reactor N
|           |-- Connection Agents
|           `-- colocated Protocol Sessions
|
|-- Application Dispatcher
|
|-- Application-Specific Content Generator Pools
|
`-- Logging Agent
```

This topology:

- uses multiple transport threads;
- multiplexes many channels per transport thread;
- keeps channel ownership stable;
- keeps protocol state connection-affine;
- frees protocol execution promptly after request dispatch;
- runs content generation in parallel;
- supports application selection from the HTTP `Host` header;
- avoids inter-thread messaging for every network fragment.

## Reactor Pool Sizing

The Transport Reactor pool should be independently sized from application
pools.

Relevant sizing criteria include:

- number of active connections;
- channel-event rate;
- bytes processed per second;
- TLS processing cost;
- protocol parsing cost;
- output-queue pressure;
- event-loop latency;
- CPU utilization per reactor;
- operating-system file-descriptor limits.

Application pool sizing instead depends on:

- request execution latency;
- CPU consumption;
- blocking I/O;
- database concurrency;
- external-service limits;
- application isolation policy.

The TPBA may supervise both types of pools, but their resource policies should
not be identical.

## Reactor Affinity

Once assigned, a connection should normally retain affinity with one Transport
Reactor for its complete lifetime.

Stable affinity avoids:

- repeated channel transfers;
- moving parser and transaction state;
- reordering pending response messages;
- migrating timeout callbacks;
- synchronizing write queues.

Connection migration should be exceptional and explicitly designed rather than
part of ordinary request processing.

## Slow or Blocked Responses

After dispatching content generation, a Connection Agent remains lightweight
but not stateless.

If an early transaction is slow while later transactions complete, the
Connection Agent retains the later responses until protocol ordering permits
their transmission.

Resource policy must therefore bound:

- transactions in flight per connection;
- completed but blocked responses;
- total queued response bytes;
- time spent waiting for an application result;
- application cancellation after connection closure.

When a limit is reached, the Protocol Session should stop accepting additional
requests from that connection by disabling readable events or otherwise
applying backpressure.

## Application Output Compatibility

For the initial implementation, a Content Generator Agent may produce one
complete buffered application result. This keeps the response-completion
contract simple:

```text
Content Generator Agent
    -> one semantic buffered result
    -> Connection Agent
    -> Protocol Session response encoding
    -> socket channel
```

This initial model can later evolve to support applications written for
existing Tcl application frameworks that emit output through `stdout`.

Each Content Generator Agent may provide an **Application Output Adapter** that
implements compatibility versions of Tcl's `puts` and `flush` commands.

The adapter does not transfer ownership of the client socket to the
application. It converts application output into messages addressed to the
Connection Agent that owns the applicable connection.

## Application Output Adapter

The Application Output Adapter is an interpreter-local compatibility layer
between legacy application output and TclWire's response path.

Conceptually, the Content Generator interpreter performs:

```tcl
rename ::puts  ::tclwire::native_puts
rename ::flush ::tclwire::native_flush

proc ::puts args {
    ::tclwire::application_puts {*}$args
}

proc ::flush args {
    ::tclwire::application_flush {*}$args
}
```

The actual implementation must preserve Tcl command semantics and must avoid
recursion when the server itself needs the original commands.

The adapter should:

- intercept writes directed to `stdout`;
- apply an explicit policy to writes directed to `stderr`;
- preserve writes to ordinary file and pipe channels;
- preserve `puts -nonewline` behavior;
- preserve newline behavior;
- preserve `flush channelId` behavior;
- associate every captured operation with one transaction;
- send or buffer structured output events;
- use the renamed native commands for non-captured channels.

## Tcl Command Compatibility

The replacement `puts` command must support Tcl's normal forms:

```text
puts string
puts -nonewline string
puts channelId string
puts -nonewline channelId string
```

The replacement `flush` command must support:

```text
flush channelId
```

Only `stdout` and, according to policy, `stderr` should be virtualized.
Operations on any other channel should be delegated to the renamed native
commands.

This is important because an application may use `puts` for:

- writing files;
- writing subprocess pipes;
- diagnostic output;
- producing HTTP content.

A global replacement that redirects every `puts` call to the client connection
would break ordinary Tcl I/O.

## Transaction Output Context

The compatibility commands need an active **Transaction Output Context**.

Before invoking application code, the Content Generator Agent establishes
interpreter-local context equivalent to:

```text
connection_id
connection_generation
transaction_id
reply_endpoint
output_mode
stdout_buffer
stderr_buffer
output_sequence
response_state
cancelled
```

After application execution, the agent clears the context before accepting
another request.

If `puts stdout` is called without an active transaction, the adapter should
either:

- delegate to the native `stdout`; or
- report a controlled server error.

The selected policy should be explicit. Silently attaching output to the most
recent request would be unsafe.

## Execution Concurrency Within a Content Generator

Renaming `puts` and `flush` affects the entire Tcl interpreter. A single
interpreter-global output context is safe only if one Content Generator Agent
executes at most one application transaction at a time.

This yields the rule:

> One Content Generator interpreter may execute only one stdout-compatible
> application transaction at a time unless output context can be resolved
> independently for every coroutine or execution stack.

Concurrent application invocations in the same interpreter could otherwise
mix output from unrelated transactions.

Parallelism should initially be achieved by using multiple Content Generator
threads and interpreters, not by overlapping stdout-compatible requests inside
one interpreter.

If coroutine-level concurrency is introduced later, the output adapter will
need coroutine-local context lookup rather than one global current transaction.

## Buffered Compatibility Mode

The first compatibility implementation should use **buffered capture mode**.

In this mode:

1. `puts stdout` appends bytes or text to the transaction's output buffer;
2. `flush stdout` records a compatibility flush but performs no network write;
3. application execution continues until it returns;
4. the Content Generator Agent constructs one application result;
5. the result is sent to the owning Connection Agent.

This retains the current single-result assumption while allowing existing
applications to use familiar output commands.

The application result should distinguish:

```text
status
headers
stdout body
stderr diagnostics
application completion status
```

A flush in buffered mode cannot provide true client-visible immediacy. This
limitation should be documented as a property of buffered compatibility mode.

## Future Streaming Compatibility Mode

A later implementation may use **streaming output mode**.

In streaming mode, each captured operation becomes a structured event:

```text
output_begin
output_data
output_flush
output_end
output_error
```

An output event should contain:

```text
connection_id
connection_generation
transaction_id
output_sequence
stream
data
flags
reply_endpoint
```

The `stream` field distinguishes `stdout` from `stderr`. The
`output_sequence` field preserves the order of writes generated by one
application transaction.

The event path becomes:

```text
Application
    -> Application Output Adapter
    -> output event
    -> owning Transport Reactor
    -> Connection Agent
    -> Protocol Session
    -> ordered response output
    -> socket channel
```

The Connection Agent remains the bridge to the socket. The Content Generator
Agent never writes the socket channel directly.

## Protocol Framing Boundary

Captured `stdout` data is not automatically a complete HTTP response.

The architecture must define which compatibility convention an application
uses:

1. `stdout` contains response-body data only;
2. `stdout` begins with CGI-style response headers followed by a blank line;
3. the framework calls a TclWire response API for status and headers and uses
   `stdout` only for the body;
4. `stdout` contains a complete protocol response.

The preferred contract is:

```text
status and headers
    supplied through a structured response API

stdout
    interpreted as response-body content
```

CGI-style header parsing can be provided as a compatibility profile for
frameworks that require it.

Treating arbitrary `stdout` as a complete HTTP response would weaken protocol
validation and allow application code to bypass response framing, header
normalization, and connection policy.

## HTTP Response State and Header Commitment

An HTTP Content Generator interpreter should expose convenience commands for
constructing the semantic response before output is committed.

Possible operations include:

```text
set_status code reason
set_header name value
add_header name value
remove_header name
headers
headers_sent
```

The distinction between `set_header` and `add_header` is important:

- `set_header` replaces the current values for a field;
- `add_header` appends another field value, as required for fields such as
  `Set-Cookie`.

These commands modify the transaction's response description. They do not
write directly to the client channel.

### Response State Machine

The Content Generator should maintain transaction-local response state:

```text
building
    -> committed
    -> streaming
    -> completed

any non-completed state
    -> failed
    -> cancelled
```

The states have these meanings:

- `building`: status and headers may still be modified;
- `committed`: status and headers are frozen and have been accepted for
  transmission;
- `streaming`: response-body output is being forwarded;
- `completed`: no further response changes or output are accepted;
- `failed`: response generation failed;
- `cancelled`: the connection or transaction is no longer usable.

Header mutation commands are valid only in `building`.

An attempt to modify headers in any later state must fail with a Tcl error.
It must not be silently ignored because that would conceal application bugs
and produce behavior that depends on timing.

### Commit Point

In buffered capture mode, commitment normally occurs when the Content
Generator completes and submits its single application result. Headers remain
modifiable while the application is building that result.

In streaming output mode, commitment occurs before the first body bytes become
eligible for transmission. It may be triggered by:

- an explicit `commit_headers` or `write_headers` operation;
- the first non-empty `stdout` body write;
- a `flush stdout` operation;
- application completion, if no earlier operation committed the response.

After commitment, the Content Generator Agent changes its local response state
so subsequent header operations fail immediately.

### Authoritative Connection State

The Content Generator's `headers_sent` state is a local view of the
transaction's response state. The Protocol Session remains authoritative for
whether the response headers have been accepted and transmitted.

The Content Generator cannot safely inspect or modify Connection Agent state
directly because the objects run in different interpreters and threads.

For buffered output, the response-completion message provides an atomic
handoff of status, headers, and body.

For streaming output, header commitment should use a protocol message such as:

```text
response_begin
    connection_id
    connection_generation
    transaction_id
    status
    reason
    headers
```

The Protocol Session validates the message and returns an acknowledgement or
rejection. It must reject:

- a second `response_begin`;
- headers for an unknown or cancelled transaction;
- headers for a stale connection generation;
- invalid HTTP status or header fields;
- a header mutation received after commitment.

The Content Generator should enter `committed` only after the protocol side has
accepted `response_begin`, unless the implementation deliberately uses an
optimistic asynchronous state and defines failure recovery.

An acknowledged commit is easier to reason about and prevents body events from
overtaking header validation.

### Header Convenience API

The convenience API should be installed only in HTTP Content Generator
interpreters or HTTP-specific application child interpreters.

It may be exposed through commands such as:

```tcl
::tclwire::response status 200 OK
::tclwire::response set_header Content-Type "text/html; charset=utf-8"
::tclwire::response add_header Set-Cookie "session=abc; Path=/"
::tclwire::response headers_sent
```

The API should:

- normalize or validate header names;
- reject newline characters in names and values;
- preserve repeated fields where HTTP permits them;
- prevent applications from setting connection-controlled fields when policy
  reserves them;
- fail after the response is committed;
- bind every operation to the active Transaction Output Context.

Connection-controlled fields may include:

- `Connection`;
- `Content-Length`;
- `Transfer-Encoding`;
- protocol upgrade fields;
- other fields selected by server policy.

The Protocol Session may derive or override these fields according to the
chosen framing, keep-alive, and streaming mode.

### Failure Semantics

If a header operation fails while the response is still uncommitted, the
application framework may catch the Tcl error and construct another response.

If an uncaught error occurs before commitment, the Content Generator Agent may
return a structured application failure that the Protocol Session converts
into an HTTP error response.

If an error occurs after commitment, the status and headers cannot be replaced.
The available actions are limited to:

- terminate the response body if framing permits;
- close the connection;
- cancel later pipelined transactions when required;
- report the failure to the Logging Agent.

This is why the transition from `building` to `committed` must be explicit and
observable to application frameworks.

## Standard Output and Standard Error

`stdout` and `stderr` should not normally have identical meanings.

Recommended policy:

- `stdout` is application response output;
- `stderr` is application diagnostic output sent to the Logging Agent;
- `stderr` is associated with the same application, thread, connection, and
  transaction identifiers;
- `stderr` is not sent to the client unless an explicit debugging profile
  requests it.

Sending `stderr` directly to the client could:

- corrupt HTTP framing;
- leak internal information;
- append diagnostics after a valid content body;
- make application failures protocol-dependent.

An optional compatibility mode may capture `stderr` separately in the
application result, but the Connection Agent should not forward it to the
socket as ordinary response data.

## Character Encoding and Binary Data

Tcl `stdout` normally has channel encoding, translation, and buffering
properties. A command-level adapter does not automatically inherit those
channel transformations.

The compatibility layer must define whether captured values represent:

- Tcl strings to be encoded later;
- already encoded byte sequences;
- text output using a configured application encoding;
- binary output emitted through a separate API.

The recommended distinction is:

```text
puts-compatible output
    text encoded according to the application output profile

binary response API
    explicit byte-array output without text transformations
```

Applications serving arbitrary binary content should not depend on implicit
`stdout` text conversion.

## Flush Semantics

In buffered mode, `flush stdout` is only a compatibility operation.

In streaming mode, `flush stdout` requests that all preceding output events for
the transaction become eligible for transmission. It does not guarantee that
the remote client has received the bytes.

The meaning should be:

> `flush stdout` establishes an output boundary and requests progress through
> the response pipeline.

It must not mean:

> synchronously block until the client socket confirms delivery.

A synchronous cross-thread flush would risk deadlocks and would couple
application execution to a slow client.

## Backpressure

Streaming output requires bounded queues between the Content Generator Agent
and Connection Agent.

Without backpressure, a fast application can produce unbounded output while:

- the client reads slowly;
- an earlier pipelined response blocks transmission;
- the Transport Reactor is overloaded;
- the connection has already failed.

The streaming protocol should define:

- maximum unacknowledged output bytes;
- maximum queued events;
- high- and low-water marks;
- pause and resume messages;
- transaction cancellation;
- behavior after connection closure;
- application timeout while blocked by output pressure.

A Content Generator Agent may need to yield or suspend when its output credit
is exhausted. It should not block the TPBA, Logging Agent, or Transport Reactor.

## Output Ordering

There are two distinct ordering domains:

1. **application output ordering**, concerning content generated within one
   application transaction;
2. **protocol response ordering**, concerning the order in which complete
   transactions may be transmitted on one connection.

Application output ordering belongs to the application layer. An application
or its framework determines:

- the order in which body fragments are generated;
- whether output from internal application tasks may be interleaved;
- when an application-level flush boundary is requested;
- whether independently generated content must be serialized;
- when the application result is complete.

The Application Output Adapter should preserve the order in which one
application execution submits output events. It should not invent an ordering
policy for concurrently executing application activities.

The application layer is therefore responsible for assigning or producing a
coherent sequence of output for one transaction. If an application permits
concurrent producers for one response, the application framework must
serialize them before or while invoking the output adapter.

Protocol response ordering remains a Protocol Session and Connection Agent
responsibility. For example, HTTP/1.1 requires responses on a pipelined
connection to be transmitted in request order. Separate Content Generator
Agents cannot enforce this because they do not own the connection and may
complete in a different order.

A later transaction may therefore generate and complete its application output
before an earlier transaction, but its response cannot necessarily be written
to the socket.

The Connection Agent and Protocol Session must therefore retain transaction
output separately:

```text
transaction 1 output queue
transaction 2 output queue
transaction 3 output queue
```

Only the transaction currently eligible for transmission may feed the socket
write queue.

The resulting responsibility boundary is:

```text
Application layer
    orders content within one transaction

Application Output Adapter
    preserves the submitted per-transaction order

Protocol Session
    orders transactions according to protocol rules

Transport Reactor
    preserves the byte order of the authorized write queue
```

## Cancellation and Late Output

When a connection closes or a transaction is cancelled, the Connection Agent
must notify the applicable Content Generator Agent.

After cancellation:

- new output events should be rejected or discarded;
- buffered output should be released;
- late completion messages should be ignored safely;
- application execution may be allowed to finish or may be interrupted
  according to policy;
- diagnostic information should still be sent to the Logging Agent.

Every output event must include the connection generation and transaction
identifier so stale output cannot be attached to a later connection.

## Safer Interpreter Isolation

Renaming global commands in a Content Generator interpreter is workable when
that interpreter is dedicated to application execution.

For stronger isolation, an application may run in a child interpreter where:

- compatibility `puts` and `flush` commands are installed before the framework
  is loaded;
- native commands are hidden or aliased deliberately;
- application-visible commands are controlled;
- the parent Content Generator Agent owns output context and messaging.

This prevents application command replacement from affecting the agent's own
infrastructure code.

The choice between a dedicated worker interpreter and a child application
interpreter is an implementation decision. The architectural contract remains
the Application Output Adapter.

## Revised Application Output Position

The stdout compatibility design is architecturally viable as a migration
mechanism for existing Tcl application frameworks, subject to these rules:

1. the client channel remains owned by the Transport Reactor;
2. `puts` and `flush` are replaced only within application execution
   interpreters;
3. only `stdout` is treated as response content by default;
4. `stderr` is routed to structured logging;
5. each output operation is bound to a connection generation and transaction;
6. one interpreter initially executes one compatible application transaction
   at a time;
7. buffered capture is implemented before streaming;
8. protocol framing remains under Protocol Session control;
9. streaming later adds sequencing, cancellation, and backpressure;
10. ordinary non-standard channels continue to use native Tcl I/O;
11. the application layer defines content ordering within one transaction;
12. the Protocol Session enforces transaction ordering required by the
    connection protocol;
13. HTTP header convenience commands operate only before response commitment;
14. the Protocol Session remains authoritative for accepted and transmitted
    header state.

This compatibility layer preserves existing application programming styles
without weakening channel ownership or making Content Generator Agents direct
socket writers.

## Revised Terminology

Use:

- **Transport Reactor** for an event-loop thread owning multiple channels;
- **Connection Agent** for the logical object representing one connection;
- **Protocol Session** for connection-affine protocol state;
- **Application Dispatcher** for application and pool selection;
- **Content Generator Agent** for application execution;
- **response-completion message** for an application result;
- **reply endpoint** for the route back to the owning reactor;
- **reactor affinity** for the stable connection-to-reactor assignment;
- **Transport Reactor Pool** for the sharded set of transport event loops;
- **Application Output Adapter** for the stdout/stderr compatibility layer;
- **Transaction Output Context** for request-specific output routing state;
- **buffered capture mode** for one-result application output;
- **streaming output mode** for sequenced incremental output events;
- **response commitment** for the point after which HTTP status and headers
  cannot be changed.

Avoid using **Transport/Protocol Agent** when it is unclear whether the term
means a thread, a connection object, a protocol state machine, or all three.

## Revised Architectural Position

The concern about overloading the Transport/Protocol Agent is valid if that
agent is treated as one monolithic global component.

The refined architecture instead uses:

1. a pool of Transport Reactor threads;
2. many lightweight Connection Agents in each reactor;
3. one connection-affine Protocol Session per connection;
4. asynchronous dispatch to Content Generator Agents;
5. an explicit response-completion bridge back to the owning reactor;
6. an Application Output Adapter for stdout-compatible frameworks.

This design combines event-driven efficiency with multithreaded parallelism.
Transport and protocol work are parallelized across reactor shards, while
content generation is parallelized independently across application-specific
pools.

The Protocol Session remains ready to process additional requests because it
does not perform content generation. The Connection Agent retains only the
state necessary to preserve connection lifecycle, flow control, transaction
identity, and response ordering.

Initially, each Content Generator Agent returns one buffered application
result. Later, the same response bridge may carry sequenced output events
generated by compatibility `puts` and `flush` commands, without transferring
the client channel away from its Transport Reactor.
