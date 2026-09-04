# Request API

This chapter will document the application-facing HTTP request object.

## Scope

- Request metadata.
- Header lookup.
- Query parameter decoding.
- Body access.
- Multipart forms and file uploads.
- Body storage modes.
- Cleanup and retained upload behavior.

## Client and Peer Addresses

`remote_host` and `remote_port` identify the TCP peer. They are never replaced
by request-header values. `client_host` identifies the effective client after
the listener's `trusted_proxies` policy has processed `X-Forwarded-For`; when
there is no valid trusted chain it equals `remote_host`.

`forwarded_for` returns the validated, left-to-right list advertised by the
header. It is informational and may have come from an untrusted peer, so use
`client_host` for application decisions:

```tcl
set peer_address [$request remote_host]
set client_address [$request client_host]
set advertised_chain [$request forwarded_for]
```

## Source Material

- `runtime-doc/WORKER_REQUEST_API.md`
- `runtime-doc/REQUEST_BODY_HANDLING.md`
- `runtime-doc/LARGE_REQUEST_DATA_HANDLING.md`
- `tcl/http_request.tcl`
