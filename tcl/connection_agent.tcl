# connection_agent.tcl --
#
# Protocol-independent connection-affine agent base class
# and worker-thread lifecycle helpers.

package require TclOO
package require Thread
package require tclwire::accounting 1.2
package require tclwire::logger::client 0.1
package require tclwire::tpba::control 0.1
package require tclwire::transaction_descriptor 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ConnectionAgent {
    variable channel connection_id connection_key peer_host peer_port input_buffer timeout_id
    variable initial_read_id
    variable transaction_state closed

    constructor {conn_channel id host port key} {
        if {$key eq {}} {
            error "connection agent requires connection key"
        }
        set channel         $conn_channel
        set connection_id   $id
        set connection_key  $key
        set peer_host       $host
        set peer_port       $port
        set input_buffer    {}
        set timeout_id      {}
        set initial_read_id {}
        set transaction_state {}
        set closed          0

        chan configure $channel -blocking 0 -buffering none -translation binary
    }

    destructor {
        my clear_transaction
        my close
    }

    method start {} {
        chan event $channel readable [list [self] readable]
        my refresh_timeout
        set initial_read_id [after idle [namespace code {my initial_read}]]
        return
    }

    method initial_read {} {
        set initial_read_id {}
        if {!$closed} {
            my readable
        }
        return
    }

    method refresh_timeout {} {
        if {$timeout_id ne {}} {
            after cancel $timeout_id
        }
        set timeout_id [after 30000 [list [self] timeout]]
    }

    method timeout {} {
        set timeout_id {}
        my close
    }

    method readable {} {
        error "readable must be implemented by a protocol-specific subclass"
    }

    method read_available {{max_bytes {}}} {
        if {$closed} {
            return {}
        }
        if {[eof $channel]} {
            my close
            return {}
        }

        if {$max_bytes eq {}} {
            set chunk [read $channel]
        } else {
            set chunk [read $channel $max_bytes]
        }
        if {$chunk eq {}} {
            return {}
        }

        append input_buffer $chunk
        catch {
            set record [::tclwire::accounting get_connection_record $connection_key]
            set bytes_in [expr {
                $record eq {} ? [string length $chunk] :
                [dict get $record bytes_in] + [string length $chunk]
            }]
            ::tclwire::accounting update_connection $connection_key \
                [dict create bytes_in $bytes_in]
        }
        my refresh_timeout
        return $chunk
    }

    method input_buffer {} {
        return $input_buffer
    }

    method clear_input_buffer {} {
        set input_buffer {}
        return
    }

    method begin_transaction {transaction_id descriptor} {
        if {$transaction_state ne {}} {
            error "connection already has an active transaction"
        }
        set transaction_state \
            [::tclwire::TransactionDescriptor new $descriptor $transaction_id]
        return $transaction_id
    }

    method transaction_for {transaction_id} {
        if {[$transaction_state id] != $transaction_id} {
            return {}
        }
        return $transaction_state
    }

    method clear_transaction {} {
        if {$transaction_state ne {}} {
            $transaction_state destroy
            set transaction_state {}
        }
        return
    }

    method finish_transaction {transaction_id} {
        set transaction [my transaction_for $transaction_id]
        if {$transaction eq {}} {
            return {}
        }
        set descriptor [$transaction snapshot]
        my clear_transaction
        return $descriptor
    }

    method write_and_close {data} {
        if {$closed} {
            return
        }
        my write_output $data 1
        my close
    }

    method write_output {data {flush_output 0}} {
        if {$closed} {
            return 0
        }
        if {[catch {
            puts -nonewline $channel $data
            if {$flush_output} {
                flush $channel
            }
        }]} {
            catch {
                set close_record [::tclwire::accounting record_connection_closed $connection_key \
                    [dict create status failed close_reason write_failed \
                                  transport_error write_failed]]
                ::tclwire::logger log_connection_closed $close_record
            }
            my close
            return 0
        }
        catch {
            set record [::tclwire::accounting get_connection_record $connection_key]
            set bytes_out [expr {
                $record eq {} ? [string length $data] :
                [dict get $record bytes_out] + [string length $data]
            }]
            ::tclwire::accounting update_connection $connection_key \
                [dict create bytes_out $bytes_out]
        }
        my refresh_timeout
        return 1
    }

    method close {} {
        if {$closed} { return }
        set closed 1
        if {$timeout_id ne {}} {
            after cancel $timeout_id
            set timeout_id {}
        }
        if {$initial_read_id ne {}} {
            after cancel $initial_read_id
            set initial_read_id {}
        }
        catch {chan event $channel readable {}}
        catch {close $channel}
        my clear_transaction
        catch {
            set close_record [::tclwire::accounting record_connection_closed $connection_key \
                [dict create close_reason closed]]
            ::tclwire::logger log_connection_closed $close_record
        }
        ::tclwire::connection_agent_closed [self]
        after 0 [list ::tclwire::destroy_connection_agent [self]]
    }

    method connection_id {} {
        return $connection_id
    }

    method connection_key {} {
        return $connection_key
    }

    method peer {} {
        return [dict create host $peer_host port $peer_port]
    }

    method active_transaction {} {
        if {$transaction_state eq {}} {
            return {}
        }
        return [$transaction_state snapshot]
    }

    unexport begin_transaction clear_input_buffer clear_transaction \
        finish_transaction initial_read read_available refresh_timeout transaction_for \
        write_and_close write_output
}

