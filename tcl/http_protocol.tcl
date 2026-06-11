# http_protocol.tcl --
#
# Minimal HTTP protocol session used by the connection-agent prototype.

package require TclOO

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpProtocolSession {
    method parse_headers {request} {
        set header_end [string first "\r\n\r\n" $request]
        if {$header_end < 0} {
            return [dict create]
        }

        set header_block [string range $request 0 [expr {$header_end - 1}]]
        set lines [regexp -all -inline {[^\r\n]+} $header_block]
        set headers [dict create]

        foreach line [lrange $lines 1 end] {
            if {![regexp {^([^:]+):\s*(.*)$} $line -> name value]} {
                continue
            }
            dict set headers [string tolower $name] $value
        }
        return $headers
    }

    method complete_request {request_data} {
        set header_end [string first "\r\n\r\n" $request_data]
        if {$header_end < 0} {
            return {}
        }

        set headers [my parse_headers $request_data]
        set content_length 0
        if {[dict exists $headers content-length]} {
            set content_length [dict get $headers content-length]
            if {![string is integer -strict $content_length] || $content_length < 0} {
                error "invalid Content-Length"
            }
        }

        set request_length [expr {$header_end + 4 + $content_length}]
        if {[string length $request_data] < $request_length} {
            return {}
        }
        return [string range $request_data 0 [expr {$request_length - 1}]]
    }

    method parse_request {request} {
        set request_line [lindex [split $request "\r\n"] 0]
        if {![regexp {^([A-Z]+) ([^ ]+) HTTP/([0-9.]+)$} \
                $request_line -> method target version]} {
            error "invalid HTTP request line"
        }

        set query {}
        set path $target
        set query_start [string first ? $target]
        if {$query_start >= 0} {
            set path [string range $target 0 [expr {$query_start - 1}]]
            set query [string range $target [expr {$query_start + 1}] end]
        }

        set header_end [string first "\r\n\r\n" $request]
        set body [string range $request [expr {$header_end + 4}] end]

        return [dict create \
            method $method \
            target $target \
            path $path \
            query $query \
            version $version \
            headers [my parse_headers $request] \
            body_mode in_memory \
            body $body \
            body_size [string length $body]]
    }

    method build_response {
        status reason body content_encoding {headers {}} {body_mode text}
    } {
        if {$body_mode eq "binary"} {
            set body_bytes $body
        } elseif {$body_mode eq "text"} {
            set body_bytes [encoding convertto $content_encoding $body]
        } else {
            error "unknown HTTP response body mode: $body_mode"
        }
        set response_headers [list \
            "HTTP/1.1 $status $reason" \
            "Connection: close" \
            "Content-Length: [string length $body_bytes]"]
        if {![regexp -nocase {^Content-Type:} [join $headers "\n"]]} {
            if {$body_mode eq "binary"} {
                lappend response_headers "Content-Type: application/octet-stream"
            } else {
                lappend response_headers \
                    "Content-Type: text/html; charset=$content_encoding"
            }
        }
        set response_headers [concat $response_headers $headers]
        set response [encoding convertto ascii \
            "[join $response_headers "\r\n"]\r\n\r\n"]
        append response $body_bytes
        return $response
    }
}

package provide tclwire::http::protocol 0.1
