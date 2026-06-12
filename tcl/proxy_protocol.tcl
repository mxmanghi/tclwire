# proxy_protocol.tcl --
#
# HTTP proxy target parsing and upstream request construction.

package require TclOO
package require tclwire::http::protocol 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ProxyProtocolSession {
    superclass ::tclwire::HttpProtocolSession

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
            }} {
                continue
            }
            lappend headers "[my forwarded_header_name $name]: $value"
        }
        lappend headers "Connection: close"

        set request "[dict get $request_descriptor method] [dict get $target_info path] HTTP/[dict get $request_descriptor version]\r\n"
        append request "[join $headers "\r\n"]\r\n\r\n"
        append request [dict get $request_descriptor body]
        return $request
    }

    unexport forwarded_header_name parse_authority validate_endpoint
}

package provide tclwire::proxy::protocol 0.1
