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
            set name [string tolower $name]
            if {$name in {content-length transfer-encoding} &&
                    [dict exists $headers $name]} {
                dict append headers $name ",$value"
            } else {
                dict set headers $name $value
            }
        }
        return $headers
    }

    method transfer_codings {headers} {
        if {![dict exists $headers transfer-encoding]} {
            return {}
        }

        set codings {}

        # Transfer-Encoding has two levels of syntax:
        #
        #   Transfer-Encoding: custom; option=value, chunked
        #                      ^ coding parameters  ^ next coding
        #
        # Commas separate the ordered transfer-coding chain. Semicolons
        # introduce parameters belonging to one coding. The currently
        # supported gzip and chunked codings do not define parameters, so a
        # parameterized coding is rejected rather than silently normalized.
        foreach value [split [dict get $headers transfer-encoding] ,] {
            set coding_parts [split $value ";"]
            if {[llength $coding_parts] != 1} {
                error "transfer-coding parameters are not supported"
            }
            set coding [string tolower [string trim [lindex $coding_parts 0]]]
            if {$coding eq {} || ![regexp {^[a-z0-9!#$%&'*+.^_`|~-]+$} $coding]} {
                error "invalid Transfer-Encoding"
            }
            lappend codings $coding
        }
        return $codings
    }

    method request_body_framing {headers} {
        set codings [my transfer_codings $headers]
        if {[llength $codings] > 0} {
            if {[dict exists $headers content-length]} {
                error "request contains both Transfer-Encoding and Content-Length"
            }
            if {$codings ni {{chunked} {gzip chunked}}} {
                error "unsupported Transfer-Encoding"
            }
            return chunked
        }
        if {[dict exists $headers content-length]} {
            set content_length [dict get $headers content-length]
            if {![string is integer -strict $content_length] || ($content_length < 0)} {
                error "invalid Content-Length"
            }
            return content-length
        }
        return none
    }

    method decode_transfer_codings {body codings} {
        set decoded $body
        foreach coding [lreverse $codings] {
            switch -exact -- $coding {
                chunked {
                    # Chunk framing was removed while locating the request end.
                }
                gzip {
                    if {[catch {set decoded [zlib gunzip $decoded]}]} {
                        error "invalid gzip transfer coding"
                    }
                }
                default {
                    error "unsupported Transfer-Encoding"
                }
            }
        }
        return $decoded
    }

    method parse_trailers {trailer_block} {
        set trailers [dict create]
        foreach line [split $trailer_block "\r\n"] {
            if {![regexp {^([^:]+):\s*(.*)$} $line -> name value]} {
                error "invalid chunk trailer"
            }
            dict set trailers [string tolower [string trim $name]] $value
        }
        return $trailers
    }

    method parse_chunked_body {body} {
        set decoded [binary format a* {}]
        set cursor 0

        while 1 {
            set line_end [string first "\r\n" $body $cursor]
            if {$line_end < 0} {
                return [dict create complete 0]
            }

            set size_line [string range $body $cursor [expr {$line_end - 1}]]
            set size_token [string trim [lindex [split $size_line ";"] 0]]
            if {![regexp {^[0-9A-Fa-f]+$} $size_token] ||
                    [scan $size_token %x chunk_size] != 1} {
                error "invalid chunk size"
            }

            set data_start [expr {$line_end + 2}]
            if {$chunk_size == 0} {
                if {[string length $body] < $data_start + 2} {
                    return [dict create complete 0]
                }
                if {[string range $body $data_start [expr {$data_start + 1}]] eq "\r\n"} {
                    return [dict create complete 1 \
                                        body     $decoded \
                                        trailers {} \
                                        consumed_length [expr {$data_start + 2}]]
                }

                set trailer_end [string first "\r\n\r\n" $body $data_start]
                if {$trailer_end < 0} {
                    return [dict create complete 0]
                }
                set trailer_block [string range $body $data_start [expr {$trailer_end - 1}]]
                return [dict create complete    1 \
                                    body        $decoded \
                                    trailers    [my parse_trailers $trailer_block] \
                                    consumed_length [expr {$trailer_end + 4}]]
            }

            set data_end [expr {$data_start + $chunk_size}]
            if {[string length $body] < $data_end + 2} {
                return [dict create complete 0]
            }
            if {[string range $body $data_end \
                    [expr {$data_end + 1}]] ne "\r\n"} {
                error "chunk data is not terminated by CRLF"
            }

            append decoded [string range $body $data_start \
                [expr {$data_end - 1}]]
            set cursor [expr {$data_end + 2}]
        }
    }

    method complete_request {request_data} {
        set header_end [string first "\r\n\r\n" $request_data]
        if {$header_end < 0} {
            return {}
        }

        set headers [my parse_headers $request_data]
        set framing [my request_body_framing $headers]
        if {$framing eq "chunked"} {
            set body_start [expr {$header_end + 4}]
            set chunk_info [my parse_chunked_body \
                [string range $request_data $body_start end]]
            if {![dict get $chunk_info complete]} {
                return {}
            }
            set request_length \
                [expr {$body_start + [dict get $chunk_info consumed_length]}]
            return [string range $request_data 0 [expr {$request_length - 1}]]
        }

        set content_length 0
        if {$framing eq "content-length"} {
            set content_length [dict get $headers content-length]
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
        if {$header_end < 0} {
            error "HTTP request headers are incomplete"
        }
        set headers [my parse_headers $request]
        set framing [my request_body_framing $headers]
        set codings [my transfer_codings $headers]
        set trailers [dict create]
        if {$framing eq "chunked"} {
            set chunk_info [my parse_chunked_body \
                [string range $request [expr {$header_end + 4}] end]]
            if {![dict get $chunk_info complete]} {
                error "chunked HTTP request body is incomplete"
            }
            set body [my decode_transfer_codings \
                [dict get $chunk_info body] $codings]
            set trailers [dict get $chunk_info trailers]
        } else {
            set body [string range $request [expr {$header_end + 4}] end]
        }

        return [dict create     method $method \
                                target $target \
                                path   $path \
                                query  $query \
                                version $version \
                                headers $headers \
                                body_framing $framing \
                                transfer_codings $codings \
                                body_mode in_memory \
                                body   $body \
                                body_size [string length $body] \
                                trailers $trailers]
    }

    method build_response {
        status reason body content_encoding {headers {}} {body_mode text}
    } {
        set body_bytes [my encode_response_body \
            $body $content_encoding $body_mode]
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

    method encode_response_body {body content_encoding body_mode} {
        switch -exact -- $body_mode {
            binary {
                return $body
            }
            text {
                return [encoding convertto $content_encoding $body]
            }
            default {
                error "unknown HTTP response body mode: $body_mode"
            }
        }
    }

    method build_chunked_response_head {
        status reason content_encoding headers body_mode
    } {
        set response_headers [list \
            "HTTP/1.1 $status $reason" \
            "Connection: close" \
            "Transfer-Encoding: chunked"]
        if {![regexp -nocase {^Content-Type:} [join $headers "\n"]]} {
            if {$body_mode eq "binary"} {
                lappend response_headers "Content-Type: application/octet-stream"
            } else {
                lappend response_headers \
                    "Content-Type: text/html; charset=$content_encoding"
            }
        }
        foreach header $headers {
            if {[regexp -nocase {^(Content-Length|Transfer-Encoding):} $header]} {
                continue
            }
            lappend response_headers $header
        }
        return [encoding convertto ascii \
            "[join $response_headers "\r\n"]\r\n\r\n"]
    }

    method chunk_frame {body_bytes} {
        if {$body_bytes eq {}} {
            return {}
        }
        set frame [encoding convertto ascii \
            "[format %X [string length $body_bytes]]\r\n"]
        append frame $body_bytes "\r\n"
        return $frame
    }

    method chunk_terminator {} {
        return [encoding convertto ascii "0\r\n\r\n"]
    }

    unexport decode_transfer_codings parse_chunked_body parse_trailers \
        request_body_framing transfer_codings
}

package provide tclwire::http::protocol 0.1
