# Request Body Handling

This note describes how request uploads are handled by the current threaded
HTTP implementation and outlines the likely evolution path for larger
request-body support.

## Current Behavior

The current implementation fully buffers each HTTP request in the
`HttpConnectionAgent` before application logic starts in a Content Generator
Agent (CGA) worker.

The relevant flow is:

1. `HttpConnectionAgent::readable` reads available bytes from the client
   channel into its input buffer.
2. `HttpProtocolSession::complete_request` checks whether a complete request
   has arrived.
3. `HttpProtocolSession::parse_request` parses the completed request and
   returns a request descriptor with `body_mode in_memory`.
4. `HttpConnectionAgent` adds connection and transaction metadata.
5. `ApplicationDispatcher` sends the descriptor to a CGA worker.
6. The CGA wraps the descriptor in a read-only `HttpRequest` object and calls
   the application entrypoint, `handle_request {request}`.

Relevant code:

- [http_connection_agent.tcl](../tcl/http_connection_agent.tcl)
- [http_protocol.tcl](../tcl/http_protocol.tcl)
- [content_generator_agent.tcl](../tcl/content_generator_agent.tcl)
- [http_request.tcl](../tcl/http_request.tcl)

### Fixed-Length Bodies

For requests with `Content-Length`, the server keeps buffering until it has at
least:

- end of headers
- plus the exact body length declared by `Content-Length`

This means a large `POST` or `PUT` request produces a similarly large in-memory
buffer.

### Chunked Uploads

For requests with `Transfer-Encoding: chunked`, the connection agent still
buffers the full request body in memory until the terminating chunk is present.

The protocol session parses chunk framing while locating the end of the
request. During `parse_request`, it removes chunk framing, decodes the
supported transfer-coding chain, and stores the decoded body in the request
descriptor. It does not expose upload bytes incrementally to application code.

## Consequence

The current model is acceptable for small request bodies and keeps the worker
API simple.

For a general-purpose web server, this approach is not scalable:

- memory usage grows with upload size
- memory usage grows independently for each active uploading connection
- the application cannot start processing the body until the upload is fully
  received
- the connection thread remains responsible for buffering all request bytes

In practice, the memory cost can be larger than the raw request size because of
intermediate Tcl object allocations and copying.

## Design Alternatives

There is more than one way to evolve beyond full in-memory buffering.

### 1. Full In-Memory Buffering

This is the current strategy.

Advantages:

- simple implementation
- simple application API
- easy to test

Disadvantages:

- poor scalability for large uploads
- poor scalability under concurrency

### 2. Spooling to Temporary Files

The server can keep headers and small bodies in memory, but once a body crosses
a configured threshold it can spill the payload to a temporary file.

Advantages:

- keeps the current “complete request before application handling” model
- greatly reduces memory pressure for large uploads
- application can still see a complete body descriptor

Disadvantages:

- adds filesystem I/O
- requires temporary-file lifecycle management
- still delays application processing until the full upload is complete

This is a reasonable intermediate design if preserving a buffered request model
is important.

### 3. Incremental Streaming

The server can parse the request line and headers first, then expose the body
to application code incrementally as chunks arrive.

Advantages:

- bounded memory usage
- application can process large uploads progressively
- avoids mandatory temporary files
- better fit for forwarding, hashing, filtering, or transforming uploads

Disadvantages:

- more complex application API
- more state management
- error handling becomes more subtle

This is the more scalable long-term direction.

### 4. Streaming with Optional Spooling

The best general-purpose design is often a hybrid:

- the server exposes a streaming body API
- application code may consume the stream directly
- if needed, the application or framework can spool the body to a file

This avoids forcing every upload into one representation.

## Relation to the Current Worker API

The current architecture does not transfer client channels to application
workers. The connection thread owns the channel and HTTP protocol state.
Application workers receive copied request descriptors and send ordered output
events back to the owning connection thread.

Within that model, full buffering is simple but has two important costs:

- large bodies are held by the connection thread before dispatch;
- in-memory bodies are copied into the worker request descriptor.

Any future streaming or spooling design must preserve the rule that
application workers do not perform socket I/O unless the worker API is changed
deliberately.

## Suggested Future Body Modes

To make the future application API explicit, it is useful to think in terms of
body modes.

### `in_memory`

The body is fully materialized in memory and exposed as a Tcl string or byte
sequence.

Best for:

- small form posts
- tests
- simple endpoints

### `spooled_file`

The body is fully received, but the payload lives in a temporary file rather
than a Tcl string.

Best for:

- large uploads that must be fully available before processing
- compatibility with buffered application logic

### `streaming`

The body is consumed incrementally from the channel by the worker or by an
application-facing stream abstraction.

Best for:

- very large uploads
- proxying or relaying
- checksumming during upload
- online transformation or validation

## Likely Refactoring Path

A practical step-by-step evolution could be:

1. Keep the current API for the test suite.
2. Introduce an internal body abstraction instead of always passing a raw
   complete request string.
3. Add a size threshold for spooling large bodies to temporary files.
4. Add a descriptor representation for spooled bodies.
5. Introduce a streaming body mode with explicit ownership, cancellation, and
   backpressure semantics.
6. Keep `in_memory` as a compatibility mode for tests and simple handlers.

## Summary

The current server buffers the whole upload in memory before request handling.
That is acceptable for small bodies, but not sufficient for a general-purpose
server handling large or many concurrent uploads.

Temporary files are one valid solution, but they are not the only one and not
necessarily the final one. The current worker API leaves room for future
`spooled_file` and `streaming` modes, but those modes need explicit descriptor,
lifecycle, and backpressure semantics.
