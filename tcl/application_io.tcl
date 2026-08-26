# application_io.tcl --
#
# Transaction-scoped output bridge used by Content Generator Agents.

package require Thread
package require tclwire::constants 0.1

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
    variable response_metadata {}
    variable response_planner {}
    variable response_prepared 0

    proc begin {thread_id agent_id tx_id} {
        variable active
        variable response_state
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id
        variable output_sequence
        variable output_buffer
        variable output_body_mode
        variable response_metadata
        variable response_planner
        variable response_prepared

        if {$active} {
            error "an application output transaction is already active"
        }
        set connection_thread_id $thread_id
        set connection_agent_id  $agent_id
        set transaction_id       $tx_id
        set output_sequence      0
        set output_buffer        $::tclwire::constants::empty_bytearray
        set output_body_mode     {}
        set response_metadata    [dict create status     200     \
                                              reason     OK      \
                                              headers    {}      \
                                              body_mode  text    \
                                              encoding   {}]
        set response_planner     {}
        set response_prepared    0
        set response_state       open
        set active               1
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
        variable response_metadata
        variable response_planner
        variable response_prepared

        set active 0
        set response_state inactive
        set connection_thread_id {}
        set connection_agent_id {}
        set transaction_id {}
        set output_sequence 0
        set output_buffer $::tclwire::constants::empty_bytearray
        set output_body_mode {}
        set response_metadata {}
        set response_planner {}
        set response_prepared 0
        return
    }

    proc context {} {
        variable active
        variable response_state
        variable connection_thread_id
        variable connection_agent_id
        variable transaction_id

        return [dict create active              $active \
                            response_state      $response_state \
                            connection_thread_id $connection_thread_id \
                            connection_agent_id $connection_agent_id \
                            transaction_id      $transaction_id]
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
        if {$type eq "http_header"} {
            if {[response_is_prepared]} {
                error "HTTP response metadata is immutable after preparation"
            }
            record_header_event $flags
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

    # Install the request-local response planner.  The CGA supplies a command
    # prefix which calls the application's prepare_response method.  Keeping
    # this callback in the output bridge is intentional: the bridge, rather
    # than handle_request's return, knows whether completion is buffered or a
    # flush has made a streaming response irreversible.
    proc configure_response_planner {command_prefix} {
        variable active
        variable response_planner
        if {!$active} {
            error "no application output transaction is active"
        }
        if {[catch {llength $command_prefix}]} {
            error "response planner must be a command prefix"
        }
        set response_planner $command_prefix
        return
    }

    proc response_descriptor {} {
        variable active
        variable response_metadata
        if {!$active} {
            error "no application output transaction is active"
        }
        return $response_metadata
    }

    proc response_is_prepared {} {
        variable response_prepared
        return $response_prepared
    }

    proc header_pairs {headers} {
        set pairs {}
        foreach header $headers {
            if {![regexp {^([^:]+):\s*(.*)$} $header -> name value]} {
                error "invalid HTTP response header"
            }
            lappend pairs [list [string trim $name] $value]
        }
        return $pairs
    }

    proc response_headers {headers} {
        set formatted {}
        foreach header $headers {
            if {[llength $header] != 2} {
                error "response descriptor headers must be name/value pairs"
            }
            lassign $header name value
            if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name] ||
                    [string first "\r" $value] >= 0 ||
                    [string first "\n" $value] >= 0} {
                error "invalid HTTP response header"
            }
            lappend formatted "$name: $value"
        }
        return $formatted
    }

    # header_change is the validated payload of an http_header output event.
    # Its action field is set, add, or remove; name is an HTTP field name; and
    # set/add additionally carry value.  The HTTP application-I/O helper has
    # already rejected invalid names and CR/LF-bearing values before it emits
    # this event, so this routine only applies the change to the local response
    # descriptor used by prepare_response.
    proc record_header_event {header_change} {
        variable response_metadata
        set action [dict get $header_change action]
        set name [dict get $header_change name]
        set headers [dict get $response_metadata headers]
        set updated {}
        foreach header $headers {
            if {$action in {set remove} &&
                    [string equal -nocase [lindex $header 0] $name]} {
                continue
            }
            lappend updated $header
        }
        if {$action in {set add}} {
            lappend updated [list $name [dict get $header_change value]]
        }
        dict set response_metadata headers $updated
        return
    }

    proc streaming_response {} {
        variable response_metadata
        foreach header [dict get $response_metadata headers] {
            if {[string equal -nocase [lindex $header 0] Transfer-Encoding] &&
                    [string equal -nocase [string trim [lindex $header 1]] chunked]} {
                return 1
            }
        }
        return 0
    }

    # Tcl's eq/ne operators compare value representations, while dictionary
    # key order is not semantically significant. Response headers themselves
    # remain ordered because they are one field value (a list) and are compared
    # as such.
    proc same_dictionary {left right} {
        if {[dict size $left] != [dict size $right]} {
            return 0
        }
        dict for {key value} $left {
            if {![dict exists $right $key] ||
                    [dict get $right $key] ne $value} {
                return 0
            }
        }
        return 1
    }

    proc prepare_response {} {
        variable response_planner
        variable response_prepared
        variable response_metadata

        if {$response_prepared} {
            return
        }
        if {$response_planner ne {}} {

            # this is basically calling '$application prepare_response $request $response'.
            # By default the prepare_response returns the argument. That's
            # the place where headers can be changed, for example for client
            # content cache control

            set replacement [{*}$response_planner $response_metadata]

            if {[catch {dict size $replacement}] ||
                ![dict exists $replacement status]} {
                error "prepare_response must return a response descriptor"
            }
            set replacement [dict merge $response_metadata $replacement]
            if {![same_dictionary $replacement $response_metadata]} {
                set headers [response_headers [dict get $replacement headers]]
                set response_metadata $replacement
                send_event response {} [dict create status [dict get $replacement status] \
                                                    reason [dict get $replacement reason] \
                                                    headers $headers \
                                                    body_mode [dict get $replacement body_mode] \
                                                    encoding [dict get $replacement encoding]]
            }
        }
        set response_prepared 1
        return
    }

    proc response {status reason headers {body_mode text} {encoding {}}} {
        variable active
        variable response_metadata
        variable response_prepared
        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        if {$response_prepared} {
            error "HTTP response metadata is immutable after preparation"
        }
        set response_metadata [dict create  status  $status reason $reason \
                                            headers [header_pairs $headers] \
                                            body_mode $body_mode encoding $encoding]

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
        variable response_metadata

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
        if {[dict get $response_metadata body_mode] eq "text"} {
            dict set response_metadata body_mode $body_mode
        }
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
        set output_buffer $::tclwire::constants::empty_bytearray
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
            set output_buffer $::tclwire::constants::empty_bytearray
            set output_body_mode {}
            return
        }
        send_event output $output_buffer \
            [dict create body_mode $output_body_mode]
        set output_buffer $::tclwire::constants::empty_bytearray
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

    proc flush {{channel_event_flags {}}} {
        variable active
        if {!$active} {
            error "no application output transaction is active"
        }
        if {![accepting_output]} {
            return
        }
        set channel_event_flags [dict merge [dict create auto_chunked_on_flush 0] $channel_event_flags]
        if {[dict get $channel_event_flags auto_chunked_on_flush] || [streaming_response]} {
            prepare_response
        }
        flush_buffer
        send_event flush {} $channel_event_flags
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
        prepare_response
        flush_buffer
        send_event complete
        set response_state completed
        return
    }

    proc close_connection {} {
        variable active
        variable response_state
        variable output_buffer
        variable output_body_mode

        if {!$active} {
            error "no application output transaction is active"
        }
        if {$response_state ne "open"} {
            return
        }
        set output_buffer $::tclwire::constants::empty_bytearray
        set output_body_mode {}
        send_event close_connection
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

    namespace export begin end context response out buffer \
                     discard_buffer puts flush complete \
                     close_connection fail configure_response_planner \
                     response_descriptor response_is_prepared
    namespace ensemble create
}

package provide tclwire::application::io 0.1
