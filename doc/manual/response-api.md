# Response API

Applications use `::tclwire::io` for response metadata, buffered output, and
connection-owned downloads. Response metadata is represented by a Tcl
dictionary called a **response descriptor**. This page defines that dictionary,
the points at which it is used, and the rules that apply before it becomes an
HTTP response.

## Response descriptor

A response descriptor is an ordinary Tcl dictionary. Its canonical form is
used in three places:

- as the value of `response` in a `prepare_request` reply action;
- as the argument and return value of the application's `prepare_response`
  method; and
- as the result of `::tclwire::io response_descriptor` during an active
  request.

For example, an immediate response from `prepare_request` can be written as:

```tcl
return [dict create action reply response [dict create \
    status 200 \
    reason OK \
    headers [list \
        [list Content-Type "text/plain; charset=utf-8"] \
        [list Cache-Control "no-store"]] \
    body "Hello, world!\n" \
    body_mode text \
    encoding utf-8]]
```

The dictionary is a value, not an object identity. Applications may copy it,
pass it between interpreters, serialize it with a suitable Tcl-aware format,
and modify a local copy with `dict set` or `dict lappend`.

### Fields

| Field | Required | Default | Accepted value and meaning |
| --- | --- | --- | --- |
| `status` | Yes for an immediate reply | `200` for normal output | An integer HTTP status code. Application responses should use the HTTP range `100` through `599`; ordinary final responses normally use `200` through `599`. |
| `reason` | No | `OK` | The HTTP reason phrase. It is carried on the HTTP/1.1 status line but has no response-selection semantics. Supply the phrase matching `status`; `::tclwire::http::codes reason $status` returns TclWire's conventional phrase. |
| `headers` | No | Empty list | An ordered Tcl list of two-element `{name value}` lists. Names are compared case-insensitively. Order and repeated fields, including multiple `Set-Cookie` fields, are preserved. |
| `body` | No | No body data | The complete body of an immediate `prepare_request` reply. It is not response metadata and is absent from `response_descriptor` and the descriptor passed to `prepare_response`. |
| `body_mode` | No | `text` | Exactly `text` or `binary`. It determines whether TclWire encodes the body or treats it as an existing byte sequence. |
| `encoding` | No | Application encoding | A Tcl encoding name used by `encoding convertto` in `text` mode. An empty value selects the application's configured encoding. It has no effect in `binary` mode. |

Only these fields are part of the application contract. Do not attach private
keys to a descriptor and expect TclWire to preserve or act on them.

The `status` field is the only required field in an immediate reply. Although
the other fields have defaults, specifying `reason` whenever `status` is not
200 avoids accidental status lines such as `404 OK`. A descriptor observed by
`prepare_response` or `response_descriptor` is complete and contains `status`,
`reason`, `headers`, `body_mode`, and `encoding`.

!!! note "Current validation boundary"

    Invalid body modes, text encodings, and transfer framing fail when the
    response is prepared or serialized. Incremental HTTP header helpers and
    changed headers returned by `prepare_response` validate header syntax. The
    current dictionary API does not independently range-check `status`, reject
    control characters in `reason`, or provide one public validator for every
    construction path. Treat the table above as the application contract; do
    not put untrusted input into status lines or raw header lines.

### Header representation

Inside a descriptor, each header is a two-element list:

```tcl
set response [dict create \
    status 200 \
    headers [list \
        [list Content-Type "text/html; charset=utf-8"] \
        [list Set-Cookie "theme=dark; Path=/"] \
        [list Set-Cookie "density=compact; Path=/"]]]
```

The field name must match the HTTP token syntax. The value may not contain a
carriage return or newline. A value containing spaces remains one Tcl list
element because it is nested in `[list ...]`. Constructing headers with `list`
is safer than hand-writing a deeply quoted Tcl list.

Header names are case-insensitive, but TclWire preserves the spelling supplied
by the application. Repeated names are valid and remain ordered. Whether a
particular HTTP field permits repetition or requires a particular value is the
application's responsibility.

The argument of `::tclwire::io response` deliberately has a different shape:
it is a list of formatted HTTP header lines. The output bridge parses those
lines and stores pairs in the canonical descriptor:

```tcl
::tclwire::io response 200 OK [list \
    "Content-Type: text/plain; charset=utf-8" \
    "Cache-Control: no-store"] text utf-8

set descriptor [::tclwire::io response_descriptor]
# dict get $descriptor headers =>
# {Content-Type {text/plain; charset=utf-8}} {Cache-Control no-store}
```

Do not pass a descriptor's pair-form `headers` value directly as the `headers`
argument of `::tclwire::io response`. Application handlers that want to change
one field can instead use `::tclwire::http::io header set`, `add`, or `remove`.

