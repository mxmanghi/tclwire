# Worker Request API Sketch

This note sketches a possible worker-facing API for the future HTTP server
architecture.

The goal is to support the planned separation:

- infrastructure code accepts connections and recognizes requests
- worker threads own the request/response transaction
- application code runs inside the worker context

This is not yet an implementation contract. It is a design guide for the next
refactoring steps.

## Goals

The worker-facing API should:

- avoid mandatory full in-memory buffering of request bodies
- allow the worker to own the client channel
- allow the worker to return the client channel to infrastructure when request
  recognition remains there
- support simple buffered request handling for tests
- support large uploads efficiently
- keep response generation and error handling in the worker
- make application boundaries explicit

## High-Level Model

The likely execution model is:

1. infrastructure accepts the client socket
2. infrastructure reads enough bytes to recognize the request line and headers
3. infrastructure chooses the application
4. infrastructure transfers the channel to a worker thread
5. worker constructs a request object
6. application handles the request through that object
7. worker sends the response
8. worker either closes the channel or returns it to infrastructure if the
   connection remains open and request recognition stays there

In that model, the worker should receive:

- the client channel
- parsed request-line metadata
- parsed headers
- body handling mode
- any already-buffered body bytes

If infrastructure code remains responsible for recognizing request boundaries,
then channel ownership transfer is not one-way. After a request is completed,
the worker must be able to:

- close the channel
- or return the channel to the infrastructure thread for the next request

## Proposed Main Objects

The design can be described with three main concepts:

- request context
- request body
- response writer

These may become TclOO classes, dictionaries plus helper commands, or a hybrid.

## Request Context

The request context represents request metadata and the execution environment
for one HTTP transaction.

Possible responsibilities:

- request method
- request target
- HTTP version
- parsed headers
- client address information
- application selection
- access to the request body abstraction
- access to the response writer

### Suggested Fields

A worker-side request context should probably expose values equivalent to:

- `method`
- `target`
- `path`
- `query`
- `version`
- `headers`
- `remote_host`
- `remote_port`
- `body_mode`
- `body`
- `response`

### Suggested Methods

If implemented as a TclOO object, the request context could expose methods such
as:

- `method`
- `target`
- `path`
- `query_dict`
- `version`
- `headers`
- `header name`
- `body`
- `response`
- `channel`
- `remote_host`
- `remote_port`

These methods should be read-oriented. The request context should not invite
application code to mutate protocol metadata casually.

## Request Body

The request body abstraction is the most important change relative to the
current implementation.

The application should not be forced to assume that the body is always a single
string.

### Body Modes

The request body object should expose one of these modes:

- `in_memory`
- `spooled_file`
- `streaming`

### `in_memory`

The body is fully available in RAM.

Suggested operations:

- `mode`
- `size`
- `as_bytes`
- `as_string ?encoding?`

This mode preserves compatibility with the current test-server style.

### `spooled_file`

The body is fully available, but stored in a temporary file.

Suggested operations:

- `mode`
- `size`
- `file_path`
- `open`
- `copy_to channel`

This mode is useful when the application still wants a complete body but memory
usage must stay bounded.

### `streaming`

The body is not materialized in full. The worker or application consumes it
incrementally.

Suggested operations:

- `mode`
- `read chunkSize`
- `read_all`
- `copy_to channel`
- `foreach_chunk varName script`
- `eof`

This mode is the best fit for large uploads and proxy-style forwarding.

## Buffered-Bytes Handoff

When the infrastructure thread stops after parsing headers, it may already have
read some bytes that belong to the request body.

The worker-side body abstraction should therefore support:

- an initial buffered prefix
- the live channel as the remaining source

This means a streaming body implementation should conceptually read from:

1. already-buffered bytes first
2. then the channel

That avoids losing bytes during thread handoff.

## Response Writer

The response writer owns all response-side I/O.

This aligns with the design goal that worker code performs:

- header transmission
- body transmission
- chunked transfer generation
- delayed/streaming output
- channel write error handling
- final channel close or keep-alive handling

