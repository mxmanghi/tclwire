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
   `HttpRequest` object.
7. The application framework runs its optional `rewrite_hook`, then the
   application handles the request through
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
application ID, and values. The application worker script installs that
envelope once as worker bootstrap state; the CGA reconstructs and keeps a
worker-local configuration object for the lifetime of the worker. This
serialization format is an internal dispatcher/CGA agreement, not an
application configuration-file format or public persistence format.

The request descriptor does not carry application configuration. A CGA worker
belongs to one application pool, so runtime reconfiguration must replace pools
and retire their worker threads rather than changing a worker's application
configuration request by request.

`CApplication configuration_object` exposes the worker-local object.

The CGA exposes its application constitution through `::tclwire::app`.
Application state is stable for the worker after the application object has
been constructed, while request state is scoped to the current
`handle_request` invocation:

```tcl
::tclwire::app::current
::tclwire::app::configuration
::tclwire::app::application_snapshot
::tclwire::app::application_active

::tclwire::app::request
::tclwire::app::request_descriptor
::tclwire::app::request_snapshot
::tclwire::app::request_active
```

Environment commands should use these helpers instead of discovering
application state through caller frames. `::tclwire::cga::context` remains as a
compatibility wrapper for request-time callers, but new code should not depend
on it.

### Application Configuration Object

`::tclwire::ApplicationConfiguration` is the immutable, validated
representation of the effective descriptor for one configured application.
Inside a worker, the current application configuration is available as a
worker-local object:

```tcl
set configuration [::tclwire::app::configuration]
```

Application methods can also get the same object from the current application
instance:

```tcl
set configuration [my configuration_object]
```

The object is stable for the worker. It is not rebuilt for each request, and
applications should treat every value returned from it as read-only runtime
configuration.

The public object methods are:

| Method | Result |
| --- | --- |
| `id` | Application identifier from the runtime configuration, such as `default` or `hello`. |
| `get property` | One validated property value. Raises an error for an unknown property. |
| `snapshot` | Dictionary containing all validated effective descriptor values. Mutating the returned dictionary does not mutate the object. |
| `configure ?class_name?` | The complete class-keyed `configure` dictionary, or the block for one TclOO class. Missing class blocks return an empty dictionary. |
| `class_configuration class_name` | Alias-style semantic wrapper for `configure class_name`. |
| `environment_configuration ?environment_name? ?key?` | The complete environment configuration dictionary, one environment block, or one key from that environment block. Missing environments return an empty dictionary; missing keys raise an error. |
| `serialize` | Versioned dictionary envelope used internally when configuration crosses Tcl thread boundaries. |
| `class` | Resolved TclOO application class. Bare configured names are qualified under `::tclwire::app`. |
| `hosts` | List of host names that select the application. |
| `docroot` | Normalized application document root. |
| `encoding` | Application text encoding. |
| `application_paths` | Normalized path list used for application lookup and host/path selection. |
| `aliases` | List of static-resource alias dictionaries. |
| `package` | Package name required by package-backed applications, or empty. |
| `file` | Application source file for file-backed applications, or empty. |
| `chore` | Application chore source file, or empty. |
| `chore_class` | Application chore class name, or empty. |
| `libdir` | Application library directory added to worker `auto_path`, or empty. |
| `environment` | List of enabled application environment adapters. |
| `environment_config` | Dictionary of environment-specific option dictionaries. |
| `rewrite_hook` | Docroot-relative request-rewrite hook file, or empty. |
| `log_level` | Application log-level override, or empty. |
| `reload_on_request` | Boolean flag that retires a file-backed worker after each request. |
| `retain_uploaded_files` | Boolean flag controlling whether uploaded-file spool paths are retained after request cleanup. |
| `pool_policy` | Dictionary containing worker-pool limits, including `minimum_workers` and `maximum_workers`. |

`::tclwire::ApplicationConfiguration` also has the class method:

