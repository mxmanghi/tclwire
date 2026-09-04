# proxy_protocol.tcl --
#
# HTTP proxy target parsing and upstream request construction.

package require TclOO
package require tclwire::http::protocol 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ProxyProtocolSession {
    superclass ::tclwire::HttpProtocolSession

    # Feed connection bytes through the inherited incremental HTTP parser while
    # preserving bytes that belong after the proxy request.  This matters for
    # CONNECT: a client may send tunnel bytes in the same read as the request
    # header, and those bytes must be forwarded upstream rather than consumed
    # as HTTP parser input.
    #
    # HttpProtocolSession::feed intentionally reports the completed descriptor,
    # not unconsumed input.  The proxy keeps that contract intact by deciding
    # how much data is safe to feed at each parser state:
    #
    #   headers
    #       Buffer until the complete header section is visible, then feed
    #       exactly through CRLFCRLF.  Any bytes after CRLFCRLF wait until the
    #       parser says whether the request has a body.
    #
    #   fixed_body
    #       Feed at most body_remaining bytes, so bytes after Content-Length are
    #       left as trailing data.
    #
    #   chunked body states
    #       Feed conservatively.  Chunk framing determines completion, so this
    #       wrapper advances one byte at a time to avoid crossing the terminal
    #       chunk/trailer boundary.
    #
    # On completion the returned feed_result includes a proxy-only trailing key.
    method feed_proxy_request {bytes} {
        variable proxy_pending
        variable input_state
        variable body_remaining

        if {![info exists proxy_pending]} {
            set proxy_pending {}
        }
        append proxy_pending $bytes

        set result {}
        while {$proxy_pending ne {}} {
            switch -exact -- $input_state {
                headers {
                    set header_end [string first \
                        $::tclwire::constants::http_header_separator \
                        $proxy_pending]
                    if {$header_end < 0} {
                        return [my feed_result need_more headers]
                    } else {
                        set take [expr {$header_end + 4}]
                        set part [string range $proxy_pending 0 $take-1]
                        set proxy_pending [string range $proxy_pending $take end]
                    }
                }
                fixed_body {
                    set take [expr {min($body_remaining, [string length $proxy_pending])}]
                    if {$take <= 0} {
                        break
                    }
                    set part [string range $proxy_pending 0 $take-1]
                    set proxy_pending [string range $proxy_pending $take end]
                }
                chunk_size -
                chunk_data -
                chunk_data_crlf -
                chunk_trailers {
                    set part [string index $proxy_pending 0]
                    set proxy_pending [string range $proxy_pending 1 end]
                }
                complete {
                    set result [my feed_result complete complete [my descriptor]]
                    dict set result trailing $proxy_pending
                    set proxy_pending {}
                    return $result
                }
                default {
                    error "invalid proxy parser state: $input_state"
                }
            }

            set result [my feed $part]
            if {[dict get $result status] eq "complete"} {
                dict set result trailing $proxy_pending
                set proxy_pending {}
                return $result
            }
        }

        if {$result eq {}} {
            return [my feed_result need_more body]
        }
        return $result
    }

    method parse_target {target headers} {
        if {[regexp {^http://(\[[^\]]+\]|[^/:]+)(?::([0-9]+))?(/.*)?$} \
                $target -> host port path]} {
            set host [string trim $host {[]}]
            if {$port eq {}} {
                set port 80
            }
            if {$path eq {}} {
                set path /
            }
            return [my validate_endpoint $host $port $path]
        }

        if {![dict exists $headers host]} {
            error "proxy request is missing Host"
        }
        lassign [my parse_authority [dict get $headers host] 80] host port
        return [my validate_endpoint $host $port $target]
    }

    method parse_connect_target {target} {
        lassign [my parse_authority $target {}] host port
        if {$port eq {}} {
            error "CONNECT target must include a port"
        }
        return [my validate_endpoint $host $port {}]
    }

    method parse_authority {authority default_port} {
        if {[regexp {^\[([^\]]+)\](?::([0-9]+))?$} \
                $authority -> host port]} {
            if {$port eq {}} {
                set port $default_port
            }
            return [list $host $port]
        }
        if {![regexp {^([^:]+)(?::([0-9]+))?$} \
                $authority -> host port]} {
            error "invalid proxy authority"
        }
        if {$port eq {}} {
            set port $default_port
        }
        return [list $host $port]
    }

    method validate_endpoint {host port path} {
        if {[string trim $host] eq {}} {
            error "proxy target host must not be empty"
        }
        if {![string is integer -strict $port] || $port < 1 || $port > 65535} {
            error "invalid proxy target port"
        }
        return [dict create host $host port $port path $path]
    }

    method forwarded_header_name {name} {
        set parts {}
        foreach part [split $name -] {
            lappend parts [string totitle $part]
        }
        return [join $parts -]
    }

    method build_upstream_request {request_descriptor target_info} {
        set headers {}
        dict for {name value} [dict get $request_descriptor headers] {
            if {$name in {
                proxy-authorization proxy-connection connection
                content-length transfer-encoding trailer
            }} {
                continue
            }
            lappend headers "[my forwarded_header_name $name]: $value"
        }
        set body [dict get $request_descriptor body]
        set body_framing none
        if {[dict exists $request_descriptor body_framing]} {
            set body_framing [dict get $request_descriptor body_framing]
        }
        if {$body ne {} || $body_framing ne "none"} {
            lappend headers "Content-Length: [string length $body]"
        }
        lappend headers "Connection: close"

        set request "[dict get $request_descriptor method] [dict get $target_info path] HTTP/[dict get $request_descriptor version]\r\n"
        append request "[join $headers "\r\n"]\r\n\r\n"
        append request $body
        return $request
    }

    unexport forwarded_header_name parse_authority validate_endpoint
}

package provide tclwire::proxy::protocol 0.1
