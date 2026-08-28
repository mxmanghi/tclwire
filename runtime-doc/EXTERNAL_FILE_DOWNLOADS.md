# Serving Downloads Outside the Document Root

This example implements a download endpoint in a Content Generator Agent
(CGA). It maps a public request path to a trusted file that may be anywhere on
the local filesystem, then delegates the HTTP representation work to
`::tclwire::CApplication`.

The application deliberately maps opaque identifiers rather than appending an
untrusted request path to a filesystem directory. For example:

```text
GET /download/manual
        |
        +-- catalogue key: manual
        +-- local file: /srv/private/manuals/product-manual.pdf
        +-- client filename: product-manual.pdf
```

Using `CApplication` preserves its existing binary transfer, `HEAD`, and byte
range behavior. The subclass only supplies the external path, optional media
type, and download disposition.

## Application Class

Store the following application in a Tcl file such as
`download_application.tcl`:

```tcl
package require tclwire::application 0.1

namespace eval ::example {}

oo::class create ::example::DownloadApplication {
    superclass ::tclwire::CApplication

    variable downloads

    constructor {application_descriptor} {
        next $application_descriptor

        # Public identifier -> private file metadata. These files do not need
        # to be beneath the configured document root.
        set configured [dict create \
            manual [dict create \
                path /srv/private/manuals/product-manual.pdf \
                filename product-manual.pdf \
                content_type application/pdf] \
            archive [dict create \
                path /var/lib/example/releases/current-release.zip \
                filename current-release.zip \
                content_type application/zip]]

        # Normalize administrator-controlled paths once when the request-local
        # application object is constructed.
        set downloads {}
        dict for {identifier entry} $configured {
            dict set entry path [file normalize [dict get $entry path]]
            dict set downloads $identifier $entry
        }
    }

    # Resolve the exact /download/<identifier> route to one catalogue entry.
    # Restricting identifiers also rejects encoded slashes and path separators
    # after CApplication has decoded the URL path.
    method download_entry {url_path} {
        set decoded_path [my decode_path $url_path]

        if {![regexp {^/download/([A-Za-z0-9_-]+)$} \
                $decoded_path -> identifier]} {
            return {}
        }
        if {![dict exists $downloads $identifier]} {
            return {}
        }

        return [dict get $downloads $identifier]
    }

    # Extend CApplication resolution only for the download route. All other
    # URLs retain the normal document-root and alias resolution behavior.
    method resolve_path {url_path} {
        set decoded_path [my decode_path $url_path]

        if {![string match "/download/*" $decoded_path]} {
            return [next $url_path]
        }

        set entry [my download_entry $url_path]
        if {$entry eq {}} {
            return {}
        }

        set local_path [dict get $entry path]
        if {![file isfile $local_path] || ![file readable $local_path]} {
            return {}
        }

        return [dict create \
            path       $url_path \
            local_path $local_path]
    }

    # CApplication normally derives Content-Type from the file extension. A
    # catalogue entry may provide an authoritative value instead.
    method file_resource {local_path} {
        set resource [next $local_path]

        dict for {identifier entry} $downloads {
            if {[dict get $entry path] eq $local_path &&
                    [dict exists $entry content_type]} {
                dict set resource content_type \
                    [dict get $entry content_type]
                break
            }
        }

        return $resource
    }

    # Construct both an ASCII fallback and an RFC 5987 UTF-8 filename. The
    # fallback replaces characters that are unsafe in an HTTP quoted string.
    method content_disposition {filename} {
        set filename [file tail $filename]
        if {$filename eq {}} {
            set filename download
        }

        set fallback {}
        foreach character [split $filename {}] {
            if {[regexp {^[A-Za-z0-9._ -]$} $character]} {
                append fallback $character
            } else {
                append fallback _
            }
        }

        set encoded {}
        binary scan [encoding convertto utf-8 $filename] cu* octets
        foreach octet $octets {
            set character [format %c $octet]
            if {[regexp {^[A-Za-z0-9!#$&+.^_`|~-]$} $character]} {
                append encoded $character
            } else {
                append encoded %[format %02X $octet]
            }
        }

        return "attachment; filename=\"$fallback\"; filename*=UTF-8''$encoded"
    }

    # prepare_response runs immediately before response metadata becomes
    # immutable. It therefore covers complete GET responses, 206 range
    # responses, and CApplication's optimized metadata-only HEAD response.
    method prepare_response {request response} {
        set response [next $request $response]

        if {[dict get $response status] ni {200 206}} {
            return $response
        }

        set entry [my download_entry [$request url_path]]
        if {$entry eq {} ||
                [$request local_path] ne [dict get $entry path]} {
            return $response
        }

        if {[dict exists $entry filename]} {
            set filename [dict get $entry filename]
        } else {
            set filename [file tail [dict get $entry path]]
        }

        # Replace any earlier Content-Disposition while retaining the order and
        # repeated values of every unrelated header.
        set headers {}
        foreach header [dict get $response headers] {
            if {![string equal -nocase \
                    [lindex $header 0] Content-Disposition]} {
                lappend headers $header
            }
        }
        lappend headers [list Content-Disposition \
            [my content_disposition $filename]]
        dict set response headers $headers

        return $response
    }
}
```

## Runtime Configuration

Register the class as an HTTP application. `docroot` remains required by the
application descriptor even though catalogue files may live elsewhere. It is
also used for requests that do not start with `/download/`.

```toml
[http.downloads]
class = "::example::DownloadApplication"
file = "download_application.tcl"
docroot = "/var/empty/tclwire"
encoding = "utf-8"
```

The Tcl file must be discoverable through the normal application file lookup.
An absolute path or an application/global `libdir` can be used when it is not
stored under the runtime or configuration directory.

## Request and Response Behavior

For a successful `GET /download/manual`, the inherited handler performs these
operations:

1. `resolve_path` selects the catalogue entry and sets the request's
   `local_path`.
2. `file_resource` obtains the byte length and content type.
3. `serve_complete_file` reads and emits the file in binary mode.
4. `prepare_response` adds `Content-Disposition` before the response head is
   committed.
5. The connection agent calculates `Content-Length` for the completed,
   non-chunked response and serializes the response to the client.

A typical response includes:

```http
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Type: application/pdf
Content-Disposition: attachment; filename="product-manual.pdf"; filename*=UTF-8''product-manual.pdf
Content-Length: 123456
```

The same mapping also retains the specialized `CApplication` behaviors:

- `HEAD` returns representation headers, including the exact file length,
  without reading or sending the file body.
- A satisfiable `Range` request returns `206 Partial Content` and the applicable
  `Content-Range`; the download disposition is retained.
- An unsatisfiable range returns `416 Range Not Satisfiable`.
- An unknown identifier, missing file, or unreadable file follows the normal
  `404 Not Found` path.
- Malformed percent encoding or a null byte follows the normal `400 Bad
  Request` path.

## Security Properties

The catalogue must contain administrator-controlled data. Request values must
not be accepted as catalogue file paths.

In particular, the example never joins the text following `/download/` to a
directory. It only accepts a restricted identifier and performs an exact
dictionary lookup. Consequently, values such as `..`, `%2f`, and backslashes
cannot select a different file.

The `filename` value is presentation metadata and does not select the file.
`content_disposition` reduces it to a basename, creates a conservative ASCII
fallback, and percent-encodes its UTF-8 form. TclWire's response-header
validation additionally rejects carriage returns and line feeds.

Authorization should be checked before returning a catalogue entry when files
are user-specific or otherwise protected. For example, `download_entry` may
consult authenticated request state or `prepare_request` may return a `403`
response before the inherited file handler runs.

## Transfer Size Consideration

The current `CApplication serve_complete_file` implementation reads the whole
file into the CGA output buffer. The connection agent does not commit an
ordinary non-chunked response until completion, which allows it to calculate
`Content-Length` but means this example is not a constant-memory sendfile
implementation. Byte-range requests read only their selected ranges.

For very large files, use an application-level size policy, an external object
store or reverse proxy, or a future TclWire streaming/file-delivery facility.
Do not change this example to issue repeated flushes under the assumption that
an ordinary non-chunked response will stream immediately.

## Related Runtime APIs

- [`WORKER_REQUEST_API.md`](WORKER_REQUEST_API.md) describes `HttpRequest`,
  `prepare_request`, `prepare_response`, CGA output, and response commitment.
- [`CONFIGURATION_OPTIONS.md`](CONFIGURATION_OPTIONS.md) describes application
  `docroot`, `libdir`, aliases, and class configuration.
- [`INTER_THREAD_COMMUNICATION.md`](INTER_THREAD_COMMUNICATION.md) describes
  how CGA output events reach the owning HTTP connection agent.