```tcl
set configuration [::tclwire::ApplicationConfiguration deserialize $envelope]
```

`deserialize` reconstructs a new object from the versioned dictionary returned
by `serialize`. This is primarily for runtime internals, chores, and thread
boundaries. Request handlers normally use `::tclwire::app::configuration` or
`my configuration_object` instead.

A request handler can read basic information about the running configuration
like this:

```tcl
method handle_request {request} {
    set configuration [::tclwire::app::configuration]

    set application_id      [$configuration id]
    set application_class   [$configuration class]
    set docroot             [$configuration docroot]
    set hosts               [$configuration hosts]
    set pool_policy         [$configuration pool_policy]

    set options [$configuration class_configuration [info object class [self]]]

    ::tclwire::io response 200 OK \
        [list "Content-Type: text/plain; charset=utf-8"] text utf-8
    ::tclwire::io out [join [list   "application: $application_id" \
                                    "class: $application_class" \
                                    "docroot: $docroot" \
                                    "hosts: [join $hosts {, }]" \
                                    "maximum workers: [dict get $pool_policy maximum_workers]" \
                                    "class options: $options"] \n]
}
```

Application descriptors may include a `configure` dictionary. Direct values in
the TOML `configure` table apply to the resolved application class. Child
tables keyed by TclOO class name target that class explicitly. This is
class-owned instance configuration, not automatic variable injection. Each
class decides how to map its block to object state.

Bare application class names are deployment adapter classes. The runtime
qualifies them under `::tclwire::app`, and file-backed applications are
sourced in that namespace. Bare class names in `configure` child tables are
qualified the same way:

```toml
[http.hello]
hosts = "hello.example.test"
class = "Hello"
file = "examples/hello.tcl"

[http.hello.configure]
message = "Hello from a configured virtual host"
```

The corresponding application code can read its block through the immutable
configuration object:

```tcl
set options [[my configuration_object] class_configuration [info object class [self]]]
```

Fully qualified class names remain explicit and are not rewritten. Use them
for package-defined or project-owned application classes outside
`::tclwire::app`.

The application package or file is loaded when each worker interpreter is
initialized. For each request, the CGA invokes:

```tcl
set application [$application_class new $application_descriptor]
set request [::tclwire::HttpRequest new $request_descriptor]
$application rewrite_request $request
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

A file-backed application can opt into per-request worker replacement:

```toml
[http.my_application]
class = "::example::Application"
file = "application.tcl"
reload_on_request = true
```

After completing a request, the worker removes itself from its application pool
and exits. The next request starts a replacement worker, which sources the
application file during worker initialization. This allows file-backed
applications to be edited without restarting TclWire.

This option is intended only for development: it replaces the application
worker after every request and discards worker-local state. It is rejected for
package-backed applications because replacement workers would still use
`package require` package caching.

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

## Proposed Request Preparation and Response Planning

> **Design status:** this section specifies a proposed generic hook and response
> builder. The commands and methods shown here are not part of the implemented
> worker API yet. Existing applications must continue to use `handle_request`,
> `::tclwire::io`, and `::tclwire::http::io` as documented below.

Some response decisions are useful before the normal request handler runs. A
server may be able to answer `HEAD` from metadata, reject an unauthorized
request, return a cached representation, turn a conditional request into
`304 Not Modified`, or attach a cache policy to a static asset. These are all
instances of the same operation: prepare a request and either pass it to the
normal generator or provide a response immediately.

The default `CApplication` already performs one specialized version of this
optimization for filesystem resources: `HEAD` obtains the MIME type and file
size without reading the file. The proposal generalizes the decision point so
non-filesystem resources and environment-selected application classes can make
equivalent decisions without adding special cases to CGA.

The contract must not refer to scripts, templates, or commands belonging to a
particular application environment. TclWire calls generic application methods.
An environment adapter may implement those methods by invoking its own
machinery, but that delegation remains inside the adapter-selected application
class.

### General Flow

The proposed request path is:

```text
rewrite_request
    |
