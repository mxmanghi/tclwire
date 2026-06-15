# application_io.tcl --
#
# Transaction-scoped output bridge used by Content Generator Agents.

package require Thread

namespace eval ::tclwire {}

namespace eval ::tclwire::io {
    variable active 0
    variable response_state inactive
    variable connection_thread_id {}
    variable connection_agent_id {}
    variable transaction_id {}
    variable output_sequence 0
    variable output_buffer {}
    variable output_body_mode {}

    proc begin {thread_id agent_id tx_id} {
        variable active
        variable response_state
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence
        variable output_buffer
        variable output_body_mode

        if {$active} {
            error "an application output transaction is already active"
        }
        set connection_thread_id $thread_id
        set connection_agent_id $agent_id
        set transaction_id $tx_id
        set output_sequence 0
        set output_buffer [binary format a* {}]
        set output_body_mode {}
        set response_state open
        set active 1
        return
    }

    proc end {} {
        variable active
        variable response_state
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence
        variable output_buffer
        variable output_body_mode

        set active 0
        set response_state inactive
        set connection_thread_id {}
        set connection_agent_id {}
        set transaction_id {}
        set output_sequence 0
        set output_buffer [binary format a* {}]
        set output_body_mode {}
        return
    }

    proc context {} {
        variable active
        variable response_state
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id

        return [dict create \
            active $active \
            response_state $response_state \
            connection_thread_id $connection_thread_id \
            connection_agent_id $connection_agent_id \
            transaction_id $transaction_id]
    }

    proc send_event {type {data {}} {flags {}}} {
        variable active
        variable response_state
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence

        if {!$active} {
            error "no application output transaction is active"
        }
        if {$response_state ne "open"} {
            return {}
        }
        if {![::thread::exists $connection_thread_id]} {
            error "connection-agent thread is no longer available"
        }

        set event [dict create  type            $type \
                                transaction_id  $transaction_id \
                                output_sequence [incr output_sequence] \
                                stream          stdout \
                                data            $data \
                                flags           $flags]

        ::thread::send -async $connection_thread_id \
                [list ::tclwire::route_application_output   $connection_agent_id \
                                                            $transaction_id \
                                                            $event]
        return $event
    }

    proc response {status reason headers {body_mode text} {encoding {}}} {
        variable active
        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        send_event response {} [dict create status      $status     \
                                            reason      $reason     \
                                            headers     $headers    \
                                            body_mode   $body_mode  \
                                            encoding    $encoding]
        return
    }

    proc out {data {body_mode text}} {
        variable active
        variable output_buffer
        variable output_body_mode

        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        if {$output_body_mode eq {}} {
            set output_body_mode $body_mode
        } elseif {$output_body_mode ne $body_mode} {
            error "application output buffer cannot mix body modes"
        }
        append output_buffer $data
        return
    }

    proc buffer {} {
        variable active
        variable output_buffer

        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        return $output_buffer
    }

    proc discard_buffer {} {
        variable active
        variable output_buffer
        variable output_body_mode

        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        set output_buffer [binary format a* {}]
        set output_body_mode {}
        return
    }

    proc flush_buffer {} {
        variable output_buffer
        variable output_body_mode

        if {$output_buffer eq {}} {
            return
        }
        if {![accepting_output]} {
            set output_buffer [binary format a* {}]
            set output_body_mode {}
            return
        }
        send_event output $output_buffer \
            [dict create body_mode $output_body_mode]
        set output_buffer [binary format a* {}]
        set output_body_mode {}
        return
    }

    proc puts {args} {
        set nonewline 0
        if {[llength $args] > 0 && [lindex $args 0] eq "-nonewline"} {
            set nonewline 1
            set args [lrange $args 1 end]
        }
        if {[llength $args] == 1} {
            set data [lindex $args 0]
        } elseif {[llength $args] == 2 && [lindex $args 0] eq "stdout"} {
            set data [lindex $args 1]
        } else {
            error {wrong # args: should be "::tclwire::io::puts ?-nonewline? ?stdout? string"}
        }
        if {!$nonewline} {
            append data "\n"
        }
        out $data text
        return
    }

    proc flush {} {
        variable active
        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        flush_buffer
        send_event flush
        return
    }

    proc complete {} {
        variable active
        variable response_state

        if {!$active} {
            error "no application output transaction is active"
        }
        if {$response_state ne "open"} {
            return
        }
        flush_buffer
        send_event complete
        set response_state completed
        return
    }

    proc fail {message} {
        variable active
        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        send_event error $message
        return
    }

    proc accepting_output {} {
        variable active
        variable response_state
        return [expr {$active && $response_state eq "open"}]
    }

    namespace export \
        begin end context response out buffer discard_buffer puts flush complete fail
    namespace ensemble create
}

package provide tclwire::application::io 0.1
