# connection_agent.tcl --
#
# Protocol-independent connection-affine agent base class and worker-thread
# lifecycle helpers.

package require TclOO
package require Thread

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
        dict set descriptor transaction_id $transaction_id
        set transaction_state $descriptor
        return $transaction_id
    }

    method transaction_for {transaction_id} {
        if {$transaction_state eq {} ||
                [dict get $transaction_state transaction_id] != $transaction_id} {
            return {}
        }
        return $transaction_state
    }

    method update_transaction {transaction_id descriptor} {
        if {[my transaction_for $transaction_id] eq {}} {
            error "transaction is not active: $transaction_id"
        }
        dict set descriptor transaction_id $transaction_id
        set transaction_state $descriptor
        return $transaction_id
    }

    method finish_transaction {transaction_id} {
        set descriptor [my transaction_for $transaction_id]
        if {$descriptor ne {}} {
            set transaction_state {}
        }
        return $descriptor
    }

    method write_and_close {data} {
        if {$closed} {
            return
        }
        catch {
            puts -nonewline $channel $data
            flush $channel
        }
        my close
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
        set transaction_state {}
        after 0 [list ::tclwire::connection_agent_finished [self]]
    }

    method connection_id {} {
        return $connection_id
    }

    method peer {} {
        return [dict create host $peer_host port $peer_port]
    }

    method active_transaction {} {
        return $transaction_state
    }

    unexport begin_transaction clear_input_buffer finish_transaction initial_read \
        read_available refresh_timeout transaction_for update_transaction \
        write_and_close
}

namespace eval ::tclwire {
    variable connection_agent {}
    variable connection_finished_thread {}
    variable connection_finished_command {}

    proc start_connection_agent {
        agent_class conn_channel connection_id host port finished_thread
        finished_command
        agent_args
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
        set connection_agent [$agent_class new $conn_channel $connection_id $host $port {*}$agent_args]
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