prepare_request
    |
    +-- pass  -> install response policy -> handle_request
    |
    +-- reply -> validate response descriptor -> skip handle_request
                                                     |
                                              prepare_response
                                                     |
                                               commit headers
                                                     |
                                             deliver or omit body
                                                     |
                                                  complete
```

`prepare_response` runs once at the response commitment boundary. For a
buffered response that boundary may be after `handle_request` returns. For a
streaming response it is reached by the first write or flush, so it necessarily
runs while generation is still in progress. There can be no general mutable
"after generation" phase: once streaming headers or body bytes have reached the
client, changing the response would corrupt the HTTP message.

A later `response_finished` notification may report the final status and byte
count, but it must be observational. Because CGA output is asynchronous, such a
notification requires an acknowledgement from the connection thread and must
not be required for ordinary response completion.

### Hook Methods

The application-facing lifecycle consists of two mutable hooks:

```tcl
method prepare_request {request} {
    return [::tclwire::http::request_action pass]
}

method prepare_response {request response} {
    return $response
}
```

`prepare_request` returns a pass or reply action. `prepare_response` receives
the selected response descriptor after request preparation or normal response
generation has established its metadata, but before commitment. It returns the
same descriptor or a validated replacement. It must not write response body
data or complete the transaction itself.

For example, an application can make successful dynamic responses non-cacheable
unless a handler or preparation policy chose a cache policy explicitly:

```tcl
method prepare_response {request response} {
    set status [dict get $response status]
    if {$status >= 200 && $status < 300 &&
            ![::tclwire::http::response header exists \
                $response Cache-Control]} {
        ::tclwire::http::response header set response \
            Cache-Control "no-store"
    }
    return $response
}
```

An optional future observational callback has a different contract:

```tcl
method response_finished {request summary} {
    # Observe status, committed headers, and transmitted byte counts only.
    return
}
```

It cannot replace the response or mutate headers. The `summary` dictionary
would be produced by the connection thread after output succeeds or fails, not
merely when `handle_request` returns.

### Terms

| Term | Meaning |
| --- | --- |
| **pass** | The preparation hook declines to answer the request. TclWire calls the normal `handle_request`. This is an action name, not Tcl's `continue` command. |
| **reply** | The preparation hook supplies a response descriptor. TclWire skips `handle_request` and emits that response. |
| **response descriptor** | A structured dictionary describing one immediate response: status, headers, representation properties, delivery intent, and optionally a body. |
| **response policy** | Defaults or enforced choices that are retained while the normal handler generates its response. A policy is not itself a response. |
| **response metadata** | Status, reason, headers, text or binary body mode, character encoding, delivery intent, and a known representation length. It excludes the body payload. |
| **representation** | The bytes that the corresponding successful `GET` would deliver after text encoding. A `HEAD` response describes this representation even though it does not carry it. |
| **delivery** | Application intent: let TclWire decide, buffer the response, or stream it. This is intentionally higher-level than HTTP wire framing. |
| **framing** | The protocol mechanism delimiting a body, such as `Content-Length` or chunked transfer coding. The connection thread derives and validates framing. |
| **commitment** | The point at which response headers become immutable because TclWire is about to send, or has sent, the response head. |
| **completion** | The terminal response state. No further metadata or body output is accepted. Buffered output is serialized; a chunked stream receives its terminator. |

The action names `pass` and `reply` are preferable to `continue` and `respond`:
they do not resemble Tcl flow control, and they distinguish a hook decision
from the existing `response` output event.

### Action and Response Descriptors

The default hook returns a `pass` action:

```tcl
method prepare_request {request} {
    return [::tclwire::http::request_action pass]
}
```

Conceptually, the helper returns this dictionary:

```tcl
dict create action pass
```

A pass action may carry a response policy:

```tcl
dict create action pass policy $policy
```

An immediate reply carries a response descriptor:

```tcl
dict create action reply response $response
```

The proposed response fields are:

| Field | Required | Meaning |
| --- | --- | --- |
| `status` | yes | Integer HTTP status. |
| `reason` | no | Reason phrase. TclWire supplies its standard phrase when omitted. |
| `headers` | no | Ordered list of `{name value}` pairs. Repeated names are preserved. |
| `body` | no | Complete immediate response body. Absence differs from an explicitly empty representation only when representation metadata is supplied separately. |
| `body_mode` | no | `text` or `binary`; defaults to `text`. |
| `encoding` | no | Encoding used to convert a text body to bytes; defaults to the application encoding. |
| `delivery` | no | `automatic`, `buffered`, or `streaming`; defaults to `automatic`. |
| `representation_length` | no | Exact byte length of the corresponding representation. It is useful for metadata-only `HEAD` replies and must never be an estimate. |

Headers use pairs instead of preformatted lines so validation does not require
parsing application-created strings and repeated fields remain representable:

```tcl
set headers {
    {Content-Type {text/html; charset=utf-8}}
    {Set-Cookie {session=abc; Path=/; HttpOnly}}
    {Set-Cookie {layout=compact; Path=/}}
}
```

### Response Builder Helpers

The helpers operate on a dictionary variable, like `dict set`, so applications
do not need to manage a request-scoped TclOO response object:

```tcl
set response [::tclwire::http::response create 200 \
    ?-reason reason? \
    ?-body value? \
    ?-body-mode text|binary? \
    ?-encoding encoding? \
    ?-delivery automatic|buffered|streaming?]

