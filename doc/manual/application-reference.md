# Application Command and Helper Reference

This page is the reference for the Tcl commands and objects made available to
an HTTP application while it handles a request. It describes application
contracts, not connection-thread or socket APIs. A handler receives an
`::tclwire::HttpRequest` object and writes its response through
`::tclwire::io`; it never reads or writes the client channel directly.

## Overview of request preparation and handling

For each complete HTTP request, TclWire parses and normalizes the request,
selects an application, and sends a copy of its descriptor to a worker. The
worker creates the `HttpRequest` supplied to:

```tcl
method handle_request {request} {
    # inspect $request and produce output here
}
```

Before `handle_request`, the application framework runs `prepare_request` and
the configured rewrite hook when applicable. Rewrites affect the request that
the handler sees. After the handler returns, TclWire completes the buffered
response, destroys request-scoped objects, removes temporary request files
unless configured to retain uploads, and returns the worker to its pool.

The connection worker owns HTTP parsing, response framing, and the socket.
Applications should use only the output commands below; do not retain the
request object or a spooled body path after the handler has returned.

## `HttpRequest`

`request` is an `::tclwire::HttpRequest` instance. Its public methods are
grouped below. Header, query-parameter, and trailer names are matched without
regard to case where that is meaningful.

### Request line, routing, and URLs

| Method | Result |
| --- | --- |
| `method` | HTTP method, for example `GET` or `POST`. |
| `target` | Current origin-form target, including its encoded query string. |
| `original_target` | Target before the first successful `rewrite`; otherwise `target`. |
| `version` | HTTP version supplied by the client. |
| `url_path` | URL-derived path. It changes with `rewrite`, but not when application routing changes `path`. |
| `path ?path?` | With no argument, the application working path. With an absolute path, replaces that routing path. |
| `local_path ?path?` | Gets or sets filesystem-mapping metadata. Passing an empty string clears it; a nonempty value is normalized. This does not authorize filesystem access. |
| `rewrite target ?queryDict?` | Atomically replaces target, URL path, working path, and query data. `target` must be an absolute, valid origin-form path. When `queryDict` is provided it is safely query-encoded. |
| `rewrite_query target query` | Rewrite using an already-normalized encoded query string. `target` must not contain `?`. |
| `scheme` | `http` or `https` for the accepted connection. |
| `authority` | Trimmed `Host` header, or an error when it is absent. |
| `origin` | `scheme://authority`. |
| `absolute_url ?path?` | Absolute URL for the current target, an absolute path, or a reference resolved against the current working-path directory. |

For example, route a legacy URL while preserving its original form for
diagnostics:

```tcl
if {[$request url_path] eq "/old-products"} {
    $request rewrite /products [dict create source legacy]
}
set canonical [$request absolute_url]
```

### Query, headers, cookies, and content type

| Method | Result |
| --- | --- |
| `query` | Raw, encoded query text, without the leading `?`. |
| `query_parameters` / `query_dict` | Decoded query dictionary. Repeated keys use the final value. |
| `query_parameter name ?default?` | One decoded query value, or `default` (empty by default). |
| `headers` | Normalized request-header dictionary. |
| `header name ?default?` | One header value. |
| `cookie_jar` | Lazy, request-owned cookie jar. Changes to it do not change request headers. |
| `content_type ?default?` | `Content-Type` header. |
| `content_type_info` | Dictionary with normalized `media_type` and `parameters`; errors if the header is absent or malformed. |
| `media_type ?default?` | Normalized media type from `Content-Type`. |
| `content_type_parameter name ?default?` | One normalized Content-Type parameter. |
| `is_multipart` | True when the media type begins with `multipart/`. |
| `trailers` | HTTP trailer dictionary, if a chunked request supplied trailers. |
| `trailer name ?default?` | One trailer value. |

```tcl
set page [$request query_parameter page 1]
if {[$request media_type] eq "application/json"} {
    set charset [$request content_type_parameter charset utf-8]
}
```

### Body, forms, and uploads

