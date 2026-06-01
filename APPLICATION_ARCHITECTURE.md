# HTTP Application Architecture

This note describes the current split between the generic HTTP server
infrastructure and the application logic used by the TclCurl test suite.

## Current Separation

The server stack is currently divided into three layers:

- `http_endpoint_service` in [http_endpoint.tcl](./http_endpoint.tcl)
- `http_service` in [http_server.tcl](./http_server.tcl)
- `CApplication` in [http_application.tcl](./http_application.tcl)
- `CTestApplication` in [http_test_application.tcl](./http_test_application.tcl)

### `http_endpoint_service`

This class owns the client-facing socket infrastructure:

- listening socket creation
- client acceptance
- nonblocking reads
- per-channel request buffering
- request completion detection, using the application request parser where
  header inspection is needed
- low-level client channel cleanup

### `http_service`

This class is transport-oriented. It extends the shared endpoint layer
with HTTP-specific mechanics:

- chunked request-body completion
- chunked body decoding
- response normalization
- response header/body serialization
- chunked response transmission
- delayed and streaming response output
- write error handling

Its per-request entrypoint is now a delegation point:

- `handle_request {chan request}`

This method does not implement routing anymore. It forwards the fully buffered
request to the configured application object through:

- `application service_request $service $chan $request`

Today this remains synchronous. Later the same boundary can become the
channel-handoff point to a worker thread.

### `CApplication`

`CApplication` is the abstract model for server applications.
`CTestApplication` is the current concrete implementation for the TclCurl test
suite.

`CApplication` owns request interpretation and common application helpers.
`CTestApplication` owns the route-specific behavior used by the test suite.

## Application Methods

The methods below currently represent application logic rather than transport
logic.

### `service_request {service chan request}`

This is the current application entrypoint. It receives:

- the service object
- the client channel
- the fully buffered request bytes

It currently performs:

- request-line validation
- request path extraction
- header parsing
- route dispatch
- delayed-response scheduling
- final delegation back to the service for response emission

This method is the intended future worker-thread handoff boundary.

### `route_request {service method path target version headers request}`

This is the main route dispatcher. It decides how the application responds to
the request and returns a response dictionary. In `CTestApplication` it
implements the behavior required by the TclCurl test suite.

Examples of responsibilities:

- redirects
- wait/delay endpoints
- cookie endpoints
- authentication endpoints
- inspection endpoints
- static file lookup
- range responses
- shutdown endpoint handling

### `request_body {service request}`

This method extracts the request body from the buffered HTTP request and, when
needed, asks the service to decode a chunked upload. It exists to give route
handlers a payload-oriented view of the request.

### `redirect_response {location {reason "Found"}}`

This helper builds the response dictionary for simple redirect replies. It is
application logic because redirects are chosen by route behavior, not by the
transport layer.

### `static_file_response {path}`

This helper maps a request path into the configured document root, validates
the path segments, reads the target file, and builds the response dictionary.

It belongs to the application side because file exposure policy and path-to-file
mapping are application concerns.

### `byte_range_response {service headers full_body}`

This helper implements the application behavior for `Range` requests over a
known body. It inspects the request headers, validates ranges, and returns:

- a full `200 OK` response
- a single-range `206 Partial Content` response
- a multipart `206 Partial Content` response
- a `416 Range Not Satisfiable` response

Although it is HTTP-aware, it is still application logic because it decides how
the resource body is exposed.

### `parse_query {target}`

This helper parses the query component of the request target into a Tcl
dictionary.

### `decode_query_component {value}`

This helper decodes URL query components, including `+` and percent-escaped
octets.

### `guess_content_type {path}`

This helper maps a filesystem path extension to a response content type. It is
currently used by `static_file_response`.

### `escape_response_value {value}`

This helper escapes special characters when request metadata is reflected into
diagnostic response bodies such as `/request-inspect`.

### `parse_request_line {request}`

This helper parses the buffered request line into method, target and HTTP
version fields.

### `parse_headers {request}`

This helper parses the buffered request headers into a lower-cased dictionary.

### `header_lines {header_block}`

This helper extracts non-empty header lines from the raw header block.

## Methods Still Kept in the Service Layer

The following methods are still on the service side even though they may later
move closer to the worker/application boundary:

- `header_value`

For the current step they remain there to minimize behavior changes while the
delegation architecture is introduced.

## Near-Term Direction

If the next goal is to make worker threads perform the whole request/response
cycle, the likely next move is:

1. Keep connection acceptance and request buffering in
   `http_endpoint_service`.
2. Keep response I/O on the worker side by turning `service_request` into the
   real threaded execution entrypoint.

That would leave the endpoint service as a lightweight accept/buffer layer and
move the full request-processing flow into application-controlled worker code.
