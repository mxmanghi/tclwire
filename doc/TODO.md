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
- [x] Implement correct `HEAD` handling: generate the same headers as `GET`,
      including the appropriate content length, but omit the response body.
- [x] Implement single-range and multipart byte-range responses, including
      `206 Partial Content` and the appropriate range headers.

## HTTP Application Support

- [x] Provide reusable URL query decoding into a dictionary.
- [x] Provide reusable redirect-response construction.
- [x] Provide a semantic operation for discarding an unsent response body.
- [x] Provide reusable request-header access.
- [x] Provide reusable request `Content-Type` parsing helpers.
- [x] Provide in-memory MIME multipart request parsing with form-field and
      uploaded-file accessors.
- [x] Provide reusable byte-range parsing.
- [x] Provide reusable response-cookie construction with URI path and
      expiration support.
- [ ] Define application result semantics for delayed responses and deliberate
      connection closure without a response.

These facilities should be HTTP application support components rather than
methods placed directly in the default `::tclwire::CApplication`.

## Application Output Bridge

- [x] Make `::tclwire::io::flush` forward buffered output to the Connection
      Agent and ultimately to the socket channel.
- [x] Stream application output for chunked HTTP responses instead of
      accumulating it in `::tclwire::HttpConnectionAgent`.
- [ ] Define a general streaming output mode for non-chunked responses,
      including buffering and backpressure semantics.
- [x] Add namespaced stdout compatibility commands for applications that use
      Tcl-style `puts` and `flush`.
- [ ] Implement an optionally loaded standard-channel redirection module for
      application workers.
- [ ] Decide how standard-channel redirection is enabled: application-level
      opt-in package loading, or a TclWire worker configuration flag such as
      `stdchans_redirect`.
- [x] Add a dedicated logger-agent error log sink, configured by `--logerr`,
      for future stderr redirection.
- [ ] Redirect application `stderr` output to the logger-agent error log.
- [x] Track response commitment state so the Connection Agent knows whether
      HTTP response headers have been sent.
- [x] Reject attempts to modify HTTP headers after response commitment.
- [x] Add convenient HTTP response-header add, replace, remove, and inspect
      operations for Content Generator Agents.

## Service Registration

- [x] Replace the hardcoded protocol switch in the runtime with a service
      descriptor registry.
- [x] Let each protocol descriptor identify:
  - protocol name;
  - default port;
  - secure transport requirement;
  - Connection Agent class and package;
  - Transport Reactor agent arguments.
- [ ] Move pool descriptor and worker policy selection into service
      descriptors where applicable.
- [x] Support multiple protocols sharing the same Connection Agent class, such
      as HTTP/HTTPS and FTP/FTPS.

This should use the current Transport Reactor and Connection Agent terminology,
not restore the legacy service-class hierarchy.

## Accounting and Inspection

- [x] Add a shared per-connection database recording:
  - connection identifier;
  - protocol and service endpoint;
  - peer address and port;
  - owning Connection Agent thread;
  - creation and closure timestamps;
  - current status;
  - closure or transport error.
- [x] Add a Unix-domain console socket for runtime inspection and control.
- [x] Reimplement basic thread-accounting inspection through the console `PS`
      command.
- [x] Add connection-accounting inspection through the console `CONN` command,
      including current console connections and simple port/remote filters.
- [x] Add console-triggered logger reopening through `LOGROTATE` for external
      log rotation tools.
- [ ] Have the TPBA periodically evaluate pool workers and invoke stale-thread
      release according to each pool's resource policy.

## Runtime Behavior

- [x] Prepare and seed the HTTP document root when HTTP or HTTPS is enabled,
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
- split access-log and error-log logger outputs;
- shared thread and connection accounting;
- Unix-domain console inspection and shutdown channel.