namespace eval ::tclwire {
    variable connection_descriptors [dict create]
    variable connection_agent_channels [dict create]

    proc connection_descriptor {
        channel_key connection_agent connection_id connection_key
        finished_thread finished_command pool_key
    } {
        return [dict create \
            channel_key      $channel_key \
            agent            $connection_agent \
            connection_id    $connection_id \
            connection_key   $connection_key \
            finished_thread  $finished_thread \
            finished_command $finished_command \
            pool_key         $pool_key]
    }

    proc store_connection_descriptor {descriptor} {
        variable connection_descriptors
        variable connection_agent_channels

        set channel_key [dict get $descriptor channel_key]
        set agent [dict get $descriptor agent]
        dict set connection_descriptors $channel_key $descriptor
        dict set connection_agent_channels $agent $channel_key
        return $descriptor
    }

    proc connection_descriptor_for_agent {agent} {
        variable connection_descriptors
        variable connection_agent_channels

        if {![dict exists $connection_agent_channels $agent]} {
            return {}
        }
        set channel_key [dict get $connection_agent_channels $agent]
        if {![dict exists $connection_descriptors $channel_key]} {
            return {}
        }
        return [dict get $connection_descriptors $channel_key]
    }

    proc remove_connection_descriptor {agent} {
        variable connection_descriptors
        variable connection_agent_channels

        set descriptor [connection_descriptor_for_agent $agent]
        if {$descriptor eq {}} {
            return {}
        }
        set channel_key [dict get $descriptor channel_key]
        dict unset connection_agent_channels $agent
        dict unset connection_descriptors $channel_key
        return $descriptor
    }

    proc prepare_connection_channel {channel transport_config} {
        if {$transport_config eq {} ||
            ![dict exists $transport_config secure] ||
            ![dict get $transport_config secure]} {

            return $channel

        }
        foreach field {certfile keyfile} {
            if {![dict exists $transport_config $field] ||
                 [dict get $transport_config $field] eq {}} {
                error "secure transport is missing $field"
            }
            if {![file isfile [dict get $transport_config $field]]} {
                error "secure transport $field does not exist: [dict get $transport_config $field]"
            }
        }
        package require tls
        chan configure $channel -blocking 0 -translation binary
        set channel [::tls::import $channel -server 1 \
                                            -request 0 \
                                            -require 0 \
                                            -certfile [dict get $transport_config certfile] \
                                            -keyfile [dict get $transport_config keyfile] \
                                            -ssl2 0 \
                                            -ssl3 0]
        set deadline [expr {[clock milliseconds] + 30000}]
        while 1 {
            if {[::tls::handshake $channel]} {
                break
            }
            if {[clock milliseconds] >= $deadline} {
                error "TLS handshake timed out"
            }
            after 10
        }
        return $channel
    }

