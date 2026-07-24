# http_protocol.tcl --
#
# Minimal HTTP protocol session used by the connection-agent prototype.

package require TclOO
package require tclwire::constants 0.1
package require tclwire::http::query 0.1
package require tclwire::http::message 0.1
package require tclwire::http::multipart 0.1

oo::class create ::tclwire::HttpProtocolSession {
    variable input_state header_buffer request_info request_info_status
    variable request_method request_headers
    variable body_framing transfer_codings
    variable body_threshold spool_directory body_data body_channel body_path body_size
    variable body_sink
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
        set body_threshold  $options(-bodythreshold)
        set spool_directory $options(-spooldirectory)
        set max_body_bytes  $options(-maxbodybytes)
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
        set request_info_status empty
        set request_method {}
        set request_headers {}
        set body_framing none
        set transfer_codings {}
        set body_data $::tclwire::constants::empty_bytearray
        set body_channel {}
        set body_path {}
        set body_size 0
        set body_sink {}
        set body_remaining 0
        set chunk_buffer $::tclwire::constants::empty_bytearray
        set chunk_remaining 0
        set trailers [dict create]
        set completed_descriptor {}
        set declared_request_size 0
        set header_size 0
        set transfer_stream {}
        return
    }

    # Install the parsed request head into the session.
    #
    # parse_request_head returns the stable request metadata extracted from the
    # request line and headers: method, target, path, query, decoded query_dict,
    # HTTP version, and normalized header dictionary.  feed stores that full
    # dictionary in request_info, and also caches request_method and
    # request_headers because the incremental parser needs those values often
    # while deciding framing and reporting feed_result progress.
    #
    # This method is deliberately single-use.  A protocol session accepts one
    # request at a time; once headers have been parsed, replacing request_info
    # would make already-derived parser state such as body_framing and
    # transfer_codings inconsistent with the visible request metadata.
    method install_request_info {info} {
        if {$request_info_status ne "empty"} {
            error "HTTP request information is already initialized"
        }
        set request_info $info
        set request_method [dict get $info method]
        set request_headers [dict get $info headers]
        set request_info_status complete
        return
    }

    method request_info_snapshot {} {
        if {$request_info_status ne "complete"} {
            error "HTTP request information is not initialized"
        }
        return $request_info
    }

    method request_headers {} {
        if {$request_info_status ne "complete"} {
            error "HTTP request information is not initialized"
        }
        return $request_headers
    }

    method request_method {} {
        if {$request_info_status ne "complete"} {
            error "HTTP request information is not initialized"
        }
        return $request_method
    }

    method expects_continue {} {
        if {$request_info_status ne "complete"} {
            return 0
        }
        if {![dict exists $request_headers expect]} {
            return 0
        }
        foreach expectation [split [dict get $request_headers expect] ","] {
            if {[string equal -nocase [string trim $expectation] "100-continue"]} {
                return 1
            }
        }
        return 0
    }

    method feed_result {status phase {descriptor {}}} {
        # Contract for HttpProtocolSession::feed callers:
        #
        #   status                need_more | complete
        #   phase                 headers | body | complete
        #   header_size           bytes currently held as headers, or the
        #                         final parsed header-section size
        #   method                parsed HTTP method, or empty before headers
        #   declared_request_size final wire request size for Content-Length
        #                         requests, otherwise 0
        #   descriptor            completed request descriptor, or empty until
        #                         status is complete
        #
        # Keep this dictionary shape stable so connection agents can treat it
        # as a protocol-session contract rather than probing for optional keys.

        set method {}
        if {$request_info_status eq "complete"} {
            set method $request_method
        }
        return [dict create     status      $status \
                                phase       $phase \
                                header_size $header_size \
                                method      $method \
                                declared_request_size $declared_request_size \
                                descriptor $descriptor]
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
        if {[info exists body_sink] && $body_sink ne {}} {
            catch {$body_sink abort}
            catch {$body_sink destroy}
            set body_sink {}
        }
        return
    }

    method parse_request_head {head} {
        set request_line [lindex [split $head "\r\n"] 0]
        if {![regexp {^([A-Z]+) ([^ ]+) HTTP/([0-9.]+)$} $request_line -> method target version]} {
            error "invalid HTTP request line"
        }
        set query {}
        set path $target
        set query_start [string first ? $target]
        if {$query_start >= 0} {
            set path  [string range $target 0 $query_start-1]
            set query [string range $target $query_start+1 end]
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
        set body_channel [file tempfile body_path [file join $spool_directory tclwire-request]]
        chan configure $body_channel -translation binary -encoding binary
        if {$body_data ne {}} {
            puts -nonewline $body_channel $body_data
            set body_data $::tclwire::constants::empty_bytearray
        }
        return
    }

    # -- append_raw_body
    #
    # Store decoded bytes for a non-multipart body.  Small bodies remain in
    # body_data; larger bodies spill through body_channel to body_path.

    method append_raw_body {bytes new_size} {
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

    # -- append_body_sink
    #
    # Send decoded bytes to the selected semantic body consumer.  At present
    # this is the multipart incremental parser created by select_body_sink.

    method append_body_sink {bytes new_size} {
        $body_sink append $bytes
        set body_size $new_size
        return
    }

    # -- append_body
    #
    # Common decoded-body entry point used by fixed-length and chunked paths.
    # It enforces the aggregate decoded-size limit, then dispatches to either
    # the semantic body sink or the raw body storage path.

    method append_body {bytes} {
        if {$bytes eq {}} { return }
        set new_size [expr {$body_size + [string length $bytes]}]
        if {$new_size > $max_body_bytes} {
            return  -code       error \
                    -errorcode {TCLWIRE HTTP BODY_TOO_LARGE} \
                    "decoded request body exceeds configured limit"
        }
        if {$body_sink ne {}} {
            return [my append_body_sink $bytes $new_size]
        }
        my append_raw_body $bytes $new_size
    }

    method select_body_sink {headers} {
        if {$spool_directory eq {} || ![dict exists $headers content-type]} {
            return
        }
        set content_type [dict get $headers content-type]
        set content_info [::tclwire::http::message parse_content_type $content_type]
        if {[string match multipart/* [dict get $content_info media_type]]} {
            set body_sink \
                [::tclwire::http::multipart::IncrementalParser new $content_type $spool_directory]
        }
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
                [dict get $options -errorcode] eq {TCLWIRE HTTP BODY_TOO_LARGE}} {
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

    # Finish the request assembled by feed's incremental parser.
    #
    # During feed, the header section chooses the processing pieces used for
    # transfer decoding, specialized body consumption, and body storage:
    #
    #   transfer_stream
    #       A zlib stream used only when Transfer-Encoding says that the
    #       chunk payload is gzip encoded.  Bytes read from the wire are first
    #       de-chunked by feed_chunked, then passed through this stream, and
    #       only the decoded bytes are appended to the request body.
    #
    #   body_sink
    #       A specialized decoded-body consumer.  Today this is the multipart
    #       incremental parser selected for multipart Content-Type requests.
    #       When present, append_body sends decoded body bytes to this object
    #       instead of aggregating the raw decoded body in memory or on disk.
    #
    #   body_channel
    #       The temporary file channel used for non-multipart decoded bodies
    #       after their size grows beyond body_threshold.  If this is set at
    #       completion, the final descriptor owns body_path and applications
    #       read the body from that spooled file.
    #
    # This method is the normalization point for all body framing paths
    # (no body, Content-Length, and chunked).  It drains and validates any
    # transfer decoder, closes or finishes the active body storage mechanism,
    # merges the body descriptor with the parsed request metadata, and returns
    # the feed_result that tells the connection agent the request is complete.

    method finish_incremental_request {} {
        if {$transfer_stream ne {}} {
            # A transfer decoder can still hold output internally after the
            # last wire byte was fed.  Drain it and require EOF so truncated
            # gzip transfer coding is rejected before exposing the request.
            if {[catch {
                my drain_transfer_stream
                if {![$transfer_stream eof]} { error incomplete }
                $transfer_stream close
                set transfer_stream {}
            } message options]} {
                if {[dict exists $options -errorcode] &&
                    [dict get $options -errorcode] eq {TCLWIRE HTTP BODY_TOO_LARGE}} {
                    return -options $options $message
                }
                error "invalid gzip transfer coding"
            }
        }
        if {$body_sink ne {}} {
            # Multipart bodies are not exposed as one aggregate raw body here.
            # The sink has already parsed decoded bytes into part descriptors,
            # possibly with uploaded files spooled individually.
            set parts [$body_sink finish]
            $body_sink destroy
            set body_sink {}
            set body_descriptor [dict create body_media multipart       \
                                             body_storage decomposed    \
                                             multipart_parts $parts     \
                                             body_size $body_size]
        } elseif {$body_channel ne {}} {
            # A plain decoded body crossed the in-memory threshold.  Close the
            # spool channel and transfer file ownership to the final request
            # descriptor by leaving body_path in that descriptor.
            close $body_channel
            set body_channel {}
            set body_descriptor [dict create body_media raw             \
                                             body_storage spooled_file  \
                                             body_path $body_path       \
                                             body_size $body_size]
            # Ownership passes to the completed descriptor.
            set body_path {}
        } else {
            # Small plain decoded bodies, and requests with no body, complete
            # directly from the in-memory byte buffer.
            set body_descriptor [dict create body_media raw             \
                                             body_storage in_memory     \
                                             body      $body_data       \
                                             body_size $body_size]
        }
        set completed_descriptor [dict merge [my request_info_snapshot] \
                                             [dict create body_framing       $body_framing      \
                                                          transfer_codings   $transfer_codings  \
                                                          trailers           $trailers]         \
                                            $body_descriptor]
        set input_state complete
        return [my feed_result complete complete $completed_descriptor]
    }

    # Feed bytes into the chunked-body state machine.
    #
    # feed switches input_state to chunk_size after the header block has been
    # parsed and request_body_framing has classified the request as chunked.
    # From that point this method owns the RFC chunk framing:
    #
    #   chunk_buffer
    #       Accumulates bytes that have arrived from the connection but have
    #       not yet been consumed by the chunk parser.  It may contain a
    #       partial size line, partial chunk payload, the CRLF after a payload,
    #       trailers, or bytes following any of those boundaries.
    #
    #   chunk_remaining
    #       Number of payload bytes still expected for the current non-zero
    #       chunk.  Payload bytes are forwarded to append_transfer_data, which
    #       applies any transfer_stream decoding before append_body sees them.
    #
    #   trailers
    #       Header-like fields after the zero-size chunk.  They are retained in
    #       the completed descriptor but kept separate from request_headers
    #       because request routing/framing decisions were already made from
    #       the original header section.
    method feed_chunked {bytes} {
        append chunk_buffer $bytes
        while 1 {
            switch -exact -- $input_state {
                chunk_size {
                    # Read the hexadecimal chunk-size line.  Extensions after
                    # the size token are ignored, matching the non-incremental
                    # parser below.
                    set line_end [string first "\r\n" $chunk_buffer]
                    if {$line_end < 0} {
                        return [my feed_result need_more body]
                    }
                    set size_line [string range $chunk_buffer 0 $line_end-1]
                    set size_token [string trim [lindex [split $size_line ";"] 0]]
                    if {![regexp {^[0-9A-Fa-f]+$} $size_token] ||
                            [scan $size_token %x chunk_remaining] != 1} {
                        error "invalid chunk size"
                    }
                    set chunk_buffer [string range $chunk_buffer $line_end+2 end]
                    if {$chunk_remaining == 0} {
                        set input_state chunk_trailers
                    } else {
                        set input_state chunk_data
                    }
                }
                chunk_data {
                    # Forward available payload bytes.  Chunk framing itself is
                    # removed here; gzip transfer decoding, if configured, is
                    # performed by append_transfer_data.
                    set available [string length $chunk_buffer]
                    if {$available < $chunk_remaining} {
                        my append_transfer_data $chunk_buffer
                        incr chunk_remaining -$available
                        set chunk_buffer $::tclwire::constants::empty_bytearray
                        return [my feed_result need_more body]
                    }
                    if {$chunk_remaining > 0} {
                        my append_transfer_data [string range $chunk_buffer 0 $chunk_remaining-1]
                        set chunk_buffer        [string range $chunk_buffer $chunk_remaining end]
                    }
                    set chunk_remaining 0
                    set input_state chunk_data_crlf
                }
                chunk_data_crlf {
                    # Every non-final chunk payload is followed by CRLF before
                    # the next chunk-size line.
                    if {[string length $chunk_buffer] < 2} {
                        return [my feed_result need_more body]
                    }
                    if {[string range $chunk_buffer 0 1] ne "\r\n"} {
                        error "chunk data is not terminated by CRLF"
                    }
                    set chunk_buffer [string range $chunk_buffer 2 end]
                    set input_state chunk_size
                }
                chunk_trailers {
                    # The zero-size chunk has already ended the payload.  What
                    # follows is the trailer section: either an immediate CRLF
                    # for "no trailers", or field lines terminated by CRLFCRLF.
                    # Keep these fields separate from the header dictionary;
                    # applications can inspect them through HttpRequest, but
                    # they must not affect framing/routing decisions already
                    # made after the header section was parsed.
                    if {[string length $chunk_buffer] >= 2 &&
                        [string range $chunk_buffer 0 1] eq "\r\n"} {
                        set chunk_buffer [string range $chunk_buffer 2 end]
                        return [my finish_incremental_request]
                    }
                    set trailer_end [string first "\r\n\r\n" $chunk_buffer]
                    if {$trailer_end < 0} {
                        return [my feed_result need_more body]
                    }
                    set trailers [my parse_trailers [string range $chunk_buffer 0 $trailer_end-1]]
                    set chunk_buffer [string range $chunk_buffer $trailer_end+4 end]
                    return [my finish_incremental_request]
                }
            }
        }
    }

    # Incrementally feed request bytes from the connection.
    #
    # The method is a small state machine driven by input_state:
    #
    #   headers
    #       Accumulate bytes until CRLFCRLF, parse the request head, and derive
    #       the body-processing plan.
    #
    #   fixed_body
    #       Consume exactly Content-Length bytes into the decoded body pipeline.
    #
    #   chunk_size/chunk_data/chunk_data_crlf/chunk_trailers
    #       Delegate to feed_chunked, which removes chunk framing and collects
    #       trailers.
    #
    # The main parser descriptors established after headers are:
    #
    #   body_framing
    #       How the wire message body is delimited: none, content-length, or
    #       chunked.  This controls which input_state receives subsequent
    #       bytes and when the request is complete.
    #
    #   transfer_codings
    #       Ordered Transfer-Encoding codings from the headers, such as
    #       {gzip chunked}.  Chunked is framing and is removed by feed_chunked;
    #       gzip is content transformation and is represented by transfer_stream
    #       so append_transfer_data can produce decoded body bytes.
    #
    #   body_remaining
    #       For Content-Length requests, the number of wire body bytes still
    #       required before finish_incremental_request can be called.
    #
    #   declared_request_size
    #       Header size plus Content-Length.  It is reported before completion
    #       so the connection agent can reject oversized fixed-length requests
    #       without waiting for the whole body.

    method feed {bytes} {
        # Guard the completed/closed session boundary.
        if {$input_state in {complete aborted}} {
            error "HTTP protocol session is not accepting request data"
        }

        if {$input_state eq "headers"} {
            # Header phase: buffer until the full request head is available.
            # Any bytes after CRLFCRLF stay in the local bytes variable and are
            # processed by the selected body phase below in the same call.
            append header_buffer $bytes
            set header_end [string first "\r\n\r\n" $header_buffer]
            if {$header_end < 0} {
                set header_size [string length $header_buffer]
                return [my feed_result need_more headers]
            }
            set head [string range $header_buffer 0 $header_end-1]
            set header_size [expr $header_end + 4]
            set bytes [string range $header_buffer $header_end+4 end]
            set header_buffer {}

            # Request metadata phase: parse and cache the stable request head,
            # then derive the body parser configuration from its headers.
            my install_request_info [my parse_request_head $head]
            set headers [my request_headers]
            set body_framing [my request_body_framing $headers]
            set transfer_codings [my transfer_codings $headers]

            # Transfer decoding phase: chunked framing is handled by the parser
            # state machine.  gzip requires a streaming decoder because a
            # compressed stream can span chunk boundaries.
            if {$transfer_codings eq {gzip chunked}} {
                set transfer_stream [zlib stream gunzip]
            }

            # Body sink phase: multipart bodies are decomposed while bytes are
            # arriving; plain bodies use the in-memory/spooled-file path.
            my select_body_sink $headers

            # Framing phase: choose where the next byte belongs, or finish
            # immediately for requests without a body.
            switch -exact -- $body_framing {
                none { return [my finish_incremental_request] }
                content-length {
                    set body_remaining [dict get $headers content-length]
                    set declared_request_size [expr $header_end + 4 + $body_remaining]
                    set input_state fixed_body
                }
                chunked { set input_state chunk_size }
            }
        }

        if {$input_state eq "fixed_body"} {
            # Fixed-length body phase: consume only bytes belonging to this
            # request body.  The caller is responsible for connection-level
            # request sequencing; this session returns complete as soon as the
            # declared body length has been reached.
            set take [expr {min($body_remaining, [string length $bytes])}]
            if {$take > 0} {
                my append_body [string range $bytes 0 $take-1]
                incr body_remaining -$take
            }
            if {$body_remaining == 0} { return [my finish_incremental_request] }
            return [my feed_result need_more body]
        }

        # Chunked body phase: the finer-grained chunk states are handled there.
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

        set header_block [string range $request 0 $header_end-1]
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
        set decoded $::tclwire::constants::empty_bytearray
        set cursor 0

        while 1 {
            set line_end [string first "\r\n" $body $cursor]
            if {$line_end < 0} {
                return [dict create complete 0]
            }

            set size_line [string range $body $cursor $line_end-1]
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
                if {[string range $body $data_start $data_start+1] eq "\r\n"} {
                    return [dict create complete 1 \
                                        body     $decoded \
                                        trailers {} \
                                        consumed_length [expr {$data_start + 2}]]
                }

                set trailer_end [string first "\r\n\r\n" $body $data_start]
                if {$trailer_end < 0} {
                    return [dict create complete 0]
                }
                set trailer_block [string range $body $data_start $trailer_end-1]
                return [dict create complete    1 \
                                    body        $decoded \
                                    trailers    [my parse_trailers $trailer_block] \
                                    consumed_length [expr {$trailer_end + 4}]]
            }

            set data_end [expr {$data_start + $chunk_size}]
            if {[string length $body] < $data_end + 2} {
                return [dict create complete 0]
            }
            if {[string range $body $data_end $data_end+1] ne "\r\n"} {
                error "chunk data is not terminated by CRLF"
            }

            append decoded [string range $body $data_start $data_end-1]
            set cursor [expr {$data_end + 2}]
        }
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
            set path [string range $target 0 $query_start-1]
            set query [string range $target $query_start+1 end]
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
                [string range $request $header_end+4 end]]
            if {![dict get $chunk_info complete]} {
                error "chunked HTTP request body is incomplete"
            }
            set body [my decode_transfer_codings \
                [dict get $chunk_info body] $codings]
            set trailers [dict get $chunk_info trailers]
        } else {
            set body [string range $request $header_end+4 end]
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
                            body_media  raw         \
                            body_storage in_memory  \
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

    method build_chunked_response_head { status reason content_encoding headers body_mode } {
        set response_headers [list  "HTTP/1.1 $status $reason"  \
                                    "Connection: close"         \
                                    "Transfer-Encoding: chunked"]
        foreach header $headers {
            if {[regexp -nocase {^(Content-Length|Transfer-Encoding):} $header]} {
                continue
            }
            lappend response_headers $header
        }
        return [encoding convertto ascii "[join $response_headers "\r\n"]\r\n\r\n"]
    }

    method chunk_frame {body_bytes} {
        if {$body_bytes eq {}} {
            return {}
        }
        set frame [encoding convertto ascii "[format %X [string length $body_bytes]]\r\n"]
        append frame $body_bytes "\r\n"
        return $frame
    }

    method chunk_terminator {} {
        return [encoding convertto ascii "0\r\n\r\n"]
    }

    export request_body_framing
    unexport decode_transfer_codings feed_result install_request_info \
        parse_chunked_body parse_trailers request_headers request_info_snapshot \
        request_method transfer_codings
}

package provide tclwire::http::protocol 0.1