::tclwire::http::response header set response name value
::tclwire::http::response header add response name value
::tclwire::http::response header remove response name
::tclwire::http::response header get response name
::tclwire::http::response header exists response name
::tclwire::http::response body set response value ?text|binary?
::tclwire::http::response encoding response encoding
::tclwire::http::response delivery response mode
::tclwire::http::response representation_length response byte_count

::tclwire::http::request_action pass ?-policy policy?
::tclwire::http::request_action reply response
```

`header set` replaces all existing values with one value. `header add` appends
another field and is required for headers such as `Set-Cookie`. Every helper
validates its input immediately; the connection thread validates the compiled
response again before commitment.

For policies, header precedence must be explicit:

```tcl
set policy [::tclwire::http::response_policy create]
::tclwire::http::response_policy header default policy name value
::tclwire::http::response_policy header set policy name value
::tclwire::http::response_policy header add policy name value
::tclwire::http::response_policy delivery policy mode
```

`default` supplies a header only when the handler did not set it. `set`
replaces handler values and expresses an application-wide rule. `add` retains
handler values and appends another field. This distinction prevents a later
`::tclwire::io response` call from accidentally erasing policy installed by
`prepare_request`.

### Example: Metadata-Only HEAD Reply

An expensive dynamic page may have cheap metadata but no cached body. The hook
can return its media type and caching policy without running the generator:

```tcl
method prepare_request {request} {
    if {[$request method] ne "HEAD" ||
            [$request path] ne "/reports/current"} {
        return [::tclwire::http::request_action pass]
    }

    set response [::tclwire::http::response create 200]
    ::tclwire::http::response header set response \
        Content-Type "text/html; charset=utf-8"
    ::tclwire::http::response header set response \
        Cache-Control "private, max-age=60"

    return [::tclwire::http::request_action reply $response]
}
```

The response intentionally has no `Content-Length`. HTTP permits that omission.
Supplying an estimated or character-count length would be incorrect because a
`HEAD` `Content-Length`, when present, must equal the byte length of the
representation that the equivalent `GET` would send.

When an exact encoded length is available from a representation cache, the same
hook can include it without loading the body:

```tcl
set metadata [my report_cache metadata current]

set response [::tclwire::http::response create 200]
::tclwire::http::response header set response \
    Content-Type [dict get $metadata content_type]