| Method | Result |
| --- | --- |
| `body_storage` | `none`, `in_memory`, or `spooled_file`. It determines which body accessor is valid. |
| `body_media` | Body representation metadata; defaults to `raw`. |
| `body` | In-memory body bytes. Errors unless `body_storage` is `in_memory`. |
| `body_path` | Temporary file containing a spooled body. Errors unless `body_storage` is `spooled_file`. |
| `body_size` | Body size in bytes. |
| `multipart_parts` | Multipart part dictionaries. It parses an in-memory multipart body on first use when needed. |
| `form_fields` | Field-name dictionary for multipart form data. |
| `form_values name` | All values for a multipart field. |
| `form_value name ?default?` | Final value for a multipart field, or `default`. |
| `uploaded_files ?name?` | Uploaded-file part dictionaries, optionally only those for `name`. |
| `uploaded_file name` | First uploaded file for `name`, or empty. |

An uploaded-file part normally includes `name`, `filename`, `headers`, and
either `body` or a `body_path`/`path` for a spooled file. Treat the filename as
untrusted client input. The temporary paths are valid only during handling.

```tcl
set upload [$request uploaded_file avatar]
if {$upload ne {}} {
    set bytes [expr {[dict exists $upload body] ?
        [dict get $upload body] : [read [open [dict get $upload body_path] rb]]}]
}
```

For production code, close any channel you open (prefer `try/finally`); do not
copy a client filename into a destination path without validating it.

### Connection and application metadata

| Method | Result |
| --- | --- |
| `connection_id` / `transaction_id` | Runtime identifiers useful for correlation and logging. |
| `remote_host` / `remote_port` | Actual TCP peer address and port. |
| `forwarded_for` | Validated, left-to-right `X-Forwarded-For` address list; informational only. |
| `client_host` | Effective client after `trusted_proxies` policy; otherwise the TCP peer. Use this for application decisions. |
| `application_id` | Selected application identifier. |
| `snapshot` | Copy of the backing request-descriptor dictionary for diagnostics or interoperability. |

## `::tclwire::io` response output

These commands are available only while an application request is active. The
runtime calls `begin` and `end`; handlers normally use `response`, `out`,
`puts`, `flush`, and `complete`.

| Command | Description |
| --- | --- |
| `::tclwire::io response status reason headers ?body_mode? ?encoding?` | Sets response metadata. `headers` is a list such as `{Content-Type: text/plain}`. Metadata becomes immutable once response preparation begins. |
| `::tclwire::io out data ?body_mode?` | Appends body data. `body_mode` is normally `text` or `binary`; buffered data cannot mix modes. |
| `::tclwire::io puts ?-nonewline? ?stdout? string` | Appends text, with a newline unless `-nonewline` is specified. |
| `::tclwire::io buffer` | Returns buffered output. |
| `::tclwire::io discard_buffer` | Discards buffered output. |
| `::tclwire::io flush ?flags?` | Sends buffered output now. A flush can make streaming response metadata irreversible. |
| `::tclwire::io complete` | Prepares metadata, sends remaining output, and completes the response. Normally TclWire performs this at successful handler completion. |
| `::tclwire::io close_connection` | Ends the response and closes the client connection without sending buffered output. |
| `::tclwire::io fail message` | Reports an application-output failure to the connection side. |
| `::tclwire::io context` | Returns diagnostic transaction context. |
| `::tclwire::io response_descriptor` / `response_is_prepared` | Inspect current response metadata and whether it is immutable. |
| `::tclwire::io configure_response_planner commandPrefix` | Runtime/application-framework hook used to install `prepare_response`; not a normal handler command. |
| `::tclwire::io begin threadId agentId transactionId` / `end` | Runtime lifecycle commands. Do not call these from a handler. |

```tcl
::tclwire::io response 200 OK \
    [list "Content-Type: text/plain; charset=utf-8"] text utf-8
::tclwire::io puts "Hello, [$request client_host]"
```

## `::tclwire::http` helpers

The namespaces below are package APIs. Require the corresponding package in
standalone code; application workers normally load the packages used by the
framework.

### Response helpers

