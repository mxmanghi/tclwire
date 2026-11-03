# Application Output

The `tclwire::application::io` package exposes the `::tclwire::io` command for
response metadata, buffered output, completion, and delegated file downloads.
The HTTP helpers provide header and cookie controls. These commands operate
inside an active application request; the CGA establishes their output context.

For request objects and application lifecycle hooks, see the
[Worker Request API](../runtime-doc/WORKER_REQUEST_API.md).

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

## Standard Channel Compatibility

Applications that enable the `stdchans` environment can use familiar Tcl
standard-channel syntax for `stdout` response output:

```toml
[http.legacy]
class = "::example::LegacyApplication"
file = "legacy.tcl"
environment = "stdchans"
```

When a TclWire output transaction is active, `stdchans` shadows these global
commands:

```tcl
puts ?-nonewline? ?stdout? $string
flush stdout
fconfigure stdout ?-option? ?-option value ...?
chan configure stdout ?-option? ?-option value ...?
chan puts ?-nonewline? ?stdout? $string
chan flush stdout
```

This is an intentionally limited response-output compatibility facade, not a
complete Tcl channel implementation. Only the listed `stdout` command forms are
intercepted. Operations on other channels are delegated to Tcl's native
implementations, while unlisted `chan` operations on `stdout` may still address
the process's real standard channel. Of the virtual `fconfigure` settings,
binary encoding or translation selects byte-preserving response output; other
settings do not reproduce every native channel behavior.

For normal text output:

```tcl
method handle_request {request} {
    puts "hello"
    puts stdout "world"
}
```

This is equivalent to writing text through `::tclwire::io puts`; the CGA
completes the response when `handle_request` returns.

For binary output through standard-channel syntax, configure virtual `stdout`
before writing bytes:

```tcl
method handle_request {request} {
    fconfigure stdout -translation binary
    puts -nonewline stdout [binary format H* 0080ff]
}
```

`chan configure` is equivalent:

```tcl
method handle_request {request} {
    chan configure stdout -translation binary
    chan puts -nonewline stdout [binary format H* 89504e470d0a]
}
```

A first binary stdout write may establish the implicit response body mode as
`binary` when no explicit response metadata has been sent and no response body
has started. If the application declares response metadata itself, the declared
`body_mode` must match later output:

```tcl
method handle_request {request} {
    ::tclwire::io response 200 OK \
        [list "Content-Type: application/octet-stream"] binary
    fconfigure stdout -translation binary
    puts -nonewline stdout $payload
}
```

Changing virtual `stdout` back to text affects subsequent `puts stdout` calls.
Make such a change before emitting response data (or for a later response),
because one HTTP response has one body mode:

```tcl
fconfigure stdout -translation lf -encoding utf-8
puts stdout "text again"
```

Do not mix text and binary output in one HTTP response, even across a flush.
The worker buffer rejects an unflushed mixture, and the connection agent rejects
a body-mode change after response output has started. A flush is a streaming
boundary, not a body-mode boundary.

With HTTP/1.1, `flush stdout` may also promote an eligible response to chunked
streaming when the effective `stdchans` environment configuration has
`auto_chunked_on_flush = true`. The `rivet` environment enables this default
for its `stdchans` dependency; direct `stdchans` applications can configure it
explicitly:

```toml
[env.stdchans]
auto_chunked_on_flush = true
```

```tcl
method handle_request {request} {
    puts -nonewline stdout "first"
    flush stdout
    after 1000
    puts -nonewline stdout "second"
}
```

Non-`stdout` channels still behave like ordinary Tcl channels:

```tcl
method handle_request {request} {
    set channel [open [file join [my document_root] data.txt] r]
    try {
        fconfigure $channel -encoding utf-8
        set data [read $channel]
    } finally {
        close $channel
    }

    puts stdout $data
}
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

For test-server behavior and protocol-edge cases, an application can ask the
connection thread to close the client connection without serializing a
response:

```tcl
::tclwire::io close_connection
```

This discards worker-local buffered output, sends a `close_connection` event,
and marks the CGA output context completed. Used before any response bytes are
written, the client receives an empty response. Used after committed chunked
output or other bytes have reached the socket, it deliberately creates an
abrupt partial response.

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
| `download` | Delegate a known-length binary body source to the connection thread. |
| `flush` | Request output progress. |
| `no_body` | Discard response representation data. |
| `complete` | Finish and send the response. |
| `close_connection` | Close the connection without sending an accumulated response. |
| `error` | Report application failure. |

Events are sent asynchronously to the connection thread. Sequence numbers must
be contiguous and begin at 1. The Connection Agent ignores events for inactive
transactions and aborts invalid event sequences or state transitions.

Detailed descriptor and event field definitions are in
[`AGENT_DATA_STRUCTURES.md`](../runtime-doc/AGENT_DATA_STRUCTURES.md).

## Delegated Known-Length Downloads

`::tclwire::io download $descriptor` sends a no-data `download` event whose
`flags` contain one of these source descriptors:

```tcl
{filename /absolute/path/archive.bin filesize 1000000}
{filename /absolute/path/archive.bin filesize 1000000 range {100 999}}
{channel file42 length 900}
```

File ranges use inclusive offsets. Channel sources begin at their current
position and require an explicit length. The IO bridge transfers channel
ownership to the connection thread before sending the event. After successful
handoff, the CGA must not read, write, or close that channel. The receiver closes
sources even when their transaction or connection has already disappeared.
Before a successful handoff, the application retains cleanup responsibility.

Each descriptor optionally accepts `blocksize`: the default is 65536 bytes per
asynchronous `fcopy`; zero selects one copy. These are copy checkpoints, not HTTP
chunks. Downloads use `Content-Length`; unknown-length streaming is not yet
implemented. The entire response body must come from this one source. Configure
headers before delegation, and do not mix it with ordinary `out` events.

The HTTP connection agent validates framing and file metadata, then delegates IO
to `::tclwire::BodyTransfer` (`tclwire::body_transfer`). A range produces 206 and
`Content-Range`. HEAD sends the corresponding length but no body. The transfer
object reports `state`, `length`, `copied_bytes`, and `error` through a local
callback and its `status` method. The agent exposes `transfer_status`; no progress
callback is sent to a CGA which may already be handling another request.

For downloads, `complete` records application completion. Actual response
completion additionally waits for the transfer and local output drain. Source
EOF before the declared length or a write error aborts the response; connection
closure cancels copying and releases the source. Progress and accounting advance
at completed copy checkpoints, not within a block and not on client receipt.
The existing 30-second connection timeout is refreshed at nonempty checkpoints;
with `blocksize 0` there is no refresh during the copy. Bounded copies should be
used for longer transfers.

See the [Response API](manual/response-api.html)
for further ownership and framing details.

### Example: Download a Whole File

For a whole-file attachment, the handler needs only one call:

```tcl
method handle_request {request} {
    ::tclwire::io download_file /srv/downloads/report.pdf
    # Returning lets the CGA complete the application side of the response.
}
```

To specify the MIME type explicitly, replace the call with:

```tcl
::tclwire::io download_file /srv/downloads/archive.zip application/zip
```

These are alternative calls, each supplying the entire response. The optional
MIME type defaults to Application's extension registry (and honors application
overrides). When the extension is unknown or absent, TclWire lazily loads
Tcllib's `fileutil::magic::filetype` (version 2 or later) and probes the file's
contents for a MIME type. Recognized extensions bypass this probe. If the probe
fails or supplies no MIME type, the result remains `application/octet-stream`. Text types use the application's configured encoding. The runtime binds the
application and request with `::tclwire::io configure_application`; response
preparation and automatic MIME detection require this context.
The helper determines the size, sets status 200, Content-Type and an attachment
Content-Disposition using the basename, then delegates to `download`. It sends
the whole file, including empty files, without interpreting Range headers.
Call it before any body output or response preparation, then return from the
handler; normal application completion still applies.

Missing files and non-regular sources produce the standard 404 response;
denied read access produces 403, and other filesystem failures produce 500.
Failures are logged at error level. Successful delegation is logged at debug
level with transaction ID, filename, size, and MIME type. This records scheduling,
not transfer completion. The connection agent reopens the file and verifies its
size, so keep it available and unchanged until the asynchronous transfer finishes.
The path is a server filesystem path; the application must authorize access before
calling the helper. Use the lower-level `download` API for ranges or custom headers.

### Registering MIME Types

Applications can register additional extension mappings before serving files:

```tcl
::tclwire::io register_mime_type .m text/x-matlab
```

The extension must include its leading dot and contain a single suffix. Matching
is case-insensitive, so this registration also matches `analysis.M`. The MIME
type must be a `type/subtype` without parameters; it is returned as registered,
without an automatically appended charset. Registering the same extension again
replaces its previous mapping, and registrations can override built-in types.
Invalid extensions or MIME types are logged at error level and ignored; the
procedure returns normally and leaves the registry unchanged. If logging fails,
the procedure raises the original validation error instead.

The registry is populated with the built-in extension mappings when
`tclwire::application::io` loads. Detection looks up the extension in this single
dictionary, then tries Tcllib's magic recognizer, and finally defaults to
`application/octet-stream`. Built-in text mappings retain the application's
charset; replacing one with `register_mime_type` returns the new MIME type
without an appended charset. Both `Application content_type` and `download_file`
use these mappings. An explicit MIME argument to `download_file` takes priority;
an application overriding `content_type` controls its own detection behavior.

The dictionary is local to each Tcl interpreter, shared by applications within
that interpreter, and persists across requests. Register types in application
initialization code that runs in each worker interpreter (for example, an
`initialize` method). Registering in the main server interpreter alone does not
propagate mappings to workers.

### Example: Download a File with Explicit Metadata

This handler serves a fixed archive as an attachment. Replace the absolute path
with a file available to the runtime:

```tcl
method handle_request {request} {
    set filename /srv/downloads/archive.zip
    set filesize [file size $filename]

    ::tclwire::io response 200 OK [list \
        "Content-Type: application/zip" \
        {Content-Disposition: attachment; filename="archive.zip"}] binary
    ::tclwire::io download [dict create \
        filename $filename \
        filesize $filesize \
        blocksize 65536]

    # Returning lets the CGA complete the application side of the response.
}
```

The connection agent opens the file, verifies that its size matches `filesize`,
and sets `Content-Length`. It copies the file asynchronously to the client;
the worker does not read the file into its output buffer or own a source channel
that it must close. Keep the source available and unchanged until copying ends.
The handler may return while the connection thread is still transferring data.
For HEAD, the same handler sends the corresponding headers without file bytes.

Set all response headers before `download`. Do not call `out`, write to virtual
`stdout`, or select chunked encoding for this response. Calling `complete`
explicitly is optional and does not wait for the transfer to finish.

### Example: Download a File Range

The lower-level API allows the application to choose an inclusive byte range.
This complete handler serves bytes 1024 through 2047 of a fixed, readable archive.
It checks the file size before delegating and returns 416 if the selected range
does not fit:

```tcl
method handle_request {request} {
    # This example assumes this authorized source exists and is readable.
    set filename /srv/downloads/archive.zip
    set filesize [file size $filename]
    set first 1024
    set last 2047

    if {$first < 0 || $last < $first || $last >= $filesize} {
        ::tclwire::io response 416 {Range Not Satisfiable} [list \
            "Content-Range: bytes */$filesize"]
        return
    }

    ::tclwire::io response 200 OK [list \
        "Content-Type: application/zip" \
        {Content-Disposition: attachment; filename="archive.zip"}] binary
    ::tclwire::io download [dict create \
        filename $filename \
        filesize $filesize \
        range [list $first $last] \
        blocksize 65536]
}
```

The initial response metadata uses status 200; the connection agent changes it
to 206 when it processes the range descriptor. For a 4096-byte source, the final
headers include `Content-Range: bytes 1024-2047/4096` and
`Content-Length: 1024`. The descriptor's `filesize` is the size of the **entire
file**, not the selected range.

This example selects a fixed range; `download` does not parse the request's
`Range` header. The application must parse and validate any client-supplied range
before delegation. For an empty file, use `filesize 0` without a range, or use
`download_file` to send the whole empty file.

### Example: Return a 404 Response

`download_file` automatically generates and logs a standard 404 when its source
is missing. An application can also return 404 explicitly, for example when a
requested download has no matching resource in its catalog. Use the shared error
catalog to keep the reason, headers, and body consistent with other TclWire errors:

```tcl
package require tclwire::http::errors 0.1
package require tclwire::logger::client 0.1

method handle_request {request} {
    # This branch handles a resource that the application could not find.
    set path [$request path]
    catch {
        ::tclwire::logger::log_error application \
            "status=404 path=[::tclwire::logger::log_value $path]" error
    }
    set failure [::tclwire::http::errors response 404 [dict create path $path]]
    dict with failure {
        ::tclwire::io response $status $reason $headers $body_mode $encoding
        ::tclwire::io out $body $body_mode
    }
    return
}
```

Use the requested URL path in the error message, rather than an internal
filesystem path. Generate the error before response preparation or body output,
and return without calling `download`. Returning lets the CGA complete the
buffered error response; an explicit `complete` call is optional.

## Implementation References

- [Application output bridge](../tcl/application_io.tcl)
- [HTTP output helpers](../tcl/http_application_io.tcl)
- [Connection and response state](../tcl/http_connection_agent.tcl)
- [CGA request lifecycle](../tcl/content_generator_agent.tcl)