::tclwire::http::response representation_length response \
    [dict get $metadata byte_length]

return [::tclwire::http::request_action reply $response]
```

TclWire compiles `representation_length` into `Content-Length` for `HEAD`; it
still suppresses body output defensively in the connection thread.

### Example: Cache Policy Without Taking Over Generation

Fingerprint-named CSS and JavaScript assets still need ordinary static handling,
but can receive a long-lived browser cache policy:

```tcl
method prepare_request {request} {
    set path [$request path]
    if {![regexp {\.[0-9a-f]{12}\.(css|js)$} $path]} {
        return [::tclwire::http::request_action pass]
    }

    set policy [::tclwire::http::response_policy create]
    ::tclwire::http::response_policy header set policy \
        Cache-Control "public, max-age=31536000, immutable"

    return [::tclwire::http::request_action pass -policy $policy]
}
```

The normal `handle_request` still resolves the resource, chooses its MIME type,
handles ranges, and generates either its `GET` body or optimized `HEAD`
metadata. The policy changes only the response header set.

### Example: Conditional Cached Representation

A cache can answer both validation requests and ordinary requests through the
same preparation method. The example assumes a standards-aware validator
helper; comparison of `If-None-Match` as one unparsed string would not correctly
handle lists, weak tags, or `*`.

```tcl
method prepare_request {request} {
    set key [my cache_key $request]
    if {![my response_cache exists $key]} {
        return [::tclwire::http::request_action pass]
    }

    set metadata [my response_cache metadata $key]
    set etag [dict get $metadata etag]

    if {[::tclwire::http::conditional not_modified $request \
            -etag $etag \
            -last-modified [dict get $metadata modified]]} {
        set response [::tclwire::http::response create 304]
        ::tclwire::http::response header set response ETag $etag
        ::tclwire::http::response header set response \
            Cache-Control "public, max-age=300"
        return [::tclwire::http::request_action reply $response]
    }

    set response [::tclwire::http::response create 200 \
        -body [my response_cache body $key] \
        -body-mode binary \
        -delivery buffered]
    ::tclwire::http::response header set response \
        Content-Type [dict get $metadata content_type]
    ::tclwire::http::response header set response ETag $etag
    ::tclwire::http::response header set response \
        Cache-Control "public, max-age=300"

    return [::tclwire::http::request_action reply $response]
}
```

For `HEAD`, TclWire uses the cached binary body length as representation
metadata but omits the body from the wire. For `304`, HTTP status semantics
forbid a message body regardless of the request method.

### Example: Declaring Streaming Intent

An endpoint may require progressive delivery while leaving protocol framing to
TclWire:

```tcl
method prepare_request {request} {
    if {[$request path] ne "/events"} {
        return [::tclwire::http::request_action pass]
    }

    set policy [::tclwire::http::response_policy create]
    ::tclwire::http::response_policy header default policy \
        Content-Type "text/event-stream; charset=utf-8"
    ::tclwire::http::response_policy header set policy \
        Cache-Control "no-cache"
    ::tclwire::http::response_policy delivery policy streaming

    return [::tclwire::http::request_action pass -policy $policy]
}

