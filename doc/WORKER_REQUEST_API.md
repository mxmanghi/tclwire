# Worker Request API

This document describes the worker-facing HTTP request and response API
implemented by TclWire.

The current architecture does not transfer client channels to application
workers. A connection thread owns the channel and HTTP protocol state for the
entire connection. Content Generator Agent (CGA) workers receive copied request
descriptors, run application code, and send ordered output events back to the
owning connection thread.

## Current Execution Model

One request follows this path:

1. `HttpConnectionAgent` reads request bytes from its client channel.
2. `HttpProtocolSession` waits for the complete request, parses it, and decodes
   its body.
3. `HttpConnectionAgent` creates the transaction and adds connection and
   output-routing metadata.
4. `ApplicationDispatcher` selects an application from the normalized `Host`
   header, falling back to the configured default application when no host is
   present.
5. The dispatcher acquires a worker from the application's TPBA pool and sends
   the request descriptor to it asynchronously.
6. `::tclwire::cga::execute` creates one application instance and one
   read-only `HttpRequest` object.
7. The application handles the request through
   `handle_request {request}`.
8. Application output commands send sequenced events to the connection thread.
9. `HttpConnectionAgent` validates the events, constructs or streams the HTTP
   response, logs the request, and closes the connection.
10. The CGA destroys the request and application objects and releases itself
    back to the TPBA pool.

The worker never receives the client channel and does not perform socket I/O,
HTTP request parsing, response framing, or connection lifecycle management.

## Worker Pool Dispatch

Each configured application has a TPBA pool identified by an application pool
key. The default pool policy is:

```tcl
dict create minimum_workers 0 maximum_workers 20
```

An application descriptor may override this through `pool_policy`.

The dispatcher adds these values to the request descriptor sent to the worker:

- `application_id`
- `application_pool_key`

If no worker is available, dispatch fails and the connection receives a
`503 Service Unavailable` response. An unknown nonempty `Host` receives
`404 Not Found`.

## Application Lifecycle and Entry Point

Effective application settings are represented internally by an immutable
`::tclwire::ApplicationConfiguration` object. Its constructor validates the
required settings and supplies defaults for every standard optional property.
Configuration objects expose named accessors such as `docroot`, `encoding`,
`reload_on_request`, and `retain_uploaded_files`, plus `get` and `snapshot`.
They expose no mutation methods. Modifying a returned snapshot cannot alter
the object.

TclOO objects belong to one interpreter and cannot cross worker-thread
boundaries. `ApplicationConfiguration serialize` therefore produces a
versioned, dictionary-based wire envelope containing its type, schema version,
application ID, and values. The worker calls the class-level `deserialize`
method, which validates the envelope and reconstructs its own configuration
object. This serialization format is an internal dispatcher/CGA agreement, not
an application configuration-file format or public persistence format.
`CApplication configuration_object` exposes the worker-local object.
The existing `configuration` method continues to return a dictionary for
compatibility with application constructors and code written against earlier
versions.

The application package or file is loaded when each worker interpreter is
initialized. For each request, the CGA invokes:

```tcl
set application [$application_class new $application_descriptor]
set request [::tclwire::HttpRequest new $request_descriptor]
$application handle_request $request
```

Before loading the application, the worker bootstrap places these directories
at the front of its interpreter-local `auto_path`, in order and without
duplicates:

1. the application's normalized `docroot`
2. its effective `libdir`, when configured
3. the TclWire installation root

For a package-backed application, `package require` runs only after those paths
have been added. An application may therefore place `pkgIndex.tcl` directly in
its document root or effective library directory. A file-backed application is
loaded with `source` after the same `auto_path` initialization.

### Development Reloading

A file-backed application can opt into per-request class reloading:

```toml
[http.my_application]
class = "::example::Application"
file = "application.tcl"
reload_on_request = true
```

