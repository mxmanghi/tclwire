# Agent Communication Data Structures

This document describes the Tcl data structures currently exchanged among the
HTTP Protocol Session, Connection Agent, Application Dispatcher, Content
Generator Agent (CGA), and application output bridge.

The cross-thread structures are Tcl dictionaries and lists. They are values
transferred between threads, not shared mutable objects. Thread-local TclOO
wrappers provide controlled access to those values. The Connection Agent owns
the authoritative mutable transaction state.

## Communication Flow

```text
HTTP request bytes
    |
    v
HttpProtocolSession
    |  parsed request descriptor
    v
HttpConnectionAgent
    |  enriched request descriptor
    v
ApplicationDispatcher
    |  worker request descriptor
    v
Content Generator Agent
    |  read-only HttpRequest
    v
Application
    |  ordered application output events
    v
HttpConnectionAgent
    |
    v
HTTP response bytes
```

## Request Transport Descriptor

The request transport descriptor is the dictionary copied from the Connection
Agent thread to a Content Generator Agent. It is assembled in stages and is
wrapped in an `HttpRequest` object before application dispatch.

### Protocol Fields

`HttpProtocolSession parse_request` creates these fields:

| Field | Value | Description |
| --- | --- | --- |
| `method` | string | HTTP method from the request line. |
| `target` | string | Unmodified request target. |
| `path` | string | Portion of `target` before the first `?`. |
| `query` | string | Raw URL-encoded query without the leading `?`. |
| `query_dict` | dictionary | Decoded query parameters. Duplicate names retain the last value. |
| `version` | string | HTTP version, such as `1.1`. |
| `headers` | dictionary | Request headers keyed by lowercase field name. |
| `body_framing` | string | `none`, `content-length`, or `chunked`. |
| `transfer_codings` | list | Applied transfer codings in request order. |
| `body_mode` | string | Currently always `in_memory`. |
| `body` | byte string | Decoded request body. |
| `body_size` | integer | Length of `body` in bytes. |
| `trailers` | dictionary | Decoded chunk trailers keyed by lowercase field name. |

`query_dict` uses `application/x-www-form-urlencoded` conventions: `+`
represents a space, percent escapes represent bytes, and the resulting byte
sequence is decoded as UTF-8.

### Connection Fields

`HttpConnectionAgent build_request_descriptor` adds:

| Field | Value | Description |
| --- | --- | --- |
| `connection_id` | integer | Runtime identifier of the client connection. |
| `remote_host` | string | Peer address. |
| `remote_port` | integer | Peer port. |

Before dispatch, `HttpConnectionAgent handle_request` adds:

| Field | Value | Description |
| --- | --- | --- |
| `transaction_id` | integer | Connection-local request identifier. |
| `connection_thread_id` | thread ID | Thread that owns the Connection Agent. |
| `connection_agent_id` | TclOO object command | Connection Agent receiving output events. |

The thread and object identifiers are routing metadata for the output bridge.
Applications should treat them as opaque values.

### Application Dispatch Fields

`ApplicationDispatcher dispatch` adds these fields to the copy sent to the
CGA:

| Field | Value | Description |
| --- | --- | --- |
| `application_id` | string | Selected application registration name. |
| `application_pool_key` | string | TPBA worker-pool key. |
| `application_descriptor` | dictionary | Effective application configuration. |

The application descriptor contains fields such as `class`, `package` or
`file`, `hosts`, `docroot`, `encoding`, and optionally `libdir` and
`pool_policy`.

The transported snapshot also contains the Connection Agent's current response
state because the transaction deliberately retains one dictionary. The
`HttpRequest` interface does not expose those internal fields.

### Application Contract

The CGA constructs a thread-local `::tclwire::HttpRequest` around the
transported dictionary. `CApplication handle_request` receives this object,
not the dictionary.

The object exposes read-only semantic methods:

| Method | Description |
| --- | --- |
| `method`, `target`, `path`, `version` | Request-line values. |
| `query` | Raw URL-encoded query. |
| `query_dict`, `query_parameters` | Complete decoded query dictionary. |
| `query_parameter name ?default?` | One decoded query parameter. |
| `headers` | Complete normalized request-header dictionary. |
| `header name ?default?` | Case-insensitive request-header access. |
| `body_mode`, `body`, `body_size` | Request-body access. |
| `trailers` | Request trailer dictionary. |
| `connection_id`, `transaction_id` | Request identity. |
| `remote_host`, `remote_port` | Peer endpoint. |
| `application_id` | Selected application registration. |

There are no mutation methods and the underlying dictionary is not exposed.
Modifying values returned by an accessor cannot mutate the Connection Agent's
state because Tcl thread messages and values use copy semantics.

The request body must be interpreted according to `body_mode`. Only
`in_memory` is implemented; future modes may replace the direct `body` field
with another access mechanism.

## Transaction Descriptor

The Connection Agent stores one active `::tclwire::TransactionDescriptor`
object. The object owns the complete descriptor dictionary. Fields present when
the object is constructed are immutable; later connection-side state fields
may be changed through `set`, `append`, and `incr`.

The object provides:

| Method | Description |
| --- | --- |
| `id` | Return the transaction identifier. |
| `get`, `exists` | Read descriptor fields. |
| `set`, `append`, `incr` | Mutate connection-side fields, rejecting immutable request fields. |
| `snapshot` | Return a dictionary value for transport, diagnostics, or final logging. |

The descriptor begins with the request fields and is extended with response
state:

