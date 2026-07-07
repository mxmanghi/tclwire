# http_protocol.tcl --
#
# Minimal HTTP protocol session used by the connection-agent prototype.

package require TclOO
package require tclwire::http::query 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpProtocolSession {
    variable input_state header_buffer request_info body_framing transfer_codings
    variable body_threshold spool_directory body_data body_channel body_path body_size
    variable body_remaining chunk_buffer chunk_remaining trailers completed_descriptor
    variable declared_request_size
    variable header_size
    variable transfer_stream
    variable max_body_bytes

    constructor {args} {
        array set options {
            -bodythreshold 1048576
            -spooldirectory /tmp
            -maxbodybytes 16777216
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        if {![string is integer -strict $options(-bodythreshold)] ||
                $options(-bodythreshold) < 0} {
            error "-bodythreshold must be a non-negative integer"
        }
        if {![string is integer -strict $options(-maxbodybytes)] ||
                $options(-maxbodybytes) < 1} {
            error "-maxbodybytes must be a positive integer"
        }
        set body_threshold $options(-bodythreshold)
        set spool_directory $options(-spooldirectory)
        set max_body_bytes $options(-maxbodybytes)
        my reset
    }

    destructor {
        my abort
    }

    method reset {} {
        my abort
        set input_state headers
        set header_buffer {}
        set request_info {}
        set body_framing none
        set transfer_codings {}
        set body_data [binary format a* {}]
        set body_channel {}
        set body_path {}
        set body_size 0
        set body_remaining 0
        set chunk_buffer [binary format a* {}]
        set chunk_remaining 0
        set trailers [dict create]
        set completed_descriptor {}
        set declared_request_size 0
        set header_size 0
        set transfer_stream {}
        return
    }

    method abort {} {
        if {[info exists body_channel] && $body_channel ne {}} {
            catch {close $body_channel}
            set body_channel {}
        }
        if {[info exists body_path] && $body_path ne {}} {
            catch {file delete $body_path}
            set body_path {}
        }
        if {[info exists transfer_stream] && $transfer_stream ne {}} {
            catch {$transfer_stream close}
            set transfer_stream {}
        }
        return
    }

    method parse_request_head {head} {
        set request_line [lindex [split $head "\r\n"] 0]
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
        set headers [my parse_headers "${head}\r\n\r\n"]
        return [dict create method $method target $target path $path query $query \
            query_dict [::tclwire::http::query decode $query] version $version \
            headers $headers]
    }

    method spill_body {} {
        if {$body_channel ne {}} { return }
        if {$spool_directory eq {}} {
            error "request body exceeded the in-memory threshold and no spool directory is configured"
        }
        file mkdir $spool_directory
        if {![file isdirectory $spool_directory] || ![file writable $spool_directory]} {
            error "request body spool directory is not writable: $spool_directory"
        }
        set body_channel [file tempfile body_path \
            [file join $spool_directory tclwire-request]]
        chan configure $body_channel -translation binary -encoding binary
        if {$body_data ne {}} {
            puts -nonewline $body_channel $body_data
            set body_data [binary format a* {}]
        }
        return
    }

    method append_body {bytes} {
        if {$bytes eq {}} { return }
        set new_size [expr {$body_size + [string length $bytes]}]
        if {$new_size > $max_body_bytes} {
            return -code error -errorcode {TCLWIRE HTTP BODY_TOO_LARGE} \
                "decoded request body exceeds configured limit"
        }
        if {$body_channel eq {} && $new_size > $body_threshold} {
            my spill_body
        }
        if {$body_channel eq {}} {
            append body_data $bytes
        } else {
            puts -nonewline $body_channel $bytes
        }
        set body_size $new_size
        return
    }

    method append_transfer_data {bytes} {
        if {$transfer_stream eq {}} {
            my append_body $bytes
            return
        }
        if {[catch {
            $transfer_stream put $bytes
            my drain_transfer_stream
        } message options]} {
            if {[dict exists $options -errorcode] &&
                    [dict get $options -errorcode] eq \
                        {TCLWIRE HTTP BODY_TOO_LARGE}} {
                return -options $options $message
            }
            error "invalid gzip transfer coding"
        }
        return
    }

    method drain_transfer_stream {} {
        while 1 {
            set decoded [$transfer_stream get 65536]
            if {$decoded eq {}} { return }
            my append_body $decoded
        }
    }

    method finish_incremental_request {} {
        if {$transfer_stream ne {}} {
            if {[catch {
                my drain_transfer_stream
                if {![$transfer_stream eof]} { error incomplete }
                $transfer_stream close
                set transfer_stream {}
            } message options]} {
                if {[dict exists $options -errorcode] &&
                        [dict get $options -errorcode] eq \
                            {TCLWIRE HTTP BODY_TOO_LARGE}} {
                    return -options $options $message
                }
                error "invalid gzip transfer coding"
            }
        }
        if {$body_channel ne {}} {
            close $body_channel
            set body_channel {}
            set body_descriptor [dict create body_mode spooled_file \
                body_path $body_path body_size $body_size]
            # Ownership passes to the completed descriptor.
            set body_path {}
        } else {
            set body_descriptor [dict create body_mode in_memory \
                body $body_data body_size $body_size]
        }
        set completed_descriptor [dict merge $request_info [dict create \
            body_framing $body_framing transfer_codings $transfer_codings \
            trailers $trailers] $body_descriptor]
        set input_state complete
        return [dict create status complete header_size $header_size \
            method [dict get $request_info method] \
            descriptor $completed_descriptor]
    }

    method feed_chunked {bytes} {
        append chunk_buffer $bytes
        while 1 {
            switch -exact -- $input_state {
                chunk_size {
                    set line_end [string first "\r\n" $chunk_buffer]
                    if {$line_end < 0} {
                        return [dict create status need_more phase body \
                            header_size $header_size \
                            method [dict get $request_info method]]
                    }
                    set size_line [string range $chunk_buffer 0 [expr {$line_end - 1}]]
                    set size_token [string trim [lindex [split $size_line ";"] 0]]
                    if {![regexp {^[0-9A-Fa-f]+$} $size_token] ||
                            [scan $size_token %x chunk_remaining] != 1} {
                        error "invalid chunk size"
                    }
                    set chunk_buffer [string range $chunk_buffer [expr {$line_end + 2}] end]
                    if {$chunk_remaining == 0} { set input_state chunk_trailers } \
                    else { set input_state chunk_data }
                }
                chunk_data {
                    set available [string length $chunk_buffer]
                    if {$available < $chunk_remaining} {
                        my append_transfer_data $chunk_buffer
                        incr chunk_remaining -$available
                        set chunk_buffer [binary format a* {}]
                        return [dict create status need_more phase body \
                            header_size $header_size \
                            method [dict get $request_info method]]
                    }
                    if {$chunk_remaining > 0} {
                        my append_transfer_data [string range $chunk_buffer 0 \
                            [expr {$chunk_remaining - 1}]]
                        set chunk_buffer [string range $chunk_buffer \
                            $chunk_remaining end]
                    }
                    set chunk_remaining 0
                    set input_state chunk_data_crlf
                }
                chunk_data_crlf {
                    if {[string length $chunk_buffer] < 2} {
                        return [dict create status need_more phase body \
                            header_size $header_size \
                            method [dict get $request_info method]]
                    }
                    if {[string range $chunk_buffer 0 1] ne "\r\n"} {
                        error "chunk data is not terminated by CRLF"
                    }
                    set chunk_buffer [string range $chunk_buffer 2 end]
                    set input_state chunk_size
                }
                chunk_trailers {
                    if {[string length $chunk_buffer] >= 2 &&
                            [string range $chunk_buffer 0 1] eq "\r\n"} {
                        set chunk_buffer [string range $chunk_buffer 2 end]
                        return [my finish_incremental_request]
                    }
                    set trailer_end [string first "\r\n\r\n" $chunk_buffer]
                    if {$trailer_end < 0} {
                        return [dict create status need_more phase body \
                            header_size $header_size \
                            method [dict get $request_info method]]
                    }
                    set trailers [my parse_trailers \
                        [string range $chunk_buffer 0 [expr {$trailer_end - 1}]]]
                    set chunk_buffer [string range $chunk_buffer \
                        [expr {$trailer_end + 4}] end]
                    return [my finish_incremental_request]
                }
            }
        }
    }

    method feed {bytes} {
        if {$input_state in {complete aborted}} {
            error "HTTP protocol session is not accepting request data"
        }
        if {$input_state eq "headers"} {
            append header_buffer $bytes
            set header_end [string first "\r\n\r\n" $header_buffer]
            if {$header_end < 0} {
                return [dict create status need_more phase headers]
            }
            set head [string range $header_buffer 0 [expr {$header_end - 1}]]
            set header_size [expr {$header_end + 4}]
            set bytes [string range $header_buffer [expr {$header_end + 4}] end]
            set header_buffer {}
            set request_info [my parse_request_head $head]
            set headers [dict get $request_info headers]
            set body_framing [my request_body_framing $headers]
            set transfer_codings [my transfer_codings $headers]
            if {$transfer_codings eq {gzip chunked}} {
                set transfer_stream [zlib stream gunzip]
            }
            switch -exact -- $body_framing {
                none { return [my finish_incremental_request] }
                content-length {
                    set body_remaining [dict get $headers content-length]
                    set declared_request_size [expr {
                        $header_end + 4 + $body_remaining
                    }]
                    set input_state fixed_body
                }
                chunked { set input_state chunk_size }
            }
        }
        if {$input_state eq "fixed_body"} {
            set take [expr {min($body_remaining, [string length $bytes])}]
            if {$take > 0} {
                my append_body [string range $bytes 0 [expr {$take - 1}]]
                incr body_remaining -$take
            }
            if {$body_remaining == 0} { return [my finish_incremental_request] }
            return [dict create status need_more phase body \
                header_size $header_size \
                method [dict get $request_info method] \
                declared_request_size $declared_request_size]
        }
        return [my feed_chunked $bytes]
    }

    method descriptor {} {
        if {$input_state ne "complete"} { error "HTTP request is incomplete" }
        return $completed_descriptor
    }
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
            set request_length [expr {$body_start + [dict get $chunk_info consumed_length]}]
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

        return [dict create method      $method     \
                            target      $target     \
                            path        $path       \
                            query       $query      \
                            query_dict [::tclwire::http::query decode $query] \
                            version     $version    \
                            headers     $headers    \
                            body_framing $framing   \
                            transfer_codings $codings \
                            body_mode   in_memory   \
                            body        $body       \
                            body_size   [string length $body] \
                            trailers    $trailers]
    }

    method build_response {
        status reason body content_encoding {headers {}} {body_mode text}
        {head_only 0}
    } {
        set body_bytes [my encode_response_body \
            $body $content_encoding $body_mode]
        set response_headers [list \
            "HTTP/1.1 $status $reason" \
            "Connection: close"]
        if {![regexp -nocase {(^|\n)Content-Length:} \
                [join $headers "\n"]]} {
            lappend response_headers \
                "Content-Length: [string length $body_bytes]"
        }
        set response_headers [concat $response_headers $headers]
        set response [encoding convertto ascii \
            "[join $response_headers "\r\n"]\r\n\r\n"]
        if {!$head_only} {
            append response $body_bytes
        }
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

    export request_body_framing
    unexport decode_transfer_codings parse_chunked_body parse_trailers \
        transfer_codings
}

package provide tclwire::http::protocol 0.1