Immediately before constructing an application instance, the worker destroys
the configured TclOO class and sources the application file again. Each worker
does this independently. This allows files using `oo::class create` to be
edited without restarting TclWire. A syntax or initialization error produces
a 500 response and is retried from the updated file on the next request.

This option is intended only for development: it adds file I/O and class
creation to every request and discards class-level state. It is rejected for
package-backed applications because `package require` caches loaded packages.

The application constructor receives its effective configuration dictionary.
The request entry point is:

```tcl
method handle_request {request} {
    # Read request metadata through $request.
    # Produce the response through ::tclwire::io and HTTP helpers.
}
```

The application object is request-scoped, not worker-scoped. It is destroyed
after `handle_request` returns or raises an error.

`::tclwire::CApplication` is the default implementation. It serves static
resources and provides extension points for path mapping, resource metadata,
complete files, and byte ranges. Derived applications normally override
`handle_request`.

## Read-Only Request Object

The CGA wraps the transported dictionary in `::tclwire::HttpRequest`.
Applications do not receive or mutate the Connection Agent's authoritative
transaction state.

The request object exposes:

| Method | Result |
| --- | --- |
| `method` | HTTP method. |
| `target` | Unmodified request target. |
| `path` | Target path before the first `?`. |
| `query` | Raw query text without the leading `?`. |
| `query_dict` | Decoded query parameter dictionary. |
| `query_parameters` | Alias for `query_dict`. |
| `query_parameter name ?default?` | One decoded query value or the supplied default. |
| `version` | HTTP version, such as `1.1`. |
| `headers` | Dictionary keyed by lowercase header names. |
| `header name ?default?` | Case-insensitive header lookup. |
| `content_type ?default?` | Raw `Content-Type` header value. |
| `content_type_info` | Parsed media type and parameters dictionary. |
| `media_type ?default?` | Lowercase media type from `Content-Type`. |
| `content_type_parameter name ?default?` | One lowercase-keyed `Content-Type` parameter. |
| `is_multipart` | True if the request media type is `multipart/*`. |
| `body_mode` | Request body storage mode. |
| `body` | In-memory decoded request body. |
| `body_size` | Request body length. |
| `multipart_parts` | Parsed MIME multipart parts. File bodies may be spooled to the configured upload area. |
| `form_fields` | Dictionary of non-file multipart form fields. |
| `form_values name` | All non-file multipart values for one field name. |
| `form_value name ?default?` | Last non-file multipart value for one field name. |
| `uploaded_files ?name?` | Multipart file parts, optionally filtered by field name. |
| `uploaded_file name` | First multipart file part for one field name, or empty. |
| `trailers` | Decoded chunk trailer dictionary. |
| `connection_id` | Runtime connection identifier. |
| `transaction_id` | Connection-local transaction identifier. |
| `remote_host` | Client address. |
| `remote_port` | Client port. |
| `application_id` | Selected application registration name. |

There are no request mutation methods and no channel accessor.

## Request Parsing and Body Handling

The connection thread fully buffers each request before dispatch. The protocol
session handles:

- request-line validation
- normalized, lowercase header names
- `Content-Length` framing
- chunked transfer decoding
- supported transfer-coding decoding
- chunk trailer parsing
- URL query decoding

The current request body mode is always:

```tcl
in_memory
```

`$request body` returns the decoded body value. It raises an error if a future
descriptor uses another body mode. `body_size` reports the length of the
decoded body.

Multipart request helpers currently parse the in-memory body. Each part is a
dictionary with `headers` and `body`; form-data parts also expose `name`, and
file parts expose `filename`. Parts with their own `Content-Type` include
`content_type`. Parsed parts are cached by the immutable request object.

There is currently no spooled-file or streaming request-body API. Large
uploads are therefore buffered in the connection thread and copied to the CGA
worker.

## Content-Type and Multipart Reference

The request object includes convenience methods for inspecting request media
types and for accessing `multipart/*` request bodies. These methods are
read-only and operate on the already-decoded in-memory request body.