| Command | Description |
| --- | --- |
| `::tclwire::http::no_body` | Discards buffered data and declares an empty response body; useful for a `204` or a deliberate bodyless response. |
| `::tclwire::http::io cookie name value ?-path path? ?-expires time?` | Adds a validated `Set-Cookie` header. `-expires` accepts epoch seconds or a value accepted by `clock scan`. |
| `::tclwire::http::io header set name value` | Replaces all response fields named `name`. |
| `::tclwire::http::io header add name value` | Adds another response header (appropriate for repeated fields such as `Set-Cookie`). |
| `::tclwire::http::io header remove name` | Removes response fields named `name`. |
| `::tclwire::http::io header get name` | Returns all current values for `name`. |
| `::tclwire::http::redirect response location ?options?` | Builds a redirect descriptor. Options: `-status` (301, 302, 303, 307, or 308), `-body`, and `-headers`. |
| `::tclwire::http::redirect send location ?options?` | Sends that redirect metadata and optional body through `::tclwire::io`. |
| `::tclwire::http::codes reason status` / `all` | Gets a conventional reason phrase or the complete status-to-reason dictionary. |
| `::tclwire::http::errors load ?path?`, `messages`, `message status`, `response status ?context?` | Loads and uses the error catalog. `response` returns a response descriptor with HTML-escaped `{{name}}` substitutions from `context`. |

### HTTP syntax and multipart helpers

| Command | Description |
| --- | --- |
| `::tclwire::http::message split_parameters value` | Splits semicolon parameters while respecting quoted strings. |
| `::tclwire::http::message unquote_parameter value` | Trims and unquotes an HTTP quoted-string. |
| `::tclwire::http::message parse_content_type value` | Returns `media_type` and normalized parameter dictionary. |
| `::tclwire::http::message header_value headers name ?default?` | Case-insensitive lookup in a normalized header dictionary. |
| `::tclwire::http::multipart parse contentType body` | Parses a complete multipart body into part dictionaries. |
| `::tclwire::http::multipart form_fields parts`, `field_values parts name` | Projects multipart parts to form fields or all values for a field. |
| `::tclwire::http::multipart files parts ?name?` | Returns filename-bearing parts. |
| `::tclwire::http::multipart store_files parts uploadArea` / `cleanup_files parts` | Spools filename-bearing parts and later removes their temporary files. These are useful to environment authors; handlers usually use request upload methods. |

## General URL and request helpers

Use the encoder that matches the URL component. In particular, never use HTML
escaping as URL escaping, and do not use query encoding for a path segment:
query spaces are `+`, whereas path spaces are `%20`.

| Command | Description |
| --- | --- |
| `::tclwire::http::query encode_component value` / `decode_component value` | Encodes or decodes one form/query component using UTF-8 and `+` for space. |
| `::tclwire::http::query encode pairs` / `decode query` | Encodes alternating name/value list or decodes a query to a dictionary. Repeated decoded names retain the last value. |
| `::tclwire::http::path encode_component value` | Percent-encodes exactly one path segment. `/` is encoded. |
| `::tclwire::http::path encode path` / `decode path` | Encodes a complete path while preserving `/`, or decodes a valid UTF-8 percent-encoded path. Invalid escapes and NUL bytes error. |
| `::tclwire::tools origin_url`, `script_url`, `directory_url` | Returns request-scoped absolute URL forms. |
| `::tclwire::tools makeurl ?path?` | Returns the current script URL, an origin-relative URL for an absolute path, or a URL relative to the current script directory. |
| `::tclwire::tools load_env ?arrayName?` | Copies process environment variables to `arrayName` (default `env`) in the caller. |

```tcl
set product [::tclwire::http::path encode_component "tea & biscuits"]
set query [::tclwire::http::query encode [list page 2 filter "new arrivals"]]
set location "/products/$product?$query"
::tclwire::http::redirect send $location -status 303
```

`::tclwire::tools` is initialized and cleared by the worker for each request.
Its exported URL commands are appropriate for compatibility-oriented
applications; new TclOO handlers can generally prefer `$request absolute_url`.