    proc start_connection_agent {
        agent_class conn_channel connection_id connection_key
        host port finished_thread finished_command
        pool_key agent_args transport_config
    } {
        if {![info object isa class $agent_class]} {
            error "unknown connection agent class: $agent_class"
        }
        set pool_key [string trim $pool_key]
        if {$pool_key eq {}} {
            error "connection agent pool key must not be empty"
        }

        ::tclwire::accounting change_thread_status [::thread::id] running [list $agent_class $connection_id]
        set channel_key $conn_channel
        if {[catch {
            set conn_channel [prepare_connection_channel $conn_channel $transport_config]
            set channel_key $conn_channel

            set agent_st_d [dict create status           open \
                                        worker_thread_id [::thread::id] \
                                        agent_class      $agent_class]

            ::tclwire::accounting update_connection $connection_key $agent_st_d

            set connection_agent [$agent_class new  $conn_channel \
                                                    $connection_id \
                                                    $host $port     \
                                                   -connectionkey $connection_key {*}$agent_args]
            store_connection_descriptor \
                [connection_descriptor $channel_key $connection_agent $connection_id $connection_key \
                                       $finished_thread $finished_command $pool_key]

            ::tclwire::accounting update_connection $connection_key [dict create agent_id $connection_agent]
        } message options]} {
            catch {close $conn_channel}
            catch {

                set close_rec [dict create status failed close_reason startup_failed transport_error $message]
                set close_record [::tclwire::accounting record_connection_closed $connection_key $close_rec]
                ::tclwire::logger log_connection_closed $close_record

            }
            if {$finished_thread ne {} && [::thread::exists $finished_thread]} {
                set callback [list {*}$finished_command \
                    $connection_id [::thread::id] 0 0]
                ::thread::send -async $finished_thread $callback
            }
            return {}
        }
        set response [::tclwire::tpba notify_workload_transition \
            $pool_key connection-open]
        if {![dict get $response ok]} {
            error [dict get $response error]
        }
        return $connection_agent
    }

    proc stop_connection_agent {} {
        variable connection_descriptors
        foreach descriptor [dict values $connection_descriptors] {
            set agent [dict get $descriptor agent]
            catch {$agent close}
        }
        return
    }

    proc connection_agent_closed {agent} {
        set descriptor [remove_connection_descriptor $agent]
        if {$descriptor eq {}} {
            return {}
        }
        set connection_id [dict get $descriptor connection_id]
        set pool_key [dict get $descriptor pool_key]
        set connection_finished_thread [dict get $descriptor finished_thread]
        set connection_finished_command [dict get $descriptor finished_command]
        set workload_released 0

        if {![catch {
            ::tclwire::tpba notify_workload_transition \
                $pool_key connection-closed
        } response] && [dict get $response ok]} {
            set workload_released 1
        }

        if {($connection_finished_thread ne {}) && \
            [::thread::exists $connection_finished_thread]} {
            set callback [list {*}$connection_finished_command \
                $connection_id [::thread::id] $workload_released]
            ::thread::send -async $connection_finished_thread $callback
        }
        return $descriptor
    }

    proc destroy_connection_agent {agent} {
        if {[info object isa object $agent]} {
            catch {$agent destroy}
        }
        return
    }

    proc connection_agent_finished {agent} {
        set descriptor [connection_agent_closed $agent]
        if {$descriptor eq {}} {
            return
        }
        destroy_connection_agent $agent
        return
    }

    proc route_application_output {agent transaction_id event} {
        if {![info object isa object $agent]} {
            return
        }
        $agent application_output $transaction_id $event
        return
    }
}

package provide tclwire::connection_agent 0.1
