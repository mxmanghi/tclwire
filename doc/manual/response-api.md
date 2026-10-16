# Response API

Applications use `::tclwire::io` for response metadata, buffered output, and
connection-owned downloads. The full worker API is described in
`runtime-doc/WORKER_REQUEST_API.md`.

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
