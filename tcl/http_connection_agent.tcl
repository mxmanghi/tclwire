# http_connection_agent.tcl --
#
# HTTP specialization of the protocol-independent ConnectionAgent.

package require TclOO
package require tclwire::connection_agent 0.1
package require tclwire::http::protocol 0.1
package require tclwire::http::errors 0.1
package require tclwire::application_dispatcher 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpConnectionAgent {
    superclass ::tclwire::ConnectionAgent

    variable protocol_session application_dispatcher closed channel
    variable next_transaction_id

    constructor {conn_channel id host port args} {
        array set options {
            -applicationconfig {}
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
            set descriptor [my build_request_descriptor $request_data]
        }]} {
            my send_error 400
            return {}
        }

        set transaction_id [incr next_transaction_id]
        dict set descriptor transaction_id $transaction_id
        dict set descriptor connection_thread_id [::thread::id]
        dict set descriptor connection_agent_id [self]
        dict set descriptor response_body {}
        dict set descriptor output_sequence 0
        my begin_transaction $transaction_id $descriptor
        if {[catch {
            set dispatch_info [$application_dispatcher dispatch $descriptor]
        } message]} {
            my finish_transaction $transaction_id
            if {[string match "no application is configured for Host *" $message]} {
                my send_error 404 [dict create path [dict get $descriptor path]]
            } else {
                my send_error 503
            }
            return {}
        }
        dict set descriptor application_id \
            [dict get $dispatch_info application_id]
        dict set descriptor application_pool_key \
            [dict get $dispatch_info pool_key]
        my update_transaction $transaction_id $descriptor
        return $descriptor
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
            output {
                dict append descriptor response_body [dict get $event data]
                my update_transaction $transaction_id $descriptor
            }
            flush {
                my update_transaction $transaction_id $descriptor
            }
            complete {
                set body [dict get $descriptor response_body]
                my finish_transaction $transaction_id
                set response [$protocol_session build_response 200 OK $body]
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
            [dict get $error_response headers]]
        my write_and_close $response
    }

    method request_info {} {
        return [my active_transaction]
    }
}

package provide tclwire::http::connection_agent 0.1
