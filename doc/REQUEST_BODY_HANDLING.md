# Request Body Handling

This note describes how request uploads are handled by the current threaded
HTTP implementation and outlines the likely evolution path for larger
request-body support.

## Current Behavior

The current implementation parses each HTTP request incrementally. Small
bodies remain in memory; bodies larger than `request_memory_threshold` are
spooled to `upload_area`. Application logic still starts only after the whole
request has arrived.

The relevant flow is:

1. `HttpConnectionAgent::readable` reads a bounded chunk from the client.
2. `HttpProtocolSession::feed` incrementally parses request framing and writes
   decoded body bytes to its current body sink.
3. The sink starts in memory and migrates existing and subsequent bytes to a
   temporary file when the configured threshold is crossed.
4. `HttpConnectionAgent` adds connection and transaction metadata.
5. `ApplicationDispatcher` sends the descriptor to a CGA worker.
6. The CGA wraps the descriptor in a read-only `HttpRequest` object and calls
   the application entrypoint, `handle_request {request}`.

Relevant code:

- [`http_connection_agent.tcl`](../tcl/http_connection_agent.tcl)
- [`http_protocol.tcl`](../tcl/http_protocol.tcl)
- [`content_generator_agent.tcl`](../tcl/content_generator_agent.tcl)
- [`http_request.tcl`](../tcl/http_request.tcl)

### Fixed-Length Bodies

For requests with `Content-Length`, the server consumes exactly the declared
number of body bytes without retaining the complete wire request. The declared
final request size is rejected as soon as the headers are parsed when it
exceeds `max_request_bytes`.

At or below `request_memory_threshold`, the descriptor uses `body_mode
in_memory`. Above it, the descriptor uses `body_mode spooled_file` and exposes
`body_path`.

### Chunked Uploads

For requests with `Transfer-Encoding: chunked`, the protocol session consumes
chunk framing incrementally and sends decoded chunk payload bytes to the same
hybrid sink. Trailers remain available in the completed descriptor.

## Consequence

The current model is acceptable for small request bodies and keeps the worker
API simple.

Memory use is bounded by the configured threshold per active request, including
for chunked and gzip transfer decoding. The remaining buffered-model limitation
is that application processing cannot begin until the upload is complete.

## Size Limits

To bound this cost, the connection agent rejects request headers larger than
64 KiB with status 431 and rejects a request larger than
`max_request_bytes` with status 413. The default request limit is 16 MiB.

For `Content-Length` requests, the declared final size is checked immediately
after the headers arrive. Chunked requests are limited by the encoded bytes
actually received. Reads are capped at the remaining allowance so one channel
event cannot cause an unbounded allocation.

Configure the request limit globally with `--max-request-bytes <count>` or
`tclwire.max_request_bytes` in TOML. An HTTP or HTTPS service can override it
with `max_request_bytes` in its protocol table.

Configure the in-memory threshold with `--request-memory-threshold <count>` or
`tclwire.request_memory_threshold`. HTTP and HTTPS protocol tables can override
it with `request_memory_threshold`. The default is 1 MiB. A value of zero
spools every non-empty request body.

## Multipart Request Diagnostics

Complete multipart requests can be written to the server's standard error
stream by setting `dump_multipart_requests = true` in the `[tclwire]` TOML
table or by passing `--dump-multipart-requests`. The feature is disabled by
default and does not dump non-multipart requests.

Request dumps include HTTP headers and all multipart field and file content.
Enable this only for short-lived diagnostics, and protect the resulting logs
as sensitive data.

## Design Alternatives

There is more than one way to evolve beyond full in-memory buffering.

### 1. Full In-Memory Buffering

This is available by configuring a threshold at least as large as the request
limit, but is no longer the default strategy.

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

This is the current request-body strategy.

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
