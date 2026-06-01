# http_endpoint.tcl --
#
# Shared HTTP endpoint plumbing for TclCurl test servers.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclcurl::testserver {}

if {[info commands ::tclcurl::testserver::http_endpoint_service] eq {}} {
    # Shared HTTP connection plumbing for test services that speak HTTP on the
    # client-facing side. Concrete subclasses keep their own request
    # completion details and response behavior, but they all share the same
    # listener setup, per-channel buffering and socket cleanup.

    # current services subclassing 'http_endpoint_service' are
    #
    #   * ::tclcurl::testserver::http_server
    #   * ::tclcurl::testserver::proxy_service

    oo::class create ::tclcurl::testserver::http_endpoint_service {
        superclass ::tclcurl::testserver::service

        variable request_data

        constructor args {
            array set request_data {}
            next {*}$args
        }

        destructor {
            foreach chan [array names request_data] {
                catch {close $chan}
            }
            next
        }

        method start {} {
            set listener [socket -server [list [self] accept] -myaddr [my host] [my port]]
            my set_listener $listener
            my log [my listening_message]
            return $listener
        }

        method accept {chan host port} {
            chan configure $chan -blocking 0 -buffering none -translation binary
            ::tclcurl::test::msgoutput "accept connection chan=$chan host=$host port=$port"
            chan event $chan readable [list [self] read_request $chan]
        }

        method read_request {chan} {
            if {[eof $chan]} {
                my close_client $chan
                return
            }

            set chunk [read $chan]
            if {$chunk eq {}} {
                return
            }

            append request_data($chan) $chunk
            set request [my complete_request $request_data($chan)]
            if {$request eq {}} { return }

            unset request_data($chan)
            chan event $chan readable {}
            if {[catch {my handle_request $chan $request} request_error request_options]} {
                ::tclcurl::test::msgoutput \
                    "request handling failed chan=$chan error=$request_error options=$request_options"
                my close_client $chan
            }
        }

        # Default request framing for simple HTTP services: a complete header
        # block plus an optional fixed-size body announced by Content-Length.

        method complete_request {request_data} {
            set header_end [string first "\r\n\r\n" $request_data]
            if {$header_end < 0} {
                return {}
            }

            set headers [[my application] parse_headers $request_data]
            set content_length 0
            if {[dict exists $headers content-length]} {
                set content_length [dict get $headers content-length]
            }
            set request_length [expr {$header_end + 4 + $content_length}]
            if {[string length $request_data] < $request_length} {
                return {}
            }

            return [string range $request_data 0 [expr {$request_length - 1}]]
        }

        # Subclasses receive a fully buffered request and are responsible for
        # producing the service-specific response or forwarding behavior.

        method handle_request {chan request} {
            error "handle_request must be implemented by subclasses"
        }

        method close_client {chan} {
            catch {unset request_data($chan)}
            catch {close $chan}
        }
    }
}
