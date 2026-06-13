# TclWire Reimplementation TODO

This document records functionality present in `legacy/` that has not yet been
reimplemented in the threaded application server under `tcl/`.

It distinguishes migration work from new architectural features that were not
meaningfully implemented by the legacy server.

## HTTP Protocol

- [x] Decode request bodies using `Transfer-Encoding: chunked`.
- [x] Decode the `gzip, chunked` request transfer-coding chain.
- [x] Generate chunked HTTP responses.
- [x] Support incremental and delayed response output without buffering the
      complete result in the Connection Agent.
- [ ] Implement correct `HEAD` handling: generate the same headers as `GET`,
      including the appropriate content length, but omit the response body.
- [ ] Implement single-range and multipart byte-range responses, including
      `206 Partial Content` and the appropriate range headers.

## HTTP Application Support

- [ ] Provide reusable URL query decoding into a dictionary.
- [ ] Provide reusable redirect-response construction.
- [ ] Provide reusable request-header access.
- [ ] Provide reusable byte-range parsing.
- [x] Provide reusable response-cookie construction with URI path and
      expiration support.
- [ ] Define application result semantics for delayed responses and deliberate
      connection closure without a response.

These facilities should be HTTP application support components rather than
methods placed directly in the default `::tclwire::CApplication`.

## Application Output Bridge

- [x] Make `::tclwire::io::flush` forward buffered output to the Connection
      Agent and ultimately to the socket channel.
- [ ] Allow application output to be streamed instead of always accumulated in
      `::tclwire::HttpConnectionAgent`.
- [ ] Add a stdout compatibility layer for applications that use Tcl `puts`
      and `flush`.
- [ ] Add stderr redirection to the logging facility.
- [ ] Track whether HTTP response headers have been sent.
- [ ] Reject attempts to modify HTTP headers after transmission has begun.
- [ ] Add convenient HTTP response-header add, replace, and remove operations
      for Content Generator Agents.

## Service Registration

- [ ] Replace the hardcoded protocol switch in the runtime with a service
      descriptor registry.
- [ ] Let each descriptor identify:
  - protocol name;
  - default port;
  - secure transport requirement;
  - Connection Agent class and package;
  - Transport Reactor arguments;
  - pool descriptor and worker policy, where applicable.
- [ ] Support multiple protocols sharing the same Connection Agent class, such
      as HTTP/HTTPS and FTP/FTPS.

This should use the current Transport Reactor and Connection Agent terminology,
not restore the legacy service-class hierarchy.

## Accounting and Inspection

- [ ] Add a shared per-connection database recording:
  - connection identifier;
  - protocol and service endpoint;
  - peer address and port;
  - owning Connection Agent thread;
  - creation and closure timestamps;
  - current status;
  - closure or transport error.
- [ ] Reimplement a thread-accounting inspection/report utility.
- [ ] Add connection-accounting inspection.
- [ ] Have the TPBA periodically evaluate pool workers and invoke stale-thread
      release according to each pool's resource policy.

## Runtime Behavior

- [ ] Prepare and seed the HTTP document root when HTTP or HTTPS is enabled,
      independently of whether FTP is enabled.
- [ ] Make `--quiet` control applicable startup and runtime messages.
- [ ] Use the configured `--debug` facility throughout the current runtime
      components.

## Legacy Test Fixtures

Evaluate and selectively port the legacy TclCurl test application routes for:

- [ ] redirects and redirect chains;
- [ ] cookies;
- [ ] HTTP Basic authentication;
- [ ] request inspection and binary request bodies;
- [ ] compressed responses;
- [ ] chunked responses;
- [ ] slow or delayed responses;
- [ ] byte-range responses;
- [ ] controlled shutdown.

These routes are conformance and integration-test fixtures. They should not be
treated automatically as production application-server requirements.

## New Architecture Work

The following capabilities are not legacy migration omissions. They require
new design and implementation:

- [ ] HTTP/1.1 persistent connections.
- [ ] Multiple sequential requests over one persistent connection.
- [ ] HTTP/1.1 pipelining, if retained as a project requirement.
- [ ] HTTP/2 multiplexing.
- [ ] Explicit backpressure and bounded output buffering between Content
      Generator Agents and Connection Agents.
- [ ] Cancellation propagation when a client disconnects during content
      generation.

## Already Reimplemented

The following areas have substantially been migrated and should be maintained
in the current architecture rather than copied again from `legacy/`:

- FTP and FTPS command processing, passive transfers, and transfer logging;
- HTTP proxy forwarding, proxy authentication, and `CONNECT` tunnelling;
- TLS listener support with service-specific credentials;
- TPBA-managed Connection Agent and application worker pools;
- Host-based application dispatch;
- binary-safe static-file serving;
- centralized logger agent and client interface;
- shared thread accounting.
