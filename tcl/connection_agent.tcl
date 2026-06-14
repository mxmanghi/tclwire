# connection_agent.tcl --
#
# Protocol-independent connection-affine agent base class and worker-thread
# lifecycle helpers.

package require TclOO
package require Thread
package require tclwire::transaction_descriptor 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ConnectionAgent {
    variable channel connection_id peer_host peer_port input_buffer timeout_id
    variable initial_read_id
    variable transaction_state closed

    constructor {conn_channel id host port} {
        set channel $conn_channel
        set connection_id $id
        set peer_host $host
        set peer_port $port
        set input_buffer {}
        set timeout_id {}
        set initial_read_id {}
        set transaction_state {}
        set closed 0

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

    method read_available {} {
        if {$closed} {
            return {}
        }
        if {[eof $channel]} {
            my close
            return {}
        }

        set chunk [read $channel]
        if {$chunk eq {}} {
            return {}
        }

        append input_buffer $chunk
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
        if {$transaction_state eq {} ||
                [$transaction_state id] != $transaction_id} {
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
            my close
            return 0
        }
        my refresh_timeout
        return 1
    }

    method close {} {
        if {$closed} {
            return
        }
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
        after 0 [list ::tclwire::connection_agent_finished [self]]
    }

    method connection_id {} {
        return $connection_id
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
    variable connection_agent {}
    variable connection_finished_thread {}
    variable connection_finished_command {}

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
        set channel [::tls::import $channel \
            -server 1 \
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
        agent_class conn_channel connection_id host port finished_thread
        finished_command
        agent_args transport_config
    } {
        variable connection_agent
        variable connection_finished_thread
        variable connection_finished_command

        if {$connection_agent ne {}} {
            error "connection worker is already active"
        }
        if {![info object isa class $agent_class]} {
            error "unknown connection agent class: $agent_class"
        }

        set connection_finished_thread  $finished_thread
        set connection_finished_command $finished_command
        if {[info commands ::tclwire::accounting] ne {}} {
            ::tclwire::accounting change_thread_status \
                [::thread::id] running [list $agent_class $connection_id]
        }
        if {[catch {
            set conn_channel [prepare_connection_channel \
                $conn_channel $transport_config]
            set connection_agent [$agent_class new \
                $conn_channel $connection_id $host $port {*}$agent_args]
        } message options]} {
            catch {close $conn_channel}
            if {$connection_finished_thread ne {} &&
                    [::thread::exists $connection_finished_thread]} {
                set callback [list {*}$connection_finished_command \
                    $connection_id [::thread::id]]
                ::thread::send -async $connection_finished_thread $callback
            }
            set connection_finished_thread {}
            set connection_finished_command {}
            return {}
        }
        return $connection_agent
    }

    proc stop_connection_agent {} {
        variable connection_agent
        if {$connection_agent ne {}} {
            catch {$connection_agent close}
        }
        return
    }

    proc connection_agent_finished {agent} {
        variable connection_agent
        variable connection_finished_thread
        variable connection_finished_command

        set connection_id {}
        if {$connection_agent eq $agent} {
            set connection_id [$connection_agent connection_id]
            catch {$connection_agent destroy}
            set connection_agent {}
        }

        if {$connection_finished_thread ne {} && [::thread::exists $connection_finished_thread]} {
            set callback [list {*}$connection_finished_command $connection_id [::thread::id]]
            ::thread::send -async $connection_finished_thread $callback
        }
        set connection_finished_thread  {}
        set connection_finished_command {}
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