### Summary

The new request-side helpers cover three layers:

- raw `Content-Type` access
- parsed media type and parameter access
- parsed MIME multipart parts, including `multipart/form-data` fields and
  uploaded file parts

This keeps request-body interpretation on the `HttpRequest` object while
leaving response output controls in `::tclwire::io` and
`::tclwire::http::io`.

### Content-Type Methods

```tcl
$request content_type ?default?
```

Returns the raw `Content-Type` request header value. Header lookup is
case-insensitive because request headers are normalized by the protocol
parser.

If the request has no `Content-Type`, the optional default is returned. Without
an explicit default, the result is an empty string.

Example:

```tcl
set value [$request content_type]
# multipart/form-data; boundary=AaB03x
```

```tcl
$request content_type_info
```

Parses the `Content-Type` header and returns a dictionary with:

- `media_type`: lowercase media type
- `parameters`: dictionary of lowercase parameter names to unquoted values

If the request has no `Content-Type`, this method raises an error.

Example:

```tcl
$request content_type_info
# media_type multipart/form-data parameters {boundary AaB03x}
```

```tcl
$request media_type ?default?
```

Returns only the lowercase media type from `Content-Type`. If no
`Content-Type` is present, the optional default is returned.

Example:

```tcl
$request media_type
# multipart/form-data
```

```tcl
$request content_type_parameter name ?default?
```

Returns one parsed `Content-Type` parameter. Parameter names are matched
case-insensitively. Quoted parameter values are returned without surrounding
quotes.

If the request has no `Content-Type`, or if the named parameter is absent, the
optional default is returned.

Example:

```tcl
$request content_type_parameter boundary
# AaB03x
```

```tcl
$request is_multipart
```

Returns true when the parsed media type matches `multipart/*`; otherwise
returns false.

Example:

```tcl
if {[$request is_multipart]} {
    set parts [$request multipart_parts]
}
```

### Multipart Part Access

```tcl
$request multipart_parts
```

Parses a `multipart/*` request body and returns a Tcl list of part
dictionaries. The parsed list is cached by the immutable request object, so
subsequent calls do not reparse the body.

Without an upload area, this method requires:

- an in-memory request body
- a `Content-Type` whose media type is `multipart/*`
- a nonempty `boundary` parameter
- a body containing the declared boundary and closing boundary

If any of those requirements is not met, it raises an error.

Every in-memory part dictionary contains:

| Key | Meaning |
| --- | --- |
| `headers` | Part headers keyed by lowercase header name. |
| `body` | Raw part body. |

For parts with a `Content-Type` header, the part also contains:

| Key | Meaning |
| --- | --- |
| `content_type` | Raw part `Content-Type` value. |

For parts with `Content-Disposition`, the part may also contain:

| Key | Meaning |
| --- | --- |
| `disposition` | Lowercase disposition type, such as `form-data`. |
| `name` | Unquoted `name` parameter. |
| `filename` | Unquoted `filename` parameter. |

Example:

```tcl
foreach part [$request multipart_parts] {
    set headers [dict get $part headers]
    set body [dict get $part body]
}
```

For a typical file upload part:

```tcl
dict create \
    headers [dict create \
        content-disposition {form-data; name="upload"; filename="hello.txt"} \
        content-type text/plain] \
    body {hello file} \
    content_type text/plain \
    disposition form-data \
    name upload \
    filename hello.txt
```

When `upload_area` is configured, the connection agent parses the multipart
body before application dispatch. Each part with a `filename` parameter is
written to a distinct, server-generated file. Such parts omit `body` and add:

| Key | Meaning |
| --- | --- |
| `body_mode` | `spooled_file`. |
| `path` | Absolute path of the stored file. |
| `body_size` | File size in bytes. |

