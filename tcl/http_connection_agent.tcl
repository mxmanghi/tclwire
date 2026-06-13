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

    variable protocol_session application_dispatcher closed channel
    variable next_transaction_id default_encoding log_protocol

    constructor {conn_channel id host port args} {
        array set options {
            -applicationconfig {}
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

        next $conn_channel $id $host $port
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
            my send_error 400
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

    method handle_request {request_data} {
        if {[catch {
            set request_d [my build_request_descriptor $request_data]
        }]} {
            my log_request {} 400 0
            my send_error 400
            return {}
        }

        set transaction_id [incr next_transaction_id]
        dict set request_d transaction_id $transaction_id
        dict set request_d connection_thread_id [::thread::id]
        dict set request_d connection_agent_id [self]
        dict set request_d response_body {}
        dict set request_d response_status 200
        dict set request_d response_reason OK
        dict set request_d response_headers {}
        dict set request_d response_body_mode text
        dict set request_d output_sequence 0
        my begin_transaction $transaction_id $request_d
        if {[catch {
            set dispatch_info [$application_dispatcher dispatch $request_d]
        } message]} {
            my finish_transaction $transaction_id
            if {[string match "no application is configured for Host *" $message]} {
                my log_request $request_d 404 0
                my send_error 404 [dict create path [dict get $request_d path]]
            } else {
                my log_request $request_d 503 0
                my send_error 503
            }
            return {}
        }
        dict set request_d application_id \
            [dict get $dispatch_info application_id]
        dict set request_d application_pool_key \
            [dict get $dispatch_info pool_key]
        dict set request_d response_encoding \
            [dict get $dispatch_info encoding]
        my update_transaction $transaction_id $request_d
        return $request_d
    }

    method application_output {transaction_id event} {
        set descriptor [my transaction_for $transaction_id]
        if {$descriptor eq {}} {
            return
        }

        set expected [expr {[dict get $descriptor output_sequence] + 1}]
        if {[dict get $event output_sequence] != $expected} {
            my finish_transaction $transaction_id
            my send_error 500
            return
        }
        dict set descriptor output_sequence $expected

        switch -exact -- [dict get $event type] {
            response {
                if {[dict get $descriptor response_body] ne {}} {
                    my finish_transaction $transaction_id
                    my send_error 500
                    return
                }
                set flags [dict get $event flags]
                foreach field {status reason headers body_mode} {
                    dict set descriptor response_$field [dict get $flags $field]
                }
                if {[dict get $flags encoding] ne {}} {
                    dict set descriptor response_encoding \
                        [dict get $flags encoding]
                }
                my update_transaction $transaction_id $descriptor
            }
            output {
                set body_mode [dict get $descriptor response_body_mode]
                if {[dict exists $event flags body_mode]} {
                    set body_mode [dict get $event flags body_mode]
                }
                if {$body_mode ne [dict get $descriptor response_body_mode]} {
                    my finish_transaction $transaction_id
                    my send_error 500
                    return
                }
                dict append descriptor response_body [dict get $event data]
                my update_transaction $transaction_id $descriptor
            }
            flush {
                my update_transaction $transaction_id $descriptor
            }
            complete {
                set body [dict get $descriptor response_body]
                set content_encoding [dict get $descriptor response_encoding]
                set status [dict get $descriptor response_status]
                set reason [dict get $descriptor response_reason]
                set headers [dict get $descriptor response_headers]
                set body_mode [dict get $descriptor response_body_mode]
                my finish_transaction $transaction_id
                set response [$protocol_session build_response \
                    $status $reason $body $content_encoding $headers $body_mode]
                if {$body_mode eq "binary"} {
                    set body_bytes [string length $body]
                } else {
                    set body_bytes [string length \
                        [encoding convertto $content_encoding $body]]
                }
                my log_request $descriptor $status $body_bytes
                my write_and_close $response
            }
            error {
                my finish_transaction $transaction_id
                my send_error 500
            }
            default {
                my finish_transaction $transaction_id
                my send_error 500
            }
        }
        return
    }

    method send_error {status {context {}}} {
        set error_response [::tclwire::http::errors response $status $context]
        set response [$protocol_session build_response \
            [dict get $error_response status] \
            [dict get $error_response reason] \
            [dict get $error_response body] \
            $default_encoding \
            [dict get $error_response headers]]
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

    unexport log_request
}

package provide tclwire::http::connection_agent 0.1
