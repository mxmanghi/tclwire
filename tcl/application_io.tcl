# application_io.tcl --
#
# Transaction-scoped output bridge used by Content Generator Agents.

package require Thread

namespace eval ::tclwire {}

namespace eval ::tclwire::io {
    variable active 0
    variable connection_thread_id {}
    variable connection_agent_id {}
    variable transaction_id {}
    variable output_sequence 0

    proc begin {thread_id agent_id tx_id} {
        variable active
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence

        if {$active} {
            error "an application output transaction is already active"
        }
        set connection_thread_id $thread_id
        set connection_agent_id $agent_id
        set transaction_id $tx_id
        set output_sequence 0
        set active 1
        return
    }

    proc end {} {
        variable active
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence

        set active 0
        set connection_thread_id {}
        set connection_agent_id {}
        set transaction_id {}
        set output_sequence 0
        return
    }

    proc context {} {
        variable active
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id

        return [dict create \
            active $active \
            connection_thread_id $connection_thread_id \
            connection_agent_id $connection_agent_id \
            transaction_id $transaction_id]
    }

    proc send_event {type {data {}} {flags {}}} {
        variable active
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence

        if {!$active} {
            error "no application output transaction is active"
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
                [list ::tclwire::route_application_output \
                      $connection_agent_id \
                      $transaction_id \
                      $event]
        return $event
    }

    proc out {data} {
        send_event output $data
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
        send_event output $data [dict create nonewline $nonewline]
        return
    }

    proc flush {} {
        send_event flush
        return
    }

    proc complete {} {
        send_event complete
        return
    }

    proc fail {message} {
        send_event error $message
        return
    }

    namespace export begin end context out puts flush complete fail
    namespace ensemble create
}

package provide tclwire::application::io 0.1