Non-file form fields remain in memory. `uploaded_files` returns every uploaded
file in request order, so repeated names and requests containing multiple file
fields are supported. After request processing and application destruction,
TclWire deletes every spool path that still exists. An application retains an
upload by moving it to an application-owned location before returning.

For temporary development diagnostics, automatic deletion can be disabled for
one application:

```toml
[http.my_application]
retain_uploaded_files = true
```

Retained uploads contain untrusted client data and require an external cleanup
policy. This option should not be enabled in production.

The upload area defaults to `/tmp`. Configure a global area for HTTP and HTTPS with either
`--upload-area <path>` or `tclwire.upload_area` in TOML. A protocol service can
override it with `http.upload_area` / `https.upload_area`, or a custom service
can use `--service 'http:8080;upload_area=/path'`. Intentionally setting the
global or service value to an empty string disables file storage and selects
the existing in-memory behavior.

The multipart storage procedure requires a nonempty upload area and fails if
called with an empty value. The HTTP connection agent does not call it while
file storage is disabled.

This mode removes file bodies and the raw multipart body before the request is
copied to the application worker. The connection agent still receives the
complete HTTP body before parsing it; incremental socket-to-file streaming is
not yet implemented.

### Multipart Form Helpers

The form helpers operate on parsed multipart parts and are intended for
`multipart/form-data` requests.

```tcl
$request form_fields
```

Returns a dictionary of non-file form fields. Parts that have a `filename`
parameter are excluded. If the same field name appears more than once, the last
value is retained in the returned dictionary.

Example:

```tcl
$request form_fields
# title {Quarterly report} published yes
```

```tcl
$request form_values name
```

Returns a list containing every non-file value for the named field, preserving
request order.

Example:

```tcl
$request form_values tag
# tcl web server
```

```tcl
$request form_value name ?default?
```

Returns the last non-file value for the named field. If no value exists, the
optional default is returned.

Example:

```tcl
$request form_value title Untitled
# Quarterly report
```

```tcl
$request uploaded_files ?name?
```

Returns all file parts. When `name` is supplied, only file parts whose
form-data `name` parameter matches are returned.

Example:

```tcl
foreach file [$request uploaded_files attachment] {
    set filename [dict get $file filename]
    if {[dict exists $file body_mode] &&
            [dict get $file body_mode] eq "spooled_file"} {
        set path [dict get $file path]
    } else {
        set bytes [dict get $file body]
    }
}
```

```tcl
$request uploaded_file name
```

Returns the first uploaded file part for the named field. If no matching file
part exists, the result is an empty string.

Example:

```tcl
set file [$request uploaded_file avatar]
if {$file ne {}} {
    set filename [dict get $file filename]
    set body [dict get $file body]
}
```

### Error Behavior

Multipart parsing errors are application-facing request interpretation errors.
They are raised when an application calls a multipart method, not while the
connection thread parses the HTTP request.

Representative errors include:

- `request Content-Type is not multipart`
- `multipart Content-Type is missing boundary`
- `multipart boundary was not found`
- `multipart closing boundary was not found`
- `multipart part headers are incomplete`

Applications that accept optional multipart bodies should check
`$request is_multipart` before calling `multipart_parts` or the form/file
helpers.

## Application Output Context

Before invoking the application, the CGA starts a transaction-scoped
`::tclwire::io` context containing:

- connection thread ID
- connection agent object ID
- transaction ID
- output sequence number
- buffered output
- buffered body mode
- response state: `open` or `completed`

Only one application output transaction may be active in a worker interpreter
at a time. TPBA worker acquisition enforces one dispatched request per worker.

The CGA automatically:

- sends `complete` after `handle_request` returns successfully if the response
  is still open
- sends `error` if application construction or request handling raises an error
  while the response is still open
- clears the output context
- destroys request-scoped objects
- releases the worker

Applications may call `::tclwire::io complete` to finish the response before
`handle_request` returns. `begin`, `end`, and `fail` remain CGA lifecycle
operations and should not be called by applications.

