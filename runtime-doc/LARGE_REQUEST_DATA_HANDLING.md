# Large Request Data Handling

This document describes how TclWire handles HTTP request bodies that may be
too large to keep entirely in memory, how the in-memory-to-file threshold is
applied, and how application code accesses request data through the
`HttpRequest` abstraction.

## Design Goals

TclWire treats in-memory request bodies as a useful fast path, not as the only
storage model. Most requests are `GET`, small form posts, or short API calls;
for these, a Tcl string is simple and efficient. Larger uploads need a bounded
memory profile, so the HTTP protocol session uses a hybrid body sink:

- start in memory;
- count decoded request-body bytes;
- when the configured threshold is crossed, create a temporary spool file;
- move bytes already accumulated in memory into that file;
- write all following body bytes directly to the file.

The application-facing object, `::tclwire::HttpRequest`, hides the transported
descriptor and exposes request data through methods. Applications should not
depend on the descriptor layout except where explicitly documented.

## Incremental Parsing Flow

HTTP parsing is owned by the connection thread. Application workers do not own
the client socket and do not parse bytes from the network.

The current flow is:

1. `HttpConnectionAgent::readable` reads a bounded amount of data from the
   socket.
2. The bytes are passed to `HttpProtocolSession::feed`.
3. `HttpProtocolSession` incrementally parses:
   - request line and headers;
   - body framing;
   - fixed-length bodies;
   - chunked bodies;
   - supported transfer codings such as `gzip, chunked`.
4. Decoded body bytes are appended to the current body sink.
5. When the request is complete, the protocol session returns a request
   descriptor with a body storage mode.
6. `HttpConnectionAgent` adds connection and transaction metadata.
7. `ApplicationDispatcher` sends the descriptor to the selected CGA worker.
8. The CGA constructs an immutable `HttpRequest` object and calls
   `handle_request`.

The important boundary is that application execution starts after the complete
request has been received. The request body is parsed incrementally, but the
current application API is still a complete-request API, not a streaming body
API.

## Body Size Accounting

The threshold is applied to decoded request-body bytes.

For a fixed-length request, these are the bytes described by
`Content-Length`. For a chunked request, chunk framing is removed before bytes
are appended to the body sink. For supported transfer-coding chains such as
`gzip, chunked`, the decoded payload is counted after transfer decoding.

Two limits matter:

- `max_request_bytes`: maximum accepted decoded request body size;
- `request_memory_threshold`: maximum decoded body bytes kept in memory before
  spooling begins.

If appending a chunk would make the decoded body larger than
`max_request_bytes`, the request fails with a body-too-large error and the
connection agent returns an HTTP error response.

## Threshold Semantics

The threshold transition happens in `HttpProtocolSession::append_body`.

Conceptually:

```tcl
set new_size [expr {$body_size + [string length $bytes]}]

if {$new_size > $max_body_bytes} {
    error "decoded request body exceeds configured limit"
}

if {$body_channel eq {} && $new_size > $body_threshold} {
    my spill_body
}

if {$body_channel eq {}} {
    append body_data $bytes
} else {
    puts -nonewline $body_channel $bytes
}

set body_size $new_size
```

This means:

- the threshold is inclusive for memory: a body whose final size is exactly
  `request_memory_threshold` stays in memory;
- spooling starts before accepting the first byte range that makes the size
  greater than the threshold;
- after spooling starts, the request does not migrate back to memory;
- `request_memory_threshold = 0` spools every non-empty body;
- an empty body remains an empty in-memory body;
- if file storage is disabled by an empty `upload_area`, TclWire sets the
  effective protocol threshold to the request limit, so accepted bodies remain
  in memory and bodies above the limit are rejected instead of spooled.

Example with a 1 MiB threshold:

| Body size | Result |
| ---: | --- |
| `0` bytes | `body_media raw`, `body_storage in_memory` |
| `1 MiB` | `body_media raw`, `body_storage in_memory` |
| `1 MiB + 1` byte | `body_media raw`, `body_storage spooled_file` |

When the threshold is crossed, `spill_body`:

1. verifies the spool directory exists or creates it;
2. verifies that it is writable;
3. creates a temporary file using the `tclwire-request` prefix;
4. writes the already buffered in-memory bytes to that file;
5. clears the in-memory body buffer;
6. writes current and subsequent bytes to the file.

At request completion, the protocol session closes the file and transfers
ownership of the file path to the completed request descriptor.

## Resulting Body Representation

The completed descriptor separates body interpretation from body storage:

- `body_media` describes how the body should be interpreted: `raw` or
  `multipart`;
- `body_storage` describes where the raw body bytes are stored, or whether the
  body has been decomposed into structured parts.

### `in_memory`

The body is stored as a Tcl byte string in the descriptor.

Descriptor fields:

- `body_media raw`
- `body_storage in_memory`
- `body`
- `body_size`

Applications access it with:

```tcl
set bytes [$request body]
set size  [$request body_size]
```

`$request body` is valid only for this mode.

### `spooled_file`