!!! warning "Helper dictionaries in the current API"

    `::tclwire::http::redirect response` and
    `::tclwire::http::errors response` currently return send-ready dictionaries
    whose `headers` field contains formatted header lines. Their `send` or
    framework paths pass those lines to `::tclwire::io response`. They are not
    canonical hook descriptors: convert their headers to `{name value}` pairs
    before nesting one in a `prepare_request` reply or returning it from
    `prepare_response`.

### Body modes and encodings

| `body_mode` | Body value | Wire representation | `encoding` |
| --- | --- | --- | --- |
| `text` | Tcl string | Result of `encoding convertto` | Must name a Tcl encoding, or be empty to use the application encoding. |
| `binary` | Byte-oriented Tcl value, normally a bytearray | Bytes are written unchanged | Ignored. |

All output for one response must use one body mode. An explicit
`::tclwire::io response ... $body_mode` fixes the mode. Without an explicit
response command, the first `::tclwire::io out` may change the implicit
`text` response to `binary`. Mixing later `text` and `binary` output is an
error.

Character count and encoded byte count are not generally equal. Let TclWire
calculate `Content-Length` for buffered output. If an application supplies
that header itself, its value must describe the final encoded bytes, not the
Tcl string length.

### Status and body semantics

The descriptor records an application's response choice; it does not infer all
HTTP semantics from the status code. In particular:

- a `HEAD` request is serialized without body bytes, while its headers describe
  the corresponding `GET` representation;
- applications producing `1xx`, `204`, `205`, or `304` responses must not emit
  a representation body; use `::tclwire::http::no_body` if output may already
  have been buffered;
- a known-length `download` rejects statuses below 200 and statuses 204, 205,
  and 304; and
- redirect status selection is available through
  `::tclwire::http::redirect`, which accepts 301, 302, 303, 307, and 308.

### Framing-related headers

For an ordinary buffered response, TclWire encodes the complete body and adds
`Content-Length` when the application did not provide one. Responses use
`Connection: close`.

The only supported response transfer coding is a single
`Transfer-Encoding: chunked` field. It requires HTTP/1.1 and cannot be combined
with `Content-Length`. When chunked transfer is selected, output can be written
as chunks and `complete` writes the terminating chunk. On an eligible HTTP/1.1
response, an environment may also request automatic promotion to chunked
transfer when flushing output.

Applications normally should leave framing to TclWire. Use an explicit
`Content-Length` only when its encoded byte length is already known, and use
`Transfer-Encoding: chunked` only when streaming behavior is required.

## Creating and inspecting a response

### Normal handler output

`::tclwire::io response` sets all response metadata at once:

```tcl
::tclwire::io response 201 Created [list \
    "Content-Type: application/json; charset=utf-8"] text utf-8
::tclwire::io out {{"created":true}} text
```

Its signature is:

```text
::tclwire::io response status reason headers ?body_mode? ?encoding?
```

`body_mode` defaults to `text`; an empty `encoding` selects the application
encoding. Calling `response` sends metadata to the connection thread but does
not send the locally buffered body or complete the response.

If a handler never calls `response`, the transaction starts with this metadata:

```tcl
dict create status 200 reason OK headers {} body_mode text encoding {}
```

`::tclwire::io response_descriptor` returns the current metadata dictionary.
It requires an active request and returns a value copy; changing that copy does
not change the active response. Use the response command or HTTP header helpers
to change handler output.

### Immediate replies from `prepare_request`

`prepare_request` can skip `handle_request` by returning a reply action:

```tcl
method prepare_request {request} {
    if {[$request path] ne "/health"} {
        return [dict create action pass]
    }
    return [dict create action reply response [dict create \
        status 200 \
        reason OK \
        headers [list [list Content-Type "text/plain; charset=utf-8"]] \
        body "ok\n" \
        body_mode text \
        encoding utf-8]]
}
```

TclWire applies field defaults, converts the header pairs to response header
lines, and emits `body` using the selected mode. `prepare_response` still runs
before this response is committed.

### Finalizing metadata with `prepare_response`

The application method receives the request object and the canonical metadata
descriptor. It must return a dictionary containing at least `status`. Omitted
metadata fields are merged from the descriptor it received. A typical method
returns the same descriptor after changing its pair-form headers:

```tcl
method prepare_response {request response} {
    if {[dict get $response status] >= 200 &&
            [dict get $response status] < 300} {
        dict lappend response headers [list Cache-Control "no-store"]
    }
    return $response
}
```

The hook changes metadata only. It cannot replace or add body data by setting a
`body` key. It must not call response-output or completion commands.

Preparation happens once, immediately before metadata must become immutable:

- at `complete` for a buffered response;
- before commitment for chunked output or a flush that enables chunking; or
- before a known-length download is delegated.

After preparation, `::tclwire::io response_is_prepared` returns true and
attempts to replace response metadata or change headers fail. For a streaming
response, this boundary can occur while `handle_request` is still running.

### Completion and errors