### Suggested Methods

Possible response-writer methods:

- `set_status code reason`
- `set_header name value`
- `add_header name value`
- `write_headers`
- `write data`
- `write_chunk data`
- `flush`
- `close`
- `send_buffered_response body`
- `send_file path`

Depending on design preference, some of these can remain internal helper
methods rather than direct application API.

## Suggested Application Entry Point

A future application entrypoint could be as simple as:

```tcl
method service_request {request_context} {
    ...
}
```

instead of the current:

```tcl
method service_request {service chan request} {
    ...
}
```

That would remove most transport knowledge from application code.

## Minimal Compatibility Layer

To migrate incrementally, the first worker-side request context can still be
backed by the current fully buffered request string.

For example:

- `body_mode` can initially be `in_memory`
- `body as_bytes` can return the current decoded body
- existing route logic can continue to work with small changes

This makes it possible to introduce the API before introducing true streaming.

## Parsing Ownership

For the future architecture, request parsing should likely move fully to the
worker/application side once the worker owns the channel.

The parsing split could become:

- infrastructure:
  only enough parsing to detect header completion and application selection
- worker:
  request-line parsing
  header normalization
  body interpretation
  response generation

This is cleaner than leaving request interpretation spread across acceptor and
worker code.

## Error Handling

The worker-side API should make error behavior explicit.

Important cases include:

- malformed request line
- malformed headers
- mismatched `Content-Length`
- invalid chunk framing
- client disconnect during upload
- write failure during response

A practical rule is:

- infrastructure handles socket acceptance failures
- worker handles request/response protocol failures

## Keep-Alive and Multiple Requests

The current server closes the connection after each response. A general-purpose
server may later support multiple requests per connection.

If that happens, the request context should represent exactly one transaction,
but channel ownership depends on where request recognition lives.

### Infrastructure-Owned Request Recognition

In this model:

1. infrastructure recognizes the request line and headers
2. infrastructure hands the channel to the worker
3. worker consumes the request body and sends the response
4. worker returns the channel to infrastructure if keep-alive continues

This means returning the client channel is part of the normal request
lifecycle.

### Worker-Owned Persistent Connection

In this model:

1. infrastructure only accepts the connection and performs the first handoff
2. worker keeps channel ownership
3. worker parses subsequent requests itself
4. worker decides when the connection ends

This avoids ownership round-trips, but it moves more protocol responsibility to
the worker.

This is another reason not to model the API as “one complete request string per
connection”.

## Example Conceptual Flow

An eventual worker flow might look like this:

```tcl
set req [::tclcurl::testserver::HttpRequestContext new \
    -channel $chan \
    -method $method \
    -target $target \
    -version $version \
    -headers $headers \
    -body $bodyObject]

$application service_request $req
```

Inside the application:

```tcl
method service_request {req} {
    set response [$req response]

    switch -- [$req path] {
        /upload {
            set body [$req body]
            if {[$body mode] eq "streaming"} {
                $body copy_to $someDestination
            } else {
                set bytes [$body as_bytes]
            }
            $response set_status 200 OK
            $response write "upload=ok\n"
            return
        }
    }
}
```

This example is only illustrative, but it shows the intended separation:

- the request object describes the request
- the body object describes body access
- the response object performs output

## Likely Refactoring Order

A practical sequence could be:

1. Introduce an internal request-context abstraction while still using full
   buffering.
2. Replace `service_request {service chan request}` with
   `service_request {request_context}`.
3. Move request parsing helpers into the request-context or application layer.
4. Introduce `in_memory` body objects.
5. Add `spooled_file` bodies behind a size threshold.
6. Add `streaming` bodies for worker-thread execution.
7. Move response-writing logic behind a response-writer object.
8. Decide explicitly whether keep-alive request recognition remains in
   infrastructure or moves fully into the worker.

## Summary

The future worker-facing API should make request metadata, body access, and
response output explicit and separate. The most important design point is that
the request body must become an abstraction rather than always being a fully
buffered Tcl string.