Response completion does not release the worker or change its accounting
status. The worker remains `running` while `handle_request` performs cleanup or
other non-response work. It becomes `idle` only when `handle_request` has
terminated, request-scoped objects have been destroyed, and the CGA releases
the worker to TPBA.

## Response Metadata

An application can declare response metadata with:

```tcl
::tclwire::io response $status $reason $headers ?$body_mode? ?$encoding?
```

Arguments are:

- `status`: HTTP status code
- `reason`: HTTP reason phrase
- `headers`: ordered list of complete header lines
- `body_mode`: `text` by default, or `binary`
- `encoding`: optional text encoding override

If the application emits no `response` event, the Connection Agent retains its
defaults:

- status `200`
- reason `OK`
- empty header list
- body mode `text`
- the selected application's configured encoding

Response metadata must be emitted while the response is still preparing and
before body output has accumulated.

## Response Output

Application output is buffered in the worker with:

```tcl
::tclwire::io out $data ?$body_mode?
```

The body mode defaults to `text`. One pending buffer cannot mix `text` and
`binary` output.

The compatibility command:

```tcl
::tclwire::io puts ?-nonewline? ?stdout? $string
```

appends text to the same buffer. This is a namespaced command; TclWire does not
replace the interpreter's global `puts` command.

The following commands inspect or clear worker-local pending output:

```tcl
::tclwire::io buffer
::tclwire::io discard_buffer
```

## Flush and Completion

`::tclwire::io flush` first sends pending output as an `output` event and then
sends a `flush` event.

For a normal non-chunked response, output events accumulate in the Connection
Agent until the CGA sends `complete`. A flush does not send that accumulated
body to the client.

For a chunked response, output events are framed and written immediately after
commitment. A flush requests progress through the connection thread's output
path.

An application may complete the response explicitly:

```tcl
::tclwire::io complete
```

This flushes pending output, sends exactly one `complete` event, and changes
the CGA output context from `open` to `completed`. Repeated completion is
idempotent. Response metadata, body output, flushes, header mutations, cookies,
and `no_body` operations become inert after completion, allowing
`handle_request` to continue with cleanup that cannot accidentally modify the
finished response.

If the application returns while the response is still open, the CGA completes
it automatically. If it was completed explicitly, the CGA does not send a
second event.

## HTTP Header and Cookie Controls

HTTP response headers may be changed before commitment:

```tcl
::tclwire::http::io header set $name $value
::tclwire::http::io header add $name $value
::tclwire::http::io header remove $name
::tclwire::http::io header get $name
```

Header names and values are validated, and line breaks in values are rejected.
`get` returns all current values for the named header.

Cookies may be appended as `Set-Cookie` headers:

```tcl
::tclwire::http::io cookie $name $value \
    ?-path $uri_path? ?-expires $expiration?
```

Cookie names, values, paths, and expiration values are validated.

## Removing a Response Body

An application can discard pending response data with:

```tcl
::tclwire::http::no_body
```

This clears the worker-local output buffer and asks the Connection Agent to
clear accumulated response data and remove an uncommitted `Content-Length`.

For a chunked response, this remains valid only while no nonempty chunk has
been transmitted. Once response bytes have been sent, the response cannot be
replaced and the connection is aborted.

## Chunked Responses

An application opts into chunked output by setting:

```tcl
::tclwire::http::io header set Transfer-Encoding chunked
```

Chunked responses:

- require HTTP/1.1
- must not also contain `Content-Length`
- accept only `chunked` as the response transfer coding
- commit on the first output event or flush
- encode and write each subsequent output event as one HTTP chunk
- write the terminating `0\r\n\r\n` chunk when the application completes

For example:

```tcl
method handle_request {request} {
    ::tclwire::io response 200 OK \
        [list "Content-Type: text/plain; charset=utf-8"] text utf-8
    ::tclwire::http::io header set Transfer-Encoding chunked
    ::tclwire::io out "first\n"
    ::tclwire::io flush
    ::tclwire::io out "second\n"

    # Finish the transfer now. This flushes "second\n" and sends complete.
    ::tclwire::io complete

    # The response is closed, but this worker remains running until the method
    # returns. Later response output is intentionally ignored.
    ::tclwire::io out "not sent"
    my perform_cleanup
}
```

Application code may therefore terminate a chunked transfer explicitly by
calling `::tclwire::io complete`. If it does not, returning successfully from
`handle_request` causes the CGA to call it automatically. On receiving the
`complete` event, the connection thread writes the zero-length terminating
chunk:

```text
0\r\n
\r\n
```

Applications must not write this marker through `::tclwire::io out`; doing so
would place those bytes inside a normal data chunk.

The connection thread, not the application or CGA, generates response heads,
data-chunk frames, and the terminating chunk.

## Output Events

Worker output is transported as ordered dictionaries with these common fields:

```tcl
dict create \
    type            $event_type \
    transaction_id  $transaction_id \
    output_sequence $sequence_number \
    stream          stdout \
    data            $event_data \
    flags           $event_flags
```

The implemented event types are:

| Type | Purpose |
| --- | --- |
| `response` | Set status, reason, initial headers, body mode, and encoding. |
| `http_header` | Set, add, or remove one HTTP header. |
| `output` | Transfer buffered text or binary body data. |
| `flush` | Request output progress. |
| `no_body` | Discard response representation data. |
| `complete` | Finish and send the response. |
| `error` | Report application failure. |

Events are sent asynchronously to the connection thread. Sequence numbers must
be contiguous and begin at 1. The Connection Agent ignores events for inactive
transactions and aborts invalid event sequences or state transitions.

Detailed descriptor and event field definitions are in
[`AGENT_DATA_STRUCTURES.md`](./AGENT_DATA_STRUCTURES.md).

## Error Behavior

The connection thread handles malformed requests before worker dispatch:

- invalid request line or headers
- conflicting request framing
- incomplete or invalid chunk framing
- unsupported transfer coding
- invalid query encoding

Application construction and `handle_request` errors become `error` events.
If the HTTP response is still uncommitted, the Connection Agent sends
`500 Internal Server Error`. If output has already committed the response, it
closes the connection because a replacement response cannot be sent safely.

Invalid response metadata, body-mode changes, header changes after commitment,
and broken output-event ordering also abort the application response.

## Connection Lifetime and Current Limitations

The current implementation processes one request per accepted connection and
closes the channel after the response. Keep-alive and HTTP pipelining are not
implemented.

Current limitations relevant to the worker API are:

- request bodies are fully buffered in memory
- request descriptors are copied between threads
- application objects are recreated for each request
- workers cannot access client channels
- non-chunked response bodies are accumulated before transmission
- there is no cancellation message from a closed connection to a running CGA
- there is no worker-facing request-body stream, response-writer object, or
  backpressure API

These are future extension points, not part of the current application
contract.

## Implementation References

- Request parsing: [`tcl/http_protocol.tcl`](../tcl/http_protocol.tcl)
- Read-only request API: [`tcl/http_request.tcl`](../tcl/http_request.tcl)
- Connection and response state:
  [`tcl/http_connection_agent.tcl`](../tcl/http_connection_agent.tcl)
- Application selection and worker dispatch:
  [`tcl/application_dispatcher.tcl`](../tcl/application_dispatcher.tcl)
- CGA request lifecycle:
  [`tcl/content_generator_agent.tcl`](../tcl/content_generator_agent.tcl)
- Application output commands:
  [`tcl/application_io.tcl`](../tcl/application_io.tcl)
- HTTP output controls:
  [`tcl/http_application_io.tcl`](../tcl/http_application_io.tcl)
- Default application API: [`tcl/application.tcl`](../tcl/application.tcl)
