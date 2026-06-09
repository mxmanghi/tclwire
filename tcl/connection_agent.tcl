# connection_agent.tcl --
#
# Protocol-independent connection-affine agent base class and worker-thread
# lifecycle helpers.

package require TclOO
package require Thread

namespace eval ::tclwire {}

oo::class create ::tclwire::ConnectionAgent {
    variable chan connection_id peer_host peer_port input_buffer timeout_id
    variable initial_read_id
    variable outstanding_transactions closed

    constructor {channel id host port} {
        set chan $channel
        set connection_id $id
        set peer_host $host
        set peer_port $port
        set input_buffer {}
        set timeout_id {}
        set initial_read_id {}
        set outstanding_transactions [dict create]
        set closed 0

        chan configure $chan -blocking 0 -buffering none -translation binary
    }

    destructor {
        my close
    }

    method start {} {
        chan event $chan readable [list [self] readable]
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
        if {[eof $chan]} {
            my close
            return {}
        }

        set chunk [read $chan]
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

    method track_transaction {transaction_id transaction} {
        dict set outstanding_transactions $transaction_id $transaction
        return $transaction_id
    }

    method transaction {transaction_id} {
        if {[dict exists $outstanding_transactions $transaction_id]} {
            return [dict get $outstanding_transactions $transaction_id]
        }
        return {}
    }

    method complete_transaction {transaction_id} {
        if {[dict exists $outstanding_transactions $transaction_id]} {
            dict unset outstanding_transactions $transaction_id
        }
        return
    }

    method write_and_close {data} {
        if {$closed} {
            return
        }
        catch {
            puts -nonewline $chan $data
            flush $chan
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
        catch {chan event $chan readable {}}
        catch {close $chan}
        set outstanding_transactions [dict create]
        after 0 [list ::tclwire::connection_agent_finished [self]]
    }

    method connection_id {} {
        return $connection_id
    }

    method peer {} {
        return [dict create host $peer_host port $peer_port]
    }

    method outstanding_transactions {} {
        return $outstanding_transactions
    }

    unexport clear_input_buffer complete_transaction initial_read read_available \
        refresh_timeout track_transaction transaction write_and_close
}

namespace eval ::tclwire {
    variable connection_agent {}
    variable connection_finished_thread {}
    variable connection_finished_command {}

    proc start_connection_agent {
        agent_class chan connection_id host port finished_thread finished_command
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

        set connection_finished_thread $finished_thread
        set connection_finished_command $finished_command
        if {[info commands ::tclwire::accounting] ne {}} {
            ::tclwire::accounting change_thread_status \
                [::thread::id] running [list $agent_class $connection_id]
        }
        set connection_agent [$agent_class new \
            $chan $connection_id $host $port {*}$agent_args]
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
            set callback [list {*}$connection_finished_command \
                                    $connection_id \
                                    [::thread::id]]
            ::thread::send -async $connection_finished_thread $callback
        }
        set connection_finished_thread {}
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