`::tclwire::io complete` prepares metadata, emits buffered data, and marks
application output complete. TclWire calls it automatically after a successful
handler return if the response is still open, so handlers rarely need to call
it themselves.

An error before headers are committed can be replaced with a 500 response. An
error after commitment cannot replace bytes already sent; TclWire closes the
connection. `::tclwire::io close_connection` deliberately closes without
sending the buffered response.

## Why the descriptor is a dictionary

The response descriptor crosses application hooks as a Tcl value and is
translated into ordinary event dictionaries for the connection thread. A
dictionary keeps those boundaries serializable, inspectable, and easy to
extend without giving another interpreter access to an object's identity or
lifetime.

A TclOO response builder can still be useful as an application-side convenience
when it validates setters or supplies higher-level operations. Such a builder
should produce a canonical dictionary snapshot at the TclWire boundary. If
stronger consistency is added to the runtime, a central dictionary validator
or constructor would preserve this value-oriented contract with less lifecycle
coupling than making the transported descriptor itself an object.

## Known-length downloads

`::tclwire::io download $descriptor` delegates the entire binary response body
to the connection agent. Data moves directly from a source channel to the client
channel through asynchronous `fcopy`; it does not pass through CGA output events
or the response-body buffer.

```tcl
set filename /srv/downloads/archive.zip
::tclwire::io response 200 OK [list "Content-Type: application/zip"] binary
::tclwire::io download [dict create \
    filename $filename filesize [file size $filename]]
::tclwire::io complete
```

Use a list of header lines when specifying multiple response headers, for example
`[list "Content-Type: application/zip" "Content-Disposition: attachment"]`.

A file descriptor requires an absolute `filename` and non-negative `filesize`.
The connection agent opens the file and verifies its length before committing
headers. An optional `range {first last}` selects inclusive byte offsets:

```tcl
::tclwire::io download [dict create \
    filename $filename filesize [file size $filename] range {1024 2047}]
```

The range must lie inside the file. TclWire sets status 206, `Content-Range`, and
`Content-Length` for a range; the original response status must be 200 or 206.
This API does not parse the request's Range header or generate multipart ranges.
The application selects the range to serve. An empty file uses `filesize 0` with
no range.

A channel descriptor requires `channel` and a non-negative `length`:

```tcl
set source [open $filename rb]
try {
    seek $source 1024
    ::tclwire::io download [dict create channel $source length 1024]
} finally {
    # After handoff the channel is no longer registered in this CGA thread.
    catch {close $source}
}
```

The copy starts at the channel's current position. TclWire sets binary IO and
removes source event handlers. The channel must support transfer between threads
and asynchronous copying; channels dependent on interpreter-local callbacks are
not generally suitable. After handoff, the application must not use the channel.
The receiving subsystem closes it on success, failure, rejection, or cancellation.
If validation or thread transfer fails before ownership moves, the caller still
owns the source. Unknown lengths are not supported by this download API.

## Framing and completion

Downloads use `Content-Length`, never chunked encoding. An existing length must
agree with the descriptor; `Transfer-Encoding`, duplicate lengths, and statuses
that prohibit bodies are rejected. HEAD sends the corresponding headers, closes
the source, and copies no body bytes.

Set response metadata before calling `download`. The response preparation hook
runs at delegation. A download must be the only body source: buffered output,
subsequent `out` calls, and additional downloads cannot be combined with it.
`flush` after delegation is a no-op.

`complete` means that the application has finished producing the response.
The CGA can return to its pool while the connection thread continues the copy.
The connection finishes only after application completion, transfer completion,
and local output drain. Local drain does not establish delivery to the client.

A source that ends before the declared length fails the transfer. Errors before
header commitment produce a 500 response; errors after commitment close the
connection without replacing or appending another response. Closing or timing
out the connection cancels the active copy and closes its source.

## Copy strategy and progress

Both descriptors accept `blocksize`:

- Omitted: successive asynchronous copies of at most 65536 bytes.
- Positive integer: the maximum bytes in each copy.
- Zero: one asynchronous copy of the entire declared length.

The connection-owned `::tclwire::BodyTransfer` object implements the copy
lifecycle separately from HTTP policy. Its callback receives a status dictionary
at copy checkpoints and on completion or failure. `status` returns `state`,
`length`, `copied_bytes`, and `error`; the connection agent exposes the same
snapshot through `transfer_status` while the transfer exists.

`copied_bytes` is the count reported by completed `fcopy` callbacks, including
partial progress reported with an error. It is not a client acknowledgement and
is not updated within a copy. There is no callback into the originating CGA.
The existing 30-second connection timeout is refreshed at nonempty copy
checkpoints. Consequently, a single-copy transfer must finish within that
interval; use bounded copies for longer transfers. A bounded copy that itself
stalls beyond that interval is also cancelled.

The transfer object owns source reads and response-body writes while active.
Future framing strategies can implement the same lifecycle without changing the
application completion contract.