The body is stored in a temporary file.

Descriptor fields:

- `body_media raw`
- `body_storage spooled_file`
- `body_path`
- `body_size`

Applications access it with:

```tcl
set path [$request body_path]
set size [$request body_size]
```

`$request body_path` is valid only for this mode. `$request body` raises an
error because the body is intentionally not stored in memory.

The file is request-owned. Unless the application configuration has
`retain_uploaded_files = true`, TclWire deletes the spool file after
`handle_request` returns. An application that wants to keep the data should
move or copy it to an application-owned location before returning.

### `multipart`

Multipart handling has one extra compatibility layer. Once the request headers
are parsed, `HttpProtocolSession` detects a `multipart/*` `Content-Type` and
switches the decoded body sink to an incremental multipart parser. The complete
request descriptor is therefore already normalized as multipart when it reaches
`HttpConnectionAgent`.

With a nonempty `upload_area`, file parts are written to temporary files and
represented as multipart part dictionaries while decoded request bytes are
still being fed. No aggregate multipart spool file is reread or materialized as
a single Tcl byte string. The descriptor uses:

- `body_media multipart`
- `body_storage decomposed`
- `multipart_parts`
- `body_size`

Applications should use:

```tcl
set fields [$request form_fields]
set files  [$request uploaded_files]
```

or:

```tcl
set part [$request uploaded_file avatar]
```

Multipart file parts may themselves use `body_storage spooled_file` and contain a
`body_path`. Non-file form fields remain in memory. Applications therefore use
the same `HttpRequest` methods for multipart requests independently of the
whole-body storage mode selected by the threshold.

## `HttpRequest` as the Opaque Application Interface

`HttpRequest` is the application-facing wrapper around the transported request
descriptor. It is intentionally read-only.

Applications should prefer methods such as:

```tcl
$request method
$request path
$request query_parameters
$request headers
$request header Content-Type
$request body_media
$request body_storage
$request body_size
$request body
$request body_path
$request multipart_parts
$request form_fields
$request uploaded_files
$request trailers
$request trailer X-Checksum
```

The method layer provides two important properties:

1. It hides the transport representation. The connection thread and CGA worker
   can change descriptor details without requiring application code to inspect
   raw dictionaries.
2. It enforces storage-mode correctness. Calling `$request body` for a
   `spooled_file` request is an error; calling `$request body_path` for an
   `in_memory` request is an error.

Trailer fields are exposed separately from header fields. They arrive only
after the terminating chunk of a chunked request, so they cannot participate in
message framing, routing, authentication, or body interpretation decisions that
were already made from the header section. Typical use is optional late
metadata, such as a checksum, digest, signature, or post-stream processing
status computed while the sender produced the body.

Typical storage-independent handling looks like this:

```tcl
switch -- [$request body_media] {
    raw {
        switch -- [$request body_storage] {
            in_memory {
                set data [$request body]
                # Process $data.
            }
            spooled_file {
                set path [$request body_path]
                # Stream, move, or copy $path.
            }
        }
    }
    multipart {
        foreach file [$request uploaded_files] {
            if {[dict get $file body_storage] eq "spooled_file"} {
                set path [dict get $file body_path]
                # Stream, move, or copy the uploaded part.
            }
        }
    }
    default {
        # No body or an unsupported future mode.
    }
}
```

This branch belongs at the application boundary. Deeper application code should
receive a domain-specific value, stream, or file path rather than reaching back
into the raw request descriptor.

## Cleanup and Ownership

Temporary request files are owned by TclWire until application code explicitly
takes ownership.

At the end of request processing, the CGA calls upload cleanup using the
worker-local application configuration:

- if `retain_uploaded_files` is false, TclWire deletes whole-body spool files
  and multipart part spool files that still exist;
- if a file was moved by the application, deletion is skipped because the
  original path no longer exists;
- if `retain_uploaded_files` is true, TclWire leaves request spool files in
  place and external cleanup becomes the application's responsibility.

Retained files contain untrusted client data. Applications should validate,
rename, permission, and clean them according to their own policy.

## Configuration Summary

Global options:

- `--upload-area <path>`
- `--max-request-bytes <count>`
- `--request-memory-threshold <count>`

TOML equivalents:

- `tclwire.upload_area`
- `tclwire.max_request_bytes`
- `tclwire.request_memory_threshold`

HTTP and HTTPS service tables may override:

- `upload_area`
- `max_request_bytes`
- `request_memory_threshold`

Defaults:

- `upload_area`: `/tmp`
- `max_request_bytes`: `16777216`
- `request_memory_threshold`: `1048576`

## Current Limitations

The current implementation bounds memory for large whole request bodies and
multipart file parts, but it is not yet a streaming application API:

- `handle_request` starts after the request is complete;
- application workers do not read from client sockets;
- multipart form fields are still retained in memory;
- applications must branch on `body_storage` only when they need raw, non-multipart
  body data.

These limitations are deliberate boundaries of the current architecture. They
leave room for a future streaming request-body interface without exposing
socket ownership to application code prematurely.
