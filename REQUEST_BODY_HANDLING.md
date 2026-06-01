# Request Body Handling

This note describes how request uploads are handled by the current test server
implementation and outlines the likely evolution path for a general-purpose
web server architecture.

## Current Behavior

The current implementation fully buffers each HTTP request before application
logic starts.

The relevant flow is:

1. `http_endpoint_service::read_request` reads from the client channel and
   appends the bytes into `request_data($chan)`.
2. `complete_request` checks whether the full request has arrived.
3. Only when the request is complete does the server call the application
   entrypoint.

Relevant code:

- [http_endpoint.tcl](/home/manghi/Projects/tclcurl-ng/testservers/http_endpoint.tcl:56)
- [http_server.tcl](/home/manghi/Projects/tclcurl-ng/testservers/http_server.tcl:65)
- [http_application.tcl](/home/manghi/Projects/tclcurl-ng/testservers/http_application.tcl:136)

### Fixed-Length Bodies

For requests with `Content-Length`, the server keeps buffering until it has at
least:

- end of headers
- plus the exact body length declared by `Content-Length`

This means a large `POST` or `PUT` request produces a similarly large in-memory
buffer.

### Chunked Uploads

For requests with `Transfer-Encoding: chunked`, the server still buffers the
full request body in memory until the terminating chunk is present.

The current code parses the buffered chunk stream only to determine whether the
upload is complete. It does not process the upload incrementally.

## Consequence

The current model is acceptable for the TclCurl test suite because the payloads
are small and the implementation is simple.

For a general-purpose web server, this approach is not scalable:

- memory usage grows with upload size
- memory usage grows independently for each active uploading connection
- the application cannot start processing the body until the upload is fully
  received
- the acceptor side remains responsible for buffering all request bytes

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

## Relation to the Planned Thread Architecture

The long-term direction discussed for this web server is:

- a lightweight infrastructure thread accepts connections
- specialized worker threads perform request processing and response I/O
- channel ownership is handed over to the worker

Within that model, full buffering in the acceptor thread is not ideal.

The cleaner direction is:

1. accept enough bytes to parse the request line and headers
2. choose the application or worker that will handle the request
3. transfer channel ownership to that worker
4. let the worker read the request body incrementally
5. let the worker also produce the response and handle write errors

This keeps the infrastructure layer small and places the full request/response
transaction in the execution context that owns the application logic.

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
4. Move request-line and header parsing fully into the application/worker side.
5. Introduce a streaming body mode for worker-thread execution.
6. Keep `in_memory` as a compatibility mode for tests and simple handlers.

## Summary

The current server buffers the whole upload in memory before request handling.
That is acceptable for the test suite, but not sufficient for a real
general-purpose server.

Temporary files are one valid solution, but they are not the only one and not
necessarily the final one. The most scalable architecture is to let the worker
thread own the channel and process the request body incrementally, while still
supporting in-memory and spooled-file modes where useful.
