# http_connection_agent.tcl --
#
# HTTP specialization of the protocol-independent ConnectionAgent.

package require TclOO
package require tclwire::connection_agent 0.1
package require tclwire::http::protocol 0.1
package require tclwire::http::errors 0.1
package require tclwire::application_dispatcher 0.1
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpConnectionAgent {
    superclass ::tclwire::ConnectionAgent

    variable protocol_session application_dispatcher closed channel connection_key
    variable next_transaction_id default_encoding log_protocol

    constructor {conn_channel id host port args} {
        array set options {
            -applicationconfig {}
            -connectionkey {}
            -protocol http
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        if {$options(-applicationconfig) eq {}} {
            error "HTTP connection agent requires application configuration"
        }
        if {$options(-connectionkey) eq {}} {
            error "HTTP connection agent requires connection key"
        }

        next $conn_channel $id $host $port $options(-connectionkey)
        set protocol_session [::tclwire::HttpProtocolSession new]
        set application_dispatcher \
            [::tclwire::ApplicationDispatcher new $options(-applicationconfig)]
        set default_application [dict get $options(-applicationconfig) default_application]
        set default_encoding [dict get [$application_dispatcher application $default_application] encoding]
        set log_protocol $options(-protocol)
        set next_transaction_id 0
        my start
    }

    destructor {
        catch {$application_dispatcher destroy}
        catch {$protocol_session destroy}
        next
    }

    method readable {} {
        set chunk [my read_available]
        if {$chunk eq {} || $closed} {
            return
        }

        if {[catch {
            set request_data [my request_complete [my input_buffer]]
        }]} {
            my send_error 400 {} [my request_is_head [my input_buffer]]
            return
        }
        if {$request_data eq {}} {
            return
        }

        chan event $channel readable {}
        my handle_request $request_data
    }

    method request_complete {request_data} {
        return [$protocol_session complete_request $request_data]
    }

    method build_request_descriptor {request_data} {
        set descriptor [$protocol_session parse_request $request_data]
        set peer [my peer]
        dict set descriptor connection_id [my connection_id]
        dict set descriptor remote_host [dict get $peer host]
        dict set descriptor remote_port [dict get $peer port]
        return $descriptor
    }

    method request_body {request_descriptor} {
        if {[dict get $request_descriptor body_mode] ne "in_memory"} {
            error "request body is not stored in memory"
        }
        return [dict get $request_descriptor body]
    }

    method request_is_head {request_data} {
        return [regexp {^HEAD[ \t]} $request_data]
    }

    method request_host {request_descriptor} {
        if {![dict exists $request_descriptor headers host]} {
            return {}
        }
        set host [string tolower \
            [string trim [dict get $request_descriptor headers host]]]
        if {[regexp {^\[([^\]]+)\](?::[0-9]+)?$} $host -> address]} {
            return $address
        }
        regsub {:[0-9]+$} $host {} host
        return $host
    }

    method handle_request {request_data} {
        if {[catch {
            set request_d [my build_request_descriptor $request_data]
        }]} {
            my log_request {} 400 0
            my send_error 400 {} [my request_is_head $request_data]
            return {}
        }
        catch {
            ::tclwire::accounting set_thread_http_host \
                [::thread::id] [my request_host $request_d]
        }

        set transaction_id [incr next_transaction_id]
        dict set request_d transaction_id       $transaction_id
        dict set request_d connection_thread_id [::thread::id]
        dict set request_d connection_agent_id  [self]
        catch {
            ::tclwire::accounting increment_connection_request_count \
                $connection_key \
                [dict create \
                    current_transaction_id $transaction_id \
                    current_command [dict get $request_d method]]
        }

        my begin_transaction $transaction_id $request_d
        set transaction [my transaction_for $transaction_id]
        $transaction set response_body      {}
        $transaction set response_status    200
        $transaction set response_reason    OK
        $transaction set response_headers   {}
        $transaction set response_body_mode text
        $transaction set response_state     preparing
        $transaction set response_bytes     0
        $transaction set output_sequence    0
        if {[catch {
            set dispatch_info [$application_dispatcher dispatch [$transaction snapshot]]
        } message]} {
            set request_d [my finish_transaction $transaction_id]
            if {[string match "no application is configured for Host *" $message]} {
                my log_request $request_d 404 0
                my send_error 404 [dict create path [dict get $request_d path]] \
                                  [my head_only $request_d]
            } else {
                my log_request $request_d 503 0
                my send_error 503 {} [my head_only $request_d]
            }
            return {}
        }
        $transaction set application_id       [dict get $dispatch_info application_id]
        $transaction set application_pool_key [dict get $dispatch_info pool_key]
        $transaction set response_encoding    [dict get $dispatch_info encoding]
        return [$transaction snapshot]
    }

    method header_name {header} {
        if {![regexp {^([^:]+):} $header -> name]} {
            error "invalid HTTP response header"
        }
        return [string trim $name]
    }

    method header_value {header} {
        if {![regexp {^[^:]+:\s*(.*)$} $header -> value]} {
            error "invalid HTTP response header"
        }
        return $value
    }

    method response_header_values {transaction name} {
        set values {}
        foreach header [$transaction get response_headers] {
            if {[string equal -nocase [my header_name $header] $name]} {
                lappend values [my header_value $header]
            }
        }
        return $values
    }

    method chunked_response {transaction} {
        set values [my response_header_values $transaction Transfer-Encoding]
        if {[llength $values] == 0} {
            return 0
        }
        if {[llength $values] != 1 ||
                ![string equal -nocase [string trim [lindex $values 0]] chunked]} {
            error "unsupported response Transfer-Encoding"
        }
        if {[llength [my response_header_values \
                $transaction Content-Length]] > 0} {
            error "response contains both Transfer-Encoding and Content-Length"
        }
        if {[$transaction get version] ne "1.1"} {
            error "chunked responses require HTTP/1.1"
        }
        return 1
    }

    method head_only {request_state} {
        if {[info object isa typeof \
                $request_state ::tclwire::TransactionDescriptor]} {
            set method [$request_state get method]
        } else {
            set method [dict get $request_state method]
        }
        return [expr {$method eq "HEAD"}]
    }

    method apply_header_event {transaction flags} {
        if {[$transaction get response_state] ne "preparing"} {
            error "HTTP response headers have already been sent"
        }

        set action [dict get $flags action]
        set name [dict get $flags name]
        set value {}
        if {[dict exists $flags value]} {
            set value [dict get $flags value]
        }
        if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name] ||
                [string first "\r" $value] >= 0 ||
                [string first "\n" $value] >= 0} {
            error "invalid HTTP response header"
        }

        set headers {}
        foreach header [$transaction get response_headers] {
            if {$action in {set remove} &&
                    [string equal -nocase [my header_name $header] $name]} {
                continue
            }
            lappend headers $header
        }
        switch -exact -- $action {
            set -
            add {
                lappend headers "$name: $value"
            }
            remove {}
            default {
                error "unknown HTTP header operation: $action"
            }
        }
        $transaction set response_headers $headers
        my chunked_response $transaction
        return
    }

    method commit_chunked_response {transaction} {
        if {[$transaction get response_state] eq "committed"} {
            return
        }
        if {![my chunked_response $transaction]} {
            error "response is not configured for chunked transfer"
        }
        set response_head [$protocol_session build_chunked_response_head \
            [$transaction get response_status] \
            [$transaction get response_reason] \
            [$transaction get response_encoding] \
            [$transaction get response_headers] \
            [$transaction get response_body_mode]]
        if {![my write_output $response_head]} {
            error "failed to write HTTP response headers"
        }
        $transaction set response_state committed
        return
    }

    method abort_application_response {transaction_id transaction} {
        set response_state [$transaction get response_state]
        set head_only [my head_only $transaction]
        my finish_transaction $transaction_id
        if {$response_state eq "preparing"} {
            my send_error 500 {} $head_only
        } else {
            my close
        }
        return
    }

    method application_output {transaction_id event} {
        set transaction [my transaction_for $transaction_id]
        if {$transaction eq {}} {
            return
        }

        set expected [expr {[$transaction get output_sequence] + 1}]
        if {[dict get $event output_sequence] != $expected} {
            set head_only [my head_only $transaction]
            my finish_transaction $transaction_id
            my send_error 500 {} $head_only
            return
        }
        $transaction set output_sequence $expected

        switch -exact -- [dict get $event type] {
            response {
                if {[$transaction get response_state] ne "preparing" ||
                        [$transaction get response_body] ne {}} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
                set flags [dict get $event flags]
                foreach field {status reason headers body_mode} {
                    $transaction set response_$field [dict get $flags $field]
                }
                if {[dict get $flags encoding] ne {}} {
                    $transaction set response_encoding \
                        [dict get $flags encoding]
                }
                if {[catch {my chunked_response $transaction}]} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
            }
            http_header {
                if {[catch {
                    my apply_header_event $transaction [dict get $event flags]
                }]} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
            }
            output {
                set body_mode [$transaction get response_body_mode]
                if {[dict exists $event flags body_mode]} {
                    set body_mode [dict get $event flags body_mode]
                }
                if {$body_mode ne [$transaction get response_body_mode]} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
                if {[catch {set chunked [my chunked_response $transaction]}]} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
                if {$chunked} {
                    if {[catch {
                        my commit_chunked_response $transaction
                        if {![my head_only $transaction]} {
                            set body_bytes [$protocol_session encode_response_body \
                                [dict get $event data] \
                                [$transaction get response_encoding] \
                                $body_mode]
                            set frame [$protocol_session chunk_frame $body_bytes]
                            if {$frame ne {} && ![my write_output $frame]} {
                                error "failed to write HTTP response chunk"
                            }
                        }
                    }]} {
                        my abort_application_response $transaction_id $transaction
                        return
                    }
                    if {![my head_only $transaction]} {
                        $transaction incr response_bytes [string length $body_bytes]
                    }
                } else {
                    $transaction append response_body [dict get $event data]
                }
            }
            no_body {
                if {[$transaction get response_bytes] > 0} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
                set response_headers {}
                foreach response_header [$transaction get response_headers] {
                    if {![string equal -nocase \
                            [my header_name $response_header] Content-Length]} {
                        lappend response_headers $response_header
                    }
                }
                $transaction set response_headers $response_headers
                $transaction set response_body {}
            }
            flush {
                if {[catch {set chunked [my chunked_response $transaction]}]} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
                if {$chunked} {
                    if {[catch {
                        my commit_chunked_response $transaction
                        if {![my write_output {} 1]} {
                            error "failed to flush HTTP response"
                        }
                    }]} {
                        my abort_application_response $transaction_id $transaction
                        return
                    }
                }
            }
            complete {
                if {[catch {set chunked [my chunked_response $transaction]}]} {
                    my abort_application_response $transaction_id $transaction
                    return
                }
                if {$chunked} {
                    if {[catch {
                        my commit_chunked_response $transaction
                        if {[my head_only $transaction]} {
                            if {![my write_output {} 1]} {
                                error "failed to complete HTTP HEAD response"
                            }
                        } elseif {![my write_output \
                                [$protocol_session chunk_terminator] 1]} {
                            error "failed to terminate HTTP chunks"
                        }
                    }]} {
                        my abort_application_response $transaction_id $transaction
                        return
                    }
                    $transaction set response_state complete
                    set descriptor [my finish_transaction $transaction_id]
                    catch {
                        ::tclwire::accounting update_connection $connection_key \
                            [dict create current_transaction_id {} \
                                         current_command {}]
                    }
                    my log_request $descriptor \
                        [dict get $descriptor response_status] \
                        [dict get $descriptor response_bytes]
                    my close
                    return
                }
                set body [$transaction get response_body]
                set content_encoding [$transaction get response_encoding]
                set status [$transaction get response_status]
                set reason [$transaction get response_reason]
                set headers [$transaction get response_headers]
                set body_mode [$transaction get response_body_mode]
                set head_only [my head_only $transaction]
                set descriptor [my finish_transaction $transaction_id]
                catch {
                    ::tclwire::accounting update_connection $connection_key \
                        [dict create current_transaction_id {} \
                                     current_command {}]
                }
                set response [$protocol_session build_response \
                    $status $reason $body $content_encoding $headers $body_mode \
                    $head_only]
                if {$head_only} {
                    set body_bytes 0
                } elseif {$body_mode eq "binary"} {
                    set body_bytes [string length $body]
                } else {
                    set body_bytes [string length \
                        [encoding convertto $content_encoding $body]]
                }
                my log_request $descriptor $status $body_bytes
                my write_and_close $response
            }
            error {
                my abort_application_response $transaction_id $transaction
            }
            default {
                my abort_application_response $transaction_id $transaction
            }
        }
        return
    }

    method send_error {status {context {}} {head_only 0}} {
        set error_response [::tclwire::http::errors response $status $context]
        set response [$protocol_session build_response \
            [dict get $error_response status] \
            [dict get $error_response reason] \
            [dict get $error_response body] \
            [dict get $error_response encoding] \
            [dict get $error_response headers] \
            [dict get $error_response body_mode] \
            $head_only]
        my write_and_close $response
    }

    method log_request {descriptor status bytes} {
        set method ?
        set path ?
        set remote_host [dict get [my peer] host]
        if {$descriptor ne {}} {
            foreach field {method path remote_host} {
                if {[dict exists $descriptor $field]} {
                    set $field [dict get $descriptor $field]
                }
            }
        }
        catch {
            ::tclwire::logger log $log_protocol [join \
                [list "method=[::tclwire::logger log_value $method]"  \
                      "path=[::tclwire::logger log_value $path]"      \
                      "status=$status" \
                      "bytes=$bytes"   \
                      "remote=[::tclwire::logger log_value $remote_host]"] " "]
        }
        return
    }

    method request_info {} {
        return [my active_transaction]
    }

    unexport abort_application_response apply_header_event \
        chunked_response commit_chunked_response head_only header_name header_value \
        log_request request_host request_is_head response_header_values
}

package provide tclwire::http::connection_agent 0.1
