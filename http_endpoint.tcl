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

namespace eval ::tclwire {}

package require json

if {[info commands ::tclwire::http_endpoint_service] eq {}} {
    # Shared HTTP connection plumbing for test services that speak HTTP on the
    # client-facing side. Concrete subclasses keep their own request
    # completion details and response behavior, but they all share the same
    # listener setup, per-channel buffering and socket cleanup.

    # current services subclassing 'http_endpoint_service' are
    #
    #   * ::tclwire::http_server
    #   * ::tclwire::proxy_service

    oo::class create ::tclwire::http_endpoint_service {
        superclass ::tclwire::service

        variable request_data http_error_messages

        constructor args {
            array set request_data {}
            set http_error_messages [my load_http_error_messages]
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
            ::tclwire::msgoutput "accept connection chan=$chan host=$host port=$port"
            chan event $chan readable [list [self] read_request $chan]
        }

        method read_request {chan} {
            ::tclwire::msgoutput "readable chan=$chan"
            if {[eof $chan]} {
                ::tclwire::msgoutput "read eof chan=$chan"
                my close_client $chan
                return
            }

            set chunk [read $chan]
            if {$chunk eq {}} {
                ::tclwire::msgoutput "read empty chan=$chan"
                return
            }

            ::tclwire::msgoutput "read bytes chan=$chan count=[string length $chunk]"
            append request_data($chan) $chunk
            set request [my complete_request $request_data($chan)]
            if {$request eq {}} {
                ::tclwire::msgoutput "request incomplete chan=$chan buffered=[string length $request_data($chan)]"
                return
            }

            ::tclwire::msgoutput "request complete chan=$chan bytes=[string length $request]"
            unset request_data($chan)
            chan event $chan readable {}
            if {[catch {my handle_request $chan $request} request_error request_options]} {
                ::tclwire::msgoutput \
                    "request handling failed chan=$chan error=$request_error options=$request_options"
                my close_client $chan
            }
        }

        method read_request_if_open {chan} {
            if {[lsearch -exact [chan names] $chan] < 0} {
                return
            }
            my read_request $chan
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

        method http_error_messages_file {} {
            return [file join [::tclwire::repo_root] http_error_messages.json]
        }

        method default_http_error_messages {} {
            return [dict create \
                000 [dict create reason "Internal Server Error" body "TclWire could not complete the request.\n"] \
                400 [dict create reason "Bad Request" body "bad request\n"] \
                404 [dict create reason "Not Found" body "not found\n"] \
                500 [dict create reason "Internal Server Error" body "internal server error\n"] \
                503 [dict create reason "Service Unavailable" body "service unavailable\n"]]
        }

        method load_http_error_messages {} {
            set path [my http_error_messages_file]
            if {![file exists $path]} {
                return [my default_http_error_messages]
            }

            set chan [open $path r]
            try {
                set content [read $chan]
            } finally {
                close $chan
            }

            if {[catch {::json::json2dict $content} messages]} {
                ::tclwire::msgoutput "failed to load HTTP error messages file=$path error=$messages"
                return [my default_http_error_messages]
            }

            return $messages
        }

        method html_escape {value} {
            return [string map [list \
                &  "&amp;" \
                <  "&lt;" \
                >  "&gt;" \
                \" "&quot;" \
                '  "&#39;"] $value]
        }

        method expand_http_error_body {body context} {
            set replacements {}
            dict for {name value} $context {
                lappend replacements "{{$name}}" [my html_escape $value]
            }
            if {[llength $replacements] == 0} {
                return $body
            }
            return [string map $replacements $body]
        }

        method http_error_message {status} {
            if {[dict exists $http_error_messages $status]} {
                return [dict get $http_error_messages $status]
            }
            return [dict get $http_error_messages 000]
        }

        method error_response {status {context {}}} {
            set message [my http_error_message $status]
            set reason [dict get $message reason]
            if {![dict exists $context status]} {
                dict set context status $status
            }
            set body [my expand_http_error_body [dict get $message body] $context]

            return [dict create \
                status $status \
                reason $reason \
                body $body \
                headers [list "Content-Type: text/html; charset=utf-8"]]
        }

        method close_client {chan {error {}}} {
            catch {unset request_data($chan)}
            catch {close $chan}
        }
    }
}