method handle_request {request} {
    foreach event [my pending_events] {
        ::tclwire::io out "data: $event\n\n"
        ::tclwire::io flush
    }
}
```

`streaming` is not a synonym for adding `Transfer-Encoding: chunked`. The
connection thread considers the HTTP version, method, and response status. For
an eligible HTTP/1.1 `GET`, it may choose chunked framing. For `HEAD`, it emits
the metadata that the equivalent streaming `GET` would have used but emits no
chunks. Unsupported combinations are rejected or fall back only according to
an explicitly documented server policy.

### Example: Environment Delegation

An environment-selected application class may delegate the generic hook to its
own adapter. TclWire still knows only `prepare_request` and the generic action
dictionary:

```tcl
oo::class create ::example::EnvironmentApplication {
    superclass ::tclwire::CApplication

    method prepare_request {request} {
        set action [next $request]
        if {[dict get $action action] ne "pass"} {
            return $action
        }
        return [::example::environment::prepare_request $request $action]
    }

    method handle_request {request} {
        tailcall ::example::environment::generate [self] $request
    }
}
```

The environment object selects this class through its existing
`application_class` contract. No environment name, callback, script phase, or
template concept is added to CGA.

### Compiling Actions Into Output Events

This proposal extends the worker-side preparation model; it does not require a
second inter-thread protocol. A reply descriptor compiles into the existing
ordered event sequence:

```text
response   status, reason, headers, body mode, encoding, delivery
output     optional body data
complete   terminal event
```

A pass policy is stored in the request-local output context. When the handler
declares or implicitly starts its response, the output bridge merges the
policy, invokes `prepare_response`, validates the final metadata, and sends the
same events. The connection thread remains authoritative for HTTP framing,
`HEAD` body suppression, status-specific body rules, commitment, and socket
I/O.

The following invariants belong to the generic implementation:

- a supplied `representation_length` is a nonnegative exact byte count;
- a complete supplied body must encode to that length when both are present;
- `Content-Length` and streaming delivery cannot be combined;
- statuses that forbid bodies reject supplied body data and emit no body;
- a `HEAD` reply never sends body bytes;
- header mutation is rejected after commitment;
- `complete` is idempotent and prevents later output;
- environment adapters receive and return only the generic action, policy, and
  response structures.

## Request Object

The CGA wraps the transported dictionary in `::tclwire::HttpRequest`.
Applications do not receive or mutate the Connection Agent's authoritative
transaction state. Request metadata is read-only except for application-local
path mapping and the rewrite methods, which update the worker's copy before
application routing.

The request object exposes:

| Method | Result |
| --- | --- |
| `method` | HTTP method. |
| `target` | Current request target. Initially the wire target; changed by a rewrite method. |
| `original_target` | Original wire target, retained after a rewrite. |
| `rewrite target ?query_dict?` | Replace the origin-form target. An optional query dictionary is URL-encoded safely. |
| `rewrite_query target normalized_query` | Replace the origin-form target using a pre-encoded normalized query string. |
| `path` | Current application-routing path. It is initially the target path before the first `?`. |
| `query` | Raw query text without the leading `?`. |
| `query_dict` | Decoded query parameter dictionary. |
| `query_parameters` | Alias for `query_dict`. |
| `query_parameter name ?default?` | One decoded query value or the supplied default. |
| `version` | HTTP version, such as `1.1`. |
| `headers` | Dictionary keyed by lowercase header names. |
| `header name ?default?` | Case-insensitive header lookup. |
| `cookie_jar` | Request-associated `::tclwire::CookieJar` object initialized from the `Cookie` header. |
| `content_type ?default?` | Raw `Content-Type` header value. |
| `content_type_info` | Parsed media type and parameters dictionary. |
| `media_type ?default?` | Lowercase media type from `Content-Type`. |
| `content_type_parameter name ?default?` | One lowercase-keyed `Content-Type` parameter. |
| `is_multipart` | True if the request media type is `multipart/*`. |
| `body_media` | Request body interpretation: `raw` or `multipart`. |
| `body_storage` | Request body storage: `in_memory`, `spooled_file`, or `decomposed`. |
| `body_path` | Path of a request body whose mode is `spooled_file`. |
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

Apart from application-local path mapping and rewriting, there are no request
mutation methods and no channel accessor.

### Request Rewriting

Rewriting is application-local: it runs after the `Host` header selected an
application, so it cannot select another virtual host or application pool. It
must use an origin-form path beginning with `/`; full URLs are not accepted.

Use the optional dictionary argument to encode query names and values safely:

```tcl
$request rewrite /index.rvt [dict create \
    page {home & news} \
    language it]
```

This sets the target to:

```text
/index.rvt?page=home+%26+news&language=it
```

Use `rewrite_query` only when the query text has already been normalized and
URL-encoded:

```tcl
$request rewrite_query /index.rvt {page=home+news&language=it}
```

For compatibility, a single `rewrite` argument may include the query directly:

```tcl
$request rewrite /index.rvt?page=home+news
```

The dictionary and pre-encoded forms keep their arguments separate to avoid
Tcl ambiguity: some query strings can also be valid Tcl dictionaries. Both
methods validate the complete replacement before changing the request. A
successful rewrite synchronizes `target`, `url_path`, `path`, `query`, and
`query_dict`, clears any previous `local_path`, and preserves the first
pre-rewrite target in `original_target`.

The cookie jar supports:

```tcl
set jar [$request cookie_jar]
$jar get $name ?$default?
$jar set $name $value ?-path $uri_path? ?-expires $expiration?
$jar validate $value
$jar serialize
```

`serialize` returns a list of argument lists. Each item can be expanded into
`::tclwire::http::io cookie`:

```tcl
foreach cookie [$jar serialize] {
    ::tclwire::http::io cookie {*}$cookie
}
```

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

The current request body representation is described by two fields:

```tcl
body_media    raw | multipart
body_storage  in_memory | spooled_file | decomposed
```

`$request body` returns the decoded body value. It raises an error when
`body_storage` is not `in_memory`. `body_size` reports the length of the
decoded body.

Multipart request helpers use parsed `multipart_parts` when the connection
thread has already decomposed the request. They can also parse an in-memory
multipart body for direct descriptor/test paths. Each part is a dictionary with
`headers` and either `body` or per-part file storage metadata; form-data parts
also expose `name`, and file parts expose `filename`. Parts with their own
`Content-Type` include `content_type`.

Large raw request bodies may be represented by `body_storage spooled_file` and
accessed through `$request body_path`. The current API is still a
complete-request API: request bodies are parsed incrementally in the connection
thread, but `handle_request` starts only after the request is complete. See
[`LARGE_REQUEST_DATA_HANDLING.md`](LARGE_REQUEST_DATA_HANDLING.md) for the
threshold and ownership rules.

## Content-Type and Multipart Reference

The request object includes convenience methods for inspecting request media
types and for accessing `multipart/*` request bodies. These methods are
read-only and operate on either parsed `multipart_parts` or an in-memory raw
body.

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
| `body_storage` | `spooled_file`. |
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

Request framing and body storage are incremental. If the decoded whole body
crosses `request_memory_threshold`, raw non-multipart requests use
`body_storage spooled_file` with `body_path`. Multipart requests are decomposed
incrementally and expose `multipart_parts` with per-part storage metadata.

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
    if {[dict exists $file body_storage] &&
            [dict get $file body_storage] eq "spooled_file"} {
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

Multipart parsing errors can be raised while the connection thread parses an
incremental multipart request, or when an application calls a multipart method
on a direct in-memory descriptor that has not already been decomposed.

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

## Standard Channel Compatibility

Applications that enable the `stdchans` environment can use Tcl's standard
channel commands for `stdout` response output:

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

Only `stdout` is virtualized. Operations on other channels are delegated to
Tcl's native `puts`, `flush`, `fconfigure`, and `chan` implementations.

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

Changing virtual `stdout` back to text affects subsequent `puts stdout` calls:

```tcl
fconfigure stdout -translation lf -encoding utf-8
puts stdout "text again"
```

Do not mix text and binary data in one pending worker buffer. Flush between
mode changes when both forms are needed:

```tcl
fconfigure stdout -translation binary
puts -nonewline stdout $binary_prefix
flush stdout

fconfigure stdout -translation lf -encoding utf-8
puts stdout "text suffix"
```

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
| `flush` | Request output progress. |
| `no_body` | Discard response representation data. |
| `complete` | Finish and send the response. |
| `close_connection` | Close the connection without sending an accumulated response. |
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
