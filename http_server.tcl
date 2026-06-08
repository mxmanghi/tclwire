# http_server.tcl -- Implementation of a simple HTTP server 
#
# HTTP server support for TclWire.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclwire {}

package require Thread

if {[info commands ::tclwire::http_endpoint_service] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_endpoint.tcl]
}
if {[info commands ::tclwire::CApplication] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_application.tcl]
}
if {[info commands ::tclwire::CTestApplication] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_test_support.tcl]
    source [file join [file dirname [file normalize [info script]]] http_test_application.tcl]
}

# HTTP origin service used by the tests. The shared base handles connection
# lifecycle and buffering; this class adds origin-specific request framing,
# and transport-specific response generation.
oo::class create ::tclwire::http_service {
    superclass ::tclwire::http_endpoint_service
    variable application connection_ids

    constructor args {
        set application_class ::tclwire::CApplication
        set service_args {}
        array set connection_ids {}

        foreach {name value} $args {
            if {$name eq "-applicationclass"} {
                set application_class $value
                continue
            }
            lappend service_args $name $value
        }

        next {*}$service_args
        set application [$application_class new]
        my apply_service_config
    }

    destructor {
        if {[info exists application] && $application ne {}} {
            catch {$application destroy}
        }
        next
    }

    method application {} {
        return $application
    }

    method apply_service_config {} {
        set config [my service_config]
        if {[dict exists $config docroot] && [dict get $config docroot] ne {}} {
            $application set_doc_root [dict get $config docroot]
        }
    }

    method description {} {
        return "HTTP origin test server"
    }

    method accept {chan host port} {
        after idle [list [self] dispatch_accept $chan $host $port]
    }

    method dispatch_accept {chan host port} {
        set thread_master [my thread_master]
        if {$thread_master eq {}} {
            ::tclwire::msgoutput "no thread master available for chan=$chan"
            catch {close $chan}
            return
        }

        set worker_thread_id [$thread_master acquire_worker]
        if {$worker_thread_id eq {}} {
            ::tclwire::msgoutput "no idle worker available for chan=$chan"
            catch {close $chan}
            return
        }

        set connection_id [::tclwire::record_connection_opened \
            [my protocol] $chan $host $port [my endpoint] $worker_thread_id]

        if {[catch {thread::transfer $worker_thread_id $chan} transfer_error]} {
            ::tclwire::record_connection_closed $connection_id $transfer_error
            ::tclwire::msgoutput "channel transfer failed chan=$chan worker=$worker_thread_id error=$transfer_error"
            catch {$thread_master return_thread $worker_thread_id}
            catch {close $chan}
            return
        }

        set config [my service_config]
        dict set config protocol [my protocol]
        dict set config connection_class [my connection_class]
        dict set config secure [my secure]
        dict set config host [my host]
        dict set config port [my port]
        ::tclwire::msgoutput "dispatch connection id=$connection_id chan=$chan worker=$worker_thread_id"
        thread::send -async $worker_thread_id \
            [list ::tclwire::serve_transferred_http_connection $chan $connection_id $config]
    }

    method serve_connection {chan connection_id} {
        ::tclwire::msgoutput "worker serve connection id=$connection_id chan=$chan"
        set connection_ids($chan) $connection_id
        chan configure $chan -blocking 0 -buffering none -translation binary
        chan event $chan readable [list [self] read_request $chan]
        after idle [list [self] read_request_if_open $chan]
    }

    # Origin tests also exercise chunked uploads, so request completion needs
    # to understand both fixed-size and chunked request bodies.
    method complete_request {request_data} {
        set header_end [string first "\r\n\r\n" $request_data]
        if {$header_end < 0} { return {} }

        set headers [[my application] parse_headers $request_data]
        if {[string tolower [my header_value $headers transfer-encoding]] eq "chunked"} {
            return [my complete_chunked_request $request_data $header_end]
        }

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

    method complete_chunked_request {request_data header_end} {
        set chunk_data [string range $request_data [expr {$header_end + 4}] end]
        set chunk_info [my parse_chunked_body $chunk_data]
        if {![dict get $chunk_info complete]} {
            return {}
        }

        set request_end [expr {$header_end + 4 + [dict get $chunk_info consumed_length] - 1}]
        return [string range $request_data 0 $request_end]
    }

    # Build the standard origin-server reply for malformed HTTP requests.
    method bad_request_response {} {
        return [my build_response_dict [my error_response 400]]
    }

    # Delegate the fully buffered request to the configured application. This
    # is the synchronous placeholder for the future worker-thread handoff.
    method handle_request {chan request} {
        if {[info commands ::tclwire::accounting] ne {}} {
            set headers [[my application] parse_headers $request]
            set http_host {}
            if {[dict exists $headers host]} {
                set http_host [dict get $headers host]
            }
            catch {
                ::tclwire::accounting set_thread_http_host \
                    [thread::id] $http_host
            }
        }
        [my application] service_request [self] $chan $request
    }

    method log_request {message} {
        if {[info exists ::master_thread_id] && $::master_thread_id ne {}} {
            thread::send -async $::master_thread_id \
                [list ::tclwire::log_from_worker [my protocol] $message]
            return
        }
        next $message
    }

    method close_client {chan {error {}}} {
        set connection_id {}
        if {[info exists connection_ids($chan)]} {
            set connection_id $connection_ids($chan)
            unset connection_ids($chan)
        }

        next $chan $error

        if {$connection_id ne {} && [info exists ::master_thread_id] && $::master_thread_id ne {}} {
            thread::send -async $::master_thread_id \
                [list ::tclwire::record_connection_closed $connection_id $error]
        }

        if {[info commands ::tclwire::accounting] ne {}} {
            catch {::tclwire::accounting change_thread_status [thread::id] idle}
        }
    }

    method decode_chunked_body {body} {
        return [dict get [my parse_chunked_body $body] decoded_body]
    }

    method parse_chunked_body {body} {
        set decoded {}
        set cursor 0

        # Some clients can send an empty chunked POST without an explicit
        # terminating zero-size chunk.
        if {$body eq {}} {
            return [dict create complete 1 decoded_body {} consumed_length 0]
        }

        while 1 {
            set line_end [string first "\r\n" $body $cursor]
            if {$line_end < 0} {
                return [dict create complete 0 decoded_body {} consumed_length 0]
            }

            set size_line [string trim [string range $body $cursor [expr {$line_end - 1}]]]
            set size_token [lindex [split $size_line ";"] 0]
            if {[scan $size_token %x chunk_size] != 1} {
                return [dict create complete 0 decoded_body {} consumed_length 0]
            }

            set data_start [expr {$line_end + 2}]
            if {$chunk_size == 0} {
                if {[string range $body $data_start [expr {$data_start + 1}]] eq "\r\n"} {
                    return [dict create \
                        complete 1 \
                        decoded_body $decoded \
                        consumed_length [expr {$data_start + 2}]]
                }

                set trailer_end [string first "\r\n\r\n" $body $data_start]
                if {$trailer_end < 0} {
                    return [dict create complete 0 decoded_body {} consumed_length 0]
                }

                return [dict create complete 1 \
                                    decoded_body $decoded \
                                    consumed_length [expr {$trailer_end + 4}]]
            }

            set data_end [expr {$data_start + $chunk_size}]
            if {[string length $body] < ($data_end + 2)} {
                return [dict create complete 0 decoded_body {} consumed_length 0]
            }
            if {[string range $body $data_end [expr {$data_end + 1}]] ne "\r\n"} {
                return [dict create complete 0 decoded_body {} consumed_length 0]
            }

            append decoded [string range $body $data_start [expr {$data_end - 1}]]
            set cursor [expr {$data_end + 2}]
        }
    }

    method header_value {headers name} {
        if {[dict exists $headers $name]} {
            return [dict get $headers $name]
        }
        return {}
    }

    method chunk_encode {body {chunk_size 16}} {
        set encoded {}
        set body_length [string length $body]
        for {set offset 0} {$offset < $body_length} {incr offset $chunk_size} {
            set chunk [string range $body $offset [expr {$offset + $chunk_size - 1}]]
            append encoded [my chunk_frame $chunk]
        }
        append encoded [my chunk_terminator]
        return $encoded
    }

    method chunk_frame {chunk_data} {
        return [format %X [string length $chunk_data]]\r\n$chunk_data\r\n
    }

    method chunk_terminator {} {
        return "0\r\n\r\n"
    }

    method streaming_payload_length {stream_chunks} {
        set total 0
        foreach stream_chunk $stream_chunks {
            lassign $stream_chunk delay_ms chunk_data
            incr total [string length $chunk_data]
        }
        return $total
    }

    method stream_response_body {chan response_headers head_only transfer_encoding stream_chunks} {
        if {[catch {
            puts -nonewline $chan [join $response_headers "\r\n"]
            puts -nonewline $chan "\r\n\r\n"
            flush $chan
        } write_error]} {
            ::tclwire::msgoutput "response write failed chan=$chan error=$write_error"
            my close_client $chan
            return
        }

        if {$head_only} {
            my close_client $chan
            return
        }

        my send_stream_chunk $chan $transfer_encoding $stream_chunks 0
    }

    method send_stream_chunk {chan transfer_encoding stream_chunks index} {
        if {$index >= [llength $stream_chunks]} {
            if {$transfer_encoding eq "chunked"} {
                if {[catch {
                    puts -nonewline $chan [my chunk_terminator]
                    flush $chan
                } write_error]} {
                    ::tclwire::msgoutput "stream write failed chan=$chan error=$write_error"
                }
            }
            my close_client $chan
            return
        }

        lassign [lindex $stream_chunks $index] delay_ms chunk_data
        after $delay_ms [list [self] write_stream_chunk $chan $transfer_encoding $stream_chunks $index $chunk_data]
    }

    method write_stream_chunk {chan transfer_encoding stream_chunks index chunk_data} {
        if {[catch {
            if {$transfer_encoding eq "chunked"} {
                puts -nonewline $chan [my chunk_frame $chunk_data]
            } else {
                puts -nonewline $chan $chunk_data
            }
            flush $chan
        } write_error]} {
            ::tclwire::msgoutput "stream write failed chan=$chan error=$write_error"
            my close_client $chan
            return
        }

        my send_stream_chunk $chan $transfer_encoding $stream_chunks [expr {$index + 1}]
    }

    # Normalize partially specified route results into a complete response
    # dictionary so sending code can follow one path.
    method build_response_dict {response} {
        set completed_response [dict create status              200 \
                                            reason              OK  \
                                            body                {}  \
                                            head_only           0   \
                                            headers             {}  \
                                            status_line         {}  \
                                            transfer_encoding   {}  \
                                            stream_chunks       {}]

        dict for {key value} $response {
            dict set completed_response $key $value
        }

        return $completed_response
    }

    # Serialize a normalized response dictionary to the client socket, handling
    # HEAD requests, chunked transfers and delayed streaming responses.
    method send_response {chan response} {
        dict with response {}
        if {$status_line eq {}} {
            set status_line "HTTP/1.1 $status $reason"
        }

        ::tclwire::msgoutput "send response chan=$chan status=$status reason=$reason body-length=[string length $body]"

        set response_headers [list $status_line "Connection: close"]
        if {![regexp -nocase {^Content-Type:} [join $headers "\n"]]} {
            lappend response_headers "Content-Type: text/plain"
        }
        if {$transfer_encoding eq "chunked"} {
            lappend response_headers "Transfer-Encoding: chunked"
        } elseif {[llength $stream_chunks] > 0} {
            lappend response_headers "Content-Length: [my streaming_payload_length $stream_chunks]"
        } else {
            lappend response_headers "Content-Length: [string length $body]"
        }
        set response_headers [concat $response_headers $headers]

        if {[llength $stream_chunks] > 0} {
            my stream_response_body $chan $response_headers $head_only $transfer_encoding $stream_chunks
            return
        }

        if {[catch {
            puts -nonewline $chan [join $response_headers "\r\n"]
            puts -nonewline $chan "\r\n\r\n"
            if {!$head_only} {
                if {$transfer_encoding eq "chunked"} {
                    puts -nonewline $chan [my chunk_encode $body]
                } else {
                    puts -nonewline $chan $body
                }
            }
            flush $chan
        } write_error]} {
            ::tclwire::msgoutput "response write failed chan=$chan error=$write_error"
            my close_client $chan
            return
        }
        my close_client $chan
    }

}

if {[info commands ::tclwire::register_service_class] ne {}} {
    ::tclwire::register_service_class http ::tclwire::http_service
}