| Field | Initial value | Description |
| --- | --- | --- |
| `response_status` | `200` | HTTP response status code. |
| `response_reason` | `OK` | HTTP reason phrase. |
| `response_headers` | empty list | Ordered HTTP response header lines. |
| `response_body_mode` | `text` | `text` or `binary`. |
| `response_encoding` | application encoding | Encoding used for text output. |
| `response_body` | empty value | Accumulated non-chunked response body. |
| `response_state` | `preparing` | `preparing`, `committed`, or `complete`. |
| `response_bytes` | `0` | Number of streamed representation bytes. |
| `output_sequence` | `0` | Last accepted output-event sequence number. |
| `application_id` | selected ID | Application handling the request. |
| `application_pool_key` | selected key | Pool used for the CGA. |

`ConnectionAgent begin_transaction`, `transaction_for`, and
`finish_transaction` control the object's lifetime. Finishing or closing the
connection destroys the wrapper. The current implementation permits one active
transaction per connection.

## Application Output Event

The application output bridge sends one dictionary per event:

```tcl
dict create \
    type            $event_type \
    transaction_id  $transaction_id \
    output_sequence $sequence_number \
    stream          stdout \
    data            $event_data \
    flags           $event_flags
```

| Field | Value | Description |
| --- | --- | --- |
| `type` | string | Event variant described below. |
| `transaction_id` | integer | Transaction to which the event belongs. |
| `output_sequence` | integer | Monotonically increasing sequence starting at 1. |
| `stream` | string | Currently always `stdout`. |
| `data` | string or byte string | Event payload; empty when unused. |
| `flags` | dictionary | Variant-specific metadata. |

The event is sent asynchronously to the connection thread as:

```tcl
::tclwire::route_application_output \
    $connection_agent_id $transaction_id $event
```

The separate routing argument and the event's `transaction_id` must identify
the same transaction.

## Output Event Variants

### `response`

Declares response metadata. `data` is empty. `flags` contains:

| Flag | Value | Description |
| --- | --- | --- |
| `status` | integer | HTTP status code. |
| `reason` | string | HTTP reason phrase. |
| `headers` | list | Initial response header lines. |
| `body_mode` | string | `text` or `binary`. |
| `encoding` | string | Text encoding, or empty to retain the application encoding. |

It is emitted by `::tclwire::io response`. It must arrive while the response
is `preparing` and before body output has accumulated.

### `http_header`

Modifies response headers before commitment. `data` is empty. `flags`
contains:

| Flag | Value | Description |
| --- | --- | --- |
| `action` | string | `set`, `add`, or `remove`. |
| `name` | string | HTTP response header name. |
| `value` | string | Header value; omitted for `remove`. |

It is emitted by `::tclwire::http::io header`.

### `output`

Transfers buffered application output. `data` contains text or bytes. `flags`
contains `body_mode`, which must match the transaction's response body mode.

For a non-chunked response, the Connection Agent appends `data` to
`response_body`. For a chunked response, it encodes and writes a chunk
immediately.

### `flush`

Requests transmission of pending output. Both `data` and `flags` are empty.
It commits and flushes a chunked response; it does not force an accumulated
non-chunked response to be sent.

### `no_body`

Deletes representation data accumulated for the response. Both `data` and
`flags` are empty. It is emitted by `::tclwire::http::no_body`, which first
discards output still buffered in the Content Generator Agent.

For a non-chunked response, the Connection Agent clears `response_body`. For
a chunked response, the operation is accepted while no non-empty chunk has
been transmitted, including after an empty response head has been committed.
Any uncommitted `Content-Length` is removed so completion can calculate zero.
Once `response_bytes` is greater than zero, deleting the body is impossible
and the response is aborted.

### `complete`

Marks successful application completion. Both `data` and `flags` are empty.
The Connection Agent serializes an accumulated response or terminates a
chunked response, records the result, and closes the connection.

### `error`

Reports application failure. `data` contains the error message and `flags` is
empty. If the response has not been committed, the Connection Agent sends a
`500` response. Otherwise it closes the connection.

## Ordering and Validity Rules

The Connection Agent enforces these rules:

1. Events for inactive or completed transactions are ignored.
2. `output_sequence` values must be contiguous and start at 1.
3. Response metadata and headers cannot change after commitment.
4. All output in one response must use the declared body mode.
5. Invalid event types or invalid state transitions abort the response.
6. A failure before commitment produces an HTTP `500`; a failure after
   commitment closes the connection because a replacement response can no
   longer be sent.

## Implementation References

- Request parsing: [`tcl/http_protocol.tcl`](../tcl/http_protocol.tcl)
- Query decoding: [`tcl/http_query.tcl`](../tcl/http_query.tcl)
- Read-only application request:
  [`tcl/http_request.tcl`](../tcl/http_request.tcl)
- Mutable transaction wrapper:
  [`tcl/transaction_descriptor.tcl`](../tcl/transaction_descriptor.tcl)
- Connection and transaction routing:
  [`tcl/connection_agent.tcl`](../tcl/connection_agent.tcl)
- HTTP transaction state:
  [`tcl/http_connection_agent.tcl`](../tcl/http_connection_agent.tcl)
- Application selection and dispatch:
  [`tcl/application_dispatcher.tcl`](../tcl/application_dispatcher.tcl)
- CGA worker entrypoint:
  [`tcl/content_generator_agent.tcl`](../tcl/content_generator_agent.tcl)
- Application output events:
  [`tcl/application_io.tcl`](../tcl/application_io.tcl)
- HTTP output controls:
  [`tcl/http_application_io.tcl`](../tcl/http_application_io.tcl)
- Redirect response construction:
  [`tcl/http_redirect.tcl`](../tcl/http_redirect.tcl)
