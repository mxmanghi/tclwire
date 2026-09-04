# Trusted Reverse Proxies

TclWire can recover an application-facing client address from
`X-Forwarded-For` when an HTTP or HTTPS listener is behind an explicitly
trusted reverse proxy. The feature preserves the socket peer separately: an
HTTP header never replaces `HttpRequest remote_host`.

## Address Model

TclWire distinguishes three values:

| Value | Meaning | Authority |
| --- | --- | --- |
| `remote_host` | Address of the TCP peer connected to TclWire. | Obtained from the accepted socket. |
| `forwarded_for` | Validated, left-to-right address list advertised by `X-Forwarded-For`. | Informational; the sender may be untrusted. |
| `client_host` | Effective client after trusted-proxy resolution. | Derived from `remote_host`, the configured trust list, and `forwarded_for`. |

`remote_port` remains the TCP peer's port. `X-Forwarded-For` does not provide a
standard, trustworthy original-client port, so TclWire does not expose a
corresponding `client_port` method.

With no trusted proxy configuration, `client_host` is always `remote_host`.
This preserves the behavior and trust boundary of a directly exposed TclWire
listener.

## Listener Configuration

Configure trusted proxies independently for each HTTP or HTTPS listener:

```toml
[http]
trusted_proxies = "127.0.0.1/32 ::1/128 10.20.0.0/16"
```

The value is a Tcl list containing literal IPv4 addresses, IPv6 addresses, or
CIDR prefixes. A bare IPv4 address is an exact `/32` match, and a bare IPv6
address is an exact `/128` match. TclWire validates this list while preparing
the runtime configuration; an invalid address or prefix prevents startup.

The bundled TOML parser currently represents lists as Tcl lists in strings,
so use the quoted form shown above rather than a TOML array.

An empty or omitted `trusted_proxies` value trusts no peers. There is no
automatic trust based on loopback, private address space, hostnames, or the
presence of an `X-Forwarded-For` header. If Apache connects over loopback,
configure `127.0.0.1/32`, `::1/128`, or both according to the listener setup.

## Resolution Algorithm

The connection agent first records the socket endpoint as `remote_host` and
`remote_port`. It then parses `X-Forwarded-For` as a comma-separated list of IP
addresses and resolves the client from the nearest hop outward:

1. Set the candidate to `remote_host`.
2. Read advertised addresses from right to left.
3. If the current candidate is not in `trusted_proxies`, stop.
4. Otherwise replace the candidate with the next advertised address.
5. Return the final candidate as `client_host`.

For example:

```text
X-Forwarded-For: 203.0.113.9, 10.20.2.5
remote_host:      127.0.0.1
trusted_proxies:  127.0.0.1/32 10.20.0.0/16
```

Resolution trusts the socket peer `127.0.0.1`, moves to `10.20.2.5`, trusts
that proxy, and then stops at the untrusted address `203.0.113.9`. The request
therefore exposes:

```text
remote_host   127.0.0.1
forwarded_for {203.0.113.9 10.20.2.5}
client_host   203.0.113.9
```

Address parsing, normalization, and IPv4/IPv6 prefix comparison use Tcllib's
`ip` package.

## Spoofing Boundary

A client can supply its own `X-Forwarded-For` value. The header becomes useful
only because a trusted edge proxy appends the address of the connection it
actually accepted or replaces untrusted incoming forwarding information.

Suppose a client at `198.51.100.20` sends a forged value:

```text
X-Forwarded-For: 192.0.2.99
```

If the trusted Apache proxy appends its observed client, TclWire receives:

```text
X-Forwarded-For: 192.0.2.99, 198.51.100.20
remote_host:      127.0.0.1
```

TclWire trusts the loopback peer, moves to the rightmost advertised address,
and stops because `198.51.100.20` is not a trusted proxy. The forged value to
its left has no effect on `client_host`.

If an untrusted peer connects directly to TclWire, resolution stops at
`remote_host` without consuming any advertised address. The validated
`forwarded_for` list remains visible for diagnostics, but applications must not
use it for authorization, rate limiting, or other trust decisions. They should
use `client_host`.

The trust list must contain only actual proxy addresses or networks. If it also
contains ordinary clients, such a client can be mistaken for another trusted
hop and can extend the forwarding chain. Restrict network access to the
TclWire listener so that only the intended proxy can connect whenever
possible.

TclWire cannot recover the original client when the trusted proxy forwards a
forged header unchanged, reports the wrong address, or is compromised. Only
the proxy observed the original connection.

## Malformed Headers

Every nonempty `X-Forwarded-For` element must be an IPv4 or IPv6 address.
TclWire rejects the entire advertised list if it contains an empty element, an
invalid address, a CIDR prefix, a port, or a token such as `unknown`. In that
case:

- `forwarded_for` returns an empty list;
- `client_host` falls back to `remote_host`;
- the request itself continues normally, and the raw header remains available
  through `$request header x-forwarded-for`.

This conservative fallback prevents a partially valid header from changing
the effective client.

## Application API

Applications access the three address views through `HttpRequest`:

```tcl
set peer_address   [$request remote_host]
set peer_port      [$request remote_port]
set proxy_chain    [$request forwarded_for]
set client_address [$request client_host]
```

The methods are read-only. For compatibility with older request descriptors,
`client_host` falls back to `remote_host` and `forwarded_for` falls back to an
empty list when the newer descriptor fields are absent.

The Rivet environment maps `REMOTE_ADDR` to `client_host`. `REMOTE_PORT`
continues to represent the TCP peer port. TclWire access-log records whose
field is named `remote` continue to report the TCP peer, preserving their
existing meaning.

## Current Scope

The implementation currently supports `X-Forwarded-For`. It does not process
the standardized `Forwarded` header, a PROXY-protocol preamble, forwarding
headers for scheme or host, or client ports. Those mechanisms would require
their own parsing and trust contracts.

## Implementation and Test References

- Trust-chain and CIDR handling: [`tcl/http_forwarded.tcl`](../tcl/http_forwarded.tcl)
- Connection descriptor enrichment: [`tcl/http_connection_agent.tcl`](../tcl/http_connection_agent.tcl)
- Application-facing methods: [`tcl/http_request.tcl`](../tcl/http_request.tcl)
- Rivet `REMOTE_ADDR`: [`environments/rivet_commands.tcl`](../environments/rivet_commands.tcl)
- Trust-policy unit tests: [`tests/http_forwarded.test`](../tests/http_forwarded.test)
- Live request integration test: [`tests/http_connection.test`](../tests/http_connection.test)

Related contracts are documented in
[`WORKER_REQUEST_API.md`](WORKER_REQUEST_API.md),
[`CONFIGURATION_OPTIONS.md`](CONFIGURATION_OPTIONS.md), and
[`AGENT_DATA_STRUCTURES.md`](AGENT_DATA_STRUCTURES.md).
