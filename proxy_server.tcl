# proxy_server.tcl --
#
# Implementation of a minimal HTTP proxy server for testing TclCurl.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclcurl::testserver {}

package require base64

if {[info commands ::tclcurl::testserver::http_endpoint_service] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_endpoint.tcl]
}
if {[info commands ::tclcurl::testserver::CApplication] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_application.tcl]
}

# HTTP proxy test service. The shared HTTP endpoint superclass owns the
# listener/buffering mechanics; this class only implements proxy
# target resolution, proxy authentication and upstream forwarding.

oo::class create ::tclcurl::testserver::proxy_service {
    superclass ::tclcurl::testserver::http_endpoint_service

    variable application tunnel_peer tunnel_root tunnel_pending

    constructor args {
        set application [::tclcurl::testserver::CApplication new]
        array set tunnel_peer {}
        array set tunnel_root {}
        array set tunnel_pending {}
        next {*}$args
    }

    destructor {
        if {[info exists application] && $application ne {}} {
            catch {$application destroy}
        }
        foreach chan [array names tunnel_peer] {
            catch {close $chan}
        }
        next
    }

    method application {} {
        return $application
    }

    method description {} {
        return "HTTP proxy test server"
    }

    # Convert either an absolute proxy target or an origin-form target plus
    # Host header into the upstream host/port/path tuple the proxy should use.

    method parse_target {target headers} {
        # Example match: "http://127.0.0.1:8990/proxy-target"
        if {[regexp {^http://([^/:]+)(?::([0-9]+))?(/.*)?$} $target -> host port path]} {
            if {$port eq {}} {
                set port 80
            }
            if {$path eq {}} {
                set path /
            }
            return [dict create host $host port $port path $path]
        }

        set host_header [dict get $headers host]
        # Example matches: "127.0.0.1" and "127.0.0.1:8990"
        if {![regexp {^([^:]+)(?::([0-9]+))?$} $host_header -> host port]} {
            error "invalid Host header"
        }
        if {$port eq {}} {
            set port 80
        }
        return [dict create host $host port $port path $target]
    }

    method auth_required {path} {
        return [expr {$path eq "/proxy-auth-target"}]
    }

    # Parse the host:port target used by HTTP CONNECT requests.
    method parse_connect_target {target} {
        if {![regexp {^([^:]+):([0-9]+)$} $target -> host port]} {
            error "invalid CONNECT target"
        }
        return [dict create host $host port $port]
    }

    # Validate the Proxy-Authorization header against the fixed credentials used
    # by the proxy authentication tests.
    method validate_proxy_auth {headers} {
        set authorization {}
        if {[dict exists $headers proxy-authorization]} {
            set authorization [dict get $headers proxy-authorization]
        }
        # Example match: "Basic cHJveHl1c2VyOnByb3h5cGFzcw=="
        if {![regexp {^Basic\s+(.+)$} $authorization -> auth_blob]} {
            return missing
        }
        if {[catch {set decoded [::base64::decode $auth_blob]}]} {
            return invalid
        }
        if {$decoded ne "proxyuser:proxypass"} {
            return denied
        }
        return ok
    }

    # Emit a simple proxy-generated response directly back to the client
    # without involving an upstream origin server.
    method proxy_response {chan status reason body headers} {
        set response_headers [concat [list \
            "HTTP/1.1 $status $reason" \
            "Content-Type: text/plain" \
            "Content-Length: [string length $body]" \
            "Connection: close"] $headers]
        catch {
            puts -nonewline $chan [join $response_headers "\r\n"]
            puts -nonewline $chan "\r\n\r\n"
            puts -nonewline $chan $body
            flush $chan
        }
        my close_client $chan
    }

    # Convert lower-cased header names from parse_headers back into the title
    # case form expected when forwarding headers upstream.
    method forwarded_header_name {name} {
        set parts {}
        foreach part [split $name -] {
            lappend parts [string totitle $part]
        }
        return [join $parts -]
    }

    # Extract the buffered request body so the proxy can forward it unchanged
    # once it has rewritten the request line and filtered the headers.
    method request_body {request} {
        set header_end [string first "\r\n\r\n" $request]
        if {$header_end < 0} {
            return {}
        }
        return [string range $request [expr {$header_end + 4}] end]
    }

    # Read the upstream response without blocking the event loop. The proxy and
    # origin services run in the same test server process, so a blocking read
    # would deadlock while the origin waits for the event loop to dispatch its
    # own readable callbacks.
    method read_upstream_response {upstream} {
        chan configure $upstream -blocking 0 -buffering none -translation binary

        set response {}
        set wait_var ::tclcurl::testserver::proxy_wait_[string map {: _} $upstream]
        while 1 {
            set chunk [chan read $upstream]
            if {$chunk ne {}} {
                append response $chunk
            }
            if {[chan eof $upstream]} {
                break
            }
            if {[chan blocked $upstream]} {
                set $wait_var 0
                chan event $upstream readable [list set $wait_var 1]
                vwait $wait_var
                chan event $upstream readable {}
                catch {unset $wait_var}
                continue
            }
            break
        }

        catch {unset $wait_var}
        return $response
    }

    # Tear down both sides of an active CONNECT tunnel and discard the book-
    # keeping used by the asynchronous copy callbacks.
    method close_tunnel {root} {
        if {![info exists tunnel_peer($root)]} {
            return
        }

        set peer $tunnel_peer($root)
        catch {unset tunnel_pending($root)}
        catch {unset tunnel_root($root)}
        catch {unset tunnel_root($peer)}
        catch {unset tunnel_peer($root)}
        catch {unset tunnel_peer($peer)}
        catch {close $root}
        catch {close $peer}
    }

    # Complete one direction of an asynchronous CONNECT tunnel copy. The tunnel
    # is closed after both directions finish, or immediately if one direction
    # ends with an error.
    method tunnel_copy_done {src dst direction bytes {error {}}} {
        set root $tunnel_root($src)
        ::tclcurl::test::msgoutput \
            "proxy tunnel copy done direction=$direction src=$src dst=$dst bytes=$bytes error=$error"

        if {$error ne {}} {
            my close_tunnel $root
            return
        }

        incr tunnel_pending($root) -1
        if {$tunnel_pending($root) <= 0} {
            my close_tunnel $root
        }
    }

    # Establish a CONNECT tunnel to the requested upstream endpoint and bridge
    # bytes asynchronously in both directions.
    method start_tunnel {chan host port} {
        ::tclcurl::test::msgoutput \
            "proxy tunnel connect chan=$chan host=$host port=$port"
        if {[catch {set upstream [socket $host $port]} socket_error]} {
            ::tclcurl::test::msgoutput \
                "proxy tunnel connect failed chan=$chan error=$socket_error"
            my log_request "method=CONNECT status=502 target=[::tclcurl::testserver::log_value $host:$port]"
            my proxy_response $chan 502 "Bad Gateway" "proxy-error=$socket_error\n" {}
            return
        }

        chan configure $upstream -blocking 0 -buffering none -translation binary
        set tunnel_peer($chan) $upstream
        set tunnel_peer($upstream) $chan
        set tunnel_root($chan) $chan
        set tunnel_root($upstream) $chan
        set tunnel_pending($chan) 2

        if {[catch {
            puts -nonewline $chan "HTTP/1.1 200 Connection Established\r\n\r\n"
            flush $chan
        } write_error]} {
            ::tclcurl::test::msgoutput \
                "proxy tunnel establish failed chan=$chan error=$write_error"
            my close_tunnel $chan
            return
        }

        my log_request "method=CONNECT status=200 target=[::tclcurl::testserver::log_value $host:$port]"

        chan copy $chan $upstream -command \
            [list [self] tunnel_copy_done $chan $upstream client_to_upstream]
        chan copy $upstream $chan -command \
            [list [self] tunnel_copy_done $upstream $chan upstream_to_client]
    }

    # Build the standard proxy reply for malformed requests before any upstream
    # forwarding is attempted.
    method bad_request_response {} {
        return [dict create status      400 \
                            reason      "Bad Request" \
                            body        "bad proxy request\n" \
                            headers     {}]
    }

    # Parse the proxy request, enforce proxy-specific policy and forward the
    # request upstream. The base class already guarantees that the request is
    # fully buffered before this method runs.
    method handle_request {chan request} {
        ::tclcurl::test::msgoutput \
            "proxy handle_request chan=$chan request-bytes=[string length $request]"
        set request_info [$application parse_request_line $request]
        if {$request_info eq {}} {
            ::tclcurl::test::msgoutput \
                "proxy bad request chan=$chan reason=request-line-parse-failed"
            my log_request "method=? status=400 target=?"
            my proxy_response $chan 400 "Bad Request" "bad proxy request\n" {}
            return
        }

        dict with request_info {}
        ::tclcurl::test::msgoutput \
            "proxy request-line chan=$chan method=$method target=$target version=$version"
        set headers [$application parse_headers $request]

        if {$method eq "CONNECT"} {
            if {[catch {set connect_info [my parse_connect_target $target]} connect_error]} {
                ::tclcurl::test::msgoutput \
                    "proxy bad connect target chan=$chan target=$target error=$connect_error"
                my log_request "method=$method status=400 target=[::tclcurl::testserver::log_value $target]"
                my proxy_response $chan 400 "Bad Request" "bad proxy request\n" {}
                return
            }
            my start_tunnel $chan [dict get $connect_info host] [dict get $connect_info port]
            return
        }

        set target_info [my parse_target $target $headers]
        set path [dict get $target_info path]
        ::tclcurl::test::msgoutput \
            "proxy target chan=$chan path=$path target-info=$target_info"

        if {[my auth_required $path]} {
            set auth_status [my validate_proxy_auth $headers]
            ::tclcurl::test::msgoutput \
                "proxy auth chan=$chan path=$path status=$auth_status"
            if {$auth_status ne "ok"} {
                my log_request \
                    "method=$method status=407 target=[::tclcurl::testserver::log_value $path]"
                my proxy_response $chan 407 \
                    "Proxy Authentication Required" "proxy-auth=$auth_status\n" \
                    [list "Proxy-Authenticate: Basic realm=\"TclCurl Proxy Test\""]
                return
            }
        }

        set host [dict get $target_info host]
        set port [dict get $target_info port]
        set origin_path [dict get $target_info path]
        ::tclcurl::test::msgoutput \
            "proxy connect chan=$chan host=$host port=$port origin-path=$origin_path"
        if {[catch {set upstream [socket $host $port]} socket_error]} {
            ::tclcurl::test::msgoutput \
                "proxy connect failed chan=$chan error=$socket_error"
            my log_request \
                "method=$method status=502 target=[::tclcurl::testserver::log_value $origin_path]"
            my proxy_response $chan 502 "Bad Gateway" "proxy-error=$socket_error\n" {}
            return
        }

        chan configure $upstream -blocking 1 -buffering none -translation binary
        set upstream_headers {}
        dict for {name value} $headers {
            if {$name in {proxy-authorization proxy-connection}} {
                continue
            }
            lappend upstream_headers "[my forwarded_header_name $name]: $value"
        }
        ::tclcurl::test::msgoutput \
            "proxy forward headers chan=$chan count=[llength $upstream_headers]"

        set request_body [my request_body $request]
        ::tclcurl::test::msgoutput \
            "proxy forward body chan=$chan bytes=[string length $request_body]"

        try {
            ::tclcurl::test::msgoutput \
                "proxy upstream write start chan=$chan upstream=$upstream"
            puts -nonewline $upstream "$method $origin_path HTTP/$version\r\n"
            puts -nonewline $upstream "[join $upstream_headers "\r\n"]"
            puts -nonewline $upstream "\r\n\r\n"
            if {$request_body ne {}} {
                puts -nonewline $upstream $request_body
            }
            flush $upstream
            ::tclcurl::test::msgoutput \
                "proxy upstream read start chan=$chan upstream=$upstream"
            set response [my read_upstream_response $upstream]
            ::tclcurl::test::msgoutput \
                "proxy upstream read done chan=$chan response-bytes=[string length $response]"
        } finally {
            ::tclcurl::test::msgoutput \
                "proxy upstream close chan=$chan upstream=$upstream"
            catch {close $upstream}
        }

        set upstream_status ?
        if {[regexp {^HTTP/[0-9.]+\s+([0-9]+)} $response -> parsed_status]} {
            set upstream_status $parsed_status
        }
        my log_request \
            "method=$method status=$upstream_status target=[::tclcurl::testserver::log_value $origin_path]"

        catch {
            ::tclcurl::test::msgoutput \
                "proxy client write chan=$chan response-bytes=[string length $response]"
            puts -nonewline $chan $response
            flush $chan
        }
        ::tclcurl::test::msgoutput "proxy complete chan=$chan"
        my close_client $chan
    }
}

::tclcurl::testserver register_service_class proxy ::tclcurl::testserver::proxy_service
