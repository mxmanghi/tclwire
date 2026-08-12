# console_reactor.tcl --
#
# Unix-domain console listener for runtime inspection and shutdown commands.

package require TclOO
package require unix_sockets
package require tclwire::accounting 1.2
package require tclwire::console::connection_agent 0.1
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ConsoleReactor {
    variable socket_path socket_group socket_permissions listener next_connection_id connections shutdown_command logger

    constructor args {
        array set options {
            -path /tmp/tclwire.sock
            -group {}
            -permissions {}
            -shutdowncommand {}
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        if {$options(-path) eq {}} {
            error "console socket path must not be empty"
        }
        if {$options(-shutdowncommand) eq {}} {
            error "console reactor requires shutdown command"
        }

        set socket_path [file normalize $options(-path)]
        set socket_group $options(-group)
        set socket_permissions $options(-permissions)
        set shutdown_command $options(-shutdowncommand)
        set listener {}
        set next_connection_id 0
        set connections [dict create]
        set logger [::tclwire::logger::Client new console]
    }

    destructor {
        my stop
        if {[info object isa object $logger]} {
            catch {$logger destroy}
        }
    }

    method start {} {
        if {$listener ne {}} {
            error "Console Reactor is already listening"
        }
        set directory [file dirname $socket_path]
        if {![file isdirectory $directory]} {
            file mkdir $directory
        }
        if {[file exists $socket_path]} {
            file delete -force $socket_path
        }
        set listener [::unix_sockets::listen $socket_path [list [self] accept]]
        if {$socket_group ne {}} {
            file attributes $socket_path -group $socket_group
        }
        if {$socket_permissions ne {}} {
            file attributes $socket_path -permissions $socket_permissions
        }
        return $listener
    }

    method stop {} {
        dict for {connection_key agent} $connections {
            catch {$agent destroy}
        }
        set connections [dict create]
        if {$listener ne {}} {
            # unix_sockets 0.5 aborts Tcl when listener channels are closed
            # directly. Drop TclWire's reference and unlink the socket path;
            # the process will release the listener channel at interpreter exit.
            set listener {}
        }
        catch {file delete -force $socket_path}
        return
    }

    method accept {channel args} {
        set connection_id [incr next_connection_id]
        set connection_key "console:$connection_id"
        catch {
            ::tclwire::accounting record_connection_opened $connection_key \
                [dict create \
                    connection_id $connection_id \
                    protocol console \
                    service_id console \
                    listener_host unix \
                    listener_port $socket_path \
                    peer_host local \
                    peer_port {} \
                    secure 0 \
                    pool_key console \
                    worker_thread_id [::thread::id] \
                    agent_class ::tclwire::ConsoleConnectionAgent \
                    status open]
        }
        if {[catch {
            set agent [::tclwire::ConsoleConnectionAgent new \
                $channel $connection_id $connection_key $socket_path \
                $shutdown_command]
            dict set connections $connection_key $agent
            ::tclwire::accounting update_connection $connection_key \
                [dict create agent_id $agent]
        } message options]} {
            catch {
                set close_record [::tclwire::accounting record_connection_closed $connection_key \
                    [dict create status failed close_reason startup_failed \
                                 transport_error $message]]
                $logger log_connection_closed $close_record
            }
            return -options $options $message
        }
        return
    }

    method socket_path {} {
        return $socket_path
    }

    method listener {} {
        return $listener
    }

    method connections {} {
        set live [dict create]
        dict for {connection_key agent} $connections {
            if {[info object isa object $agent]} {
                dict set live $connection_key $agent
            }
        }
        set connections $live
        return $connections
    }
}

package provide tclwire::console::reactor 0.1
