# transport_reactor.tcl --
#
# Listener and TPBA-managed connection-agent dispatcher.

package require TclOO
package require Thread
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::TransportReactor {
    variable listener host port next_connection_id agent_threads project_root
    variable last_accept_error pool_key pool_descriptor pool_policy pool_created
    variable agent_class agent_package agent_args

    constructor args {
        array set options {
            -host 127.0.0.1
            -port 8990
            -protocol http
            -agentclass ::tclwire::HttpConnectionAgent
            -agentpackage tclwire::http::connection_agent
            -agentargs {}
            -maxworkers 100
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }

        set listener        {}
        set host            $options(-host)
        set port            $options(-port)
        set next_connection_id 0
        set agent_threads   [dict create]
        set last_accept_error {}
        set project_root    [file dirname [file dirname [file normalize [info script]]]]
        set agent_class     $options(-agentclass)
        set agent_package   $options(-agentpackage)
        set agent_args      $options(-agentargs)
        set pool_descriptor [dict create kind           connection_agent \
                                         protocol       $options(-protocol) \
                                         family         $options(-protocol) \
                                         agent_class    $agent_class]
        set pool_policy [dict create minimum_workers 0 \
                                     maximum_workers $options(-maxworkers)]
        set pool_key {}
        set pool_created 0
    }

    destructor {
        my stop
    }

    method start {} {
        if {$listener ne {}} {
            error "Transport Reactor is already listening"
        }

        set key_response [::tclwire::tpba request [dict create operation    pool_key \
                                                               descriptor   $pool_descriptor]]

        if {![dict get $key_response ok]} {
            error [dict get $key_response error]
        }
        set pool_key [dict get $key_response result]

        set create_response [::tclwire::tpba request [dict create operation     create_pool         \
                                                                  pool_key      $pool_key           \
                                                                  worker_script [my worker_script]  \
                                                                  policy        $pool_policy        \
                                                                  descriptor    $pool_descriptor]]
        if {![dict get $create_response ok]} {
            error [dict get $create_response error]
        }
        set pool_created 1

        if {[catch {
            set listener [socket -server [list [self] accept] -myaddr $host $port]
        } message options]} {
            catch {my destroy_pool}
            return -options $options $message
        }
        return $listener
    }

    method stop {} {
        if {$listener ne {}} {
            catch {close $listener}
            set listener {}
        }

        set stopping_threads [dict keys $agent_threads]
        foreach tid $stopping_threads {
            if {[::thread::exists $tid]} {
                catch {
                    ::thread::send -async $tid ::tclwire::stop_connection_agent
                }
            }
        }

        set deadline [expr {[clock milliseconds] + 2000}]
        while {[dict size $agent_threads] > 0 &&
                [clock milliseconds] < $deadline} {
            update
            after 10
        }
        set agent_threads [dict create]
        catch {my destroy_pool}
        return
    }

    method worker_script {} {
        return [format {
            lappend auto_path %s
            package require Thread
            package require tclwire::accounting 1.2
            package require tclwire::connection_agent 0.1
            package require %s 0.1

            proc demand_thread_exit {} {
                if {[info commands ::tclwire::stop_connection_agent] ne {}} {
                    catch {::tclwire::stop_connection_agent}
                }
                ::thread::release [::thread::id]
            }

            ::thread::wait
            catch {::tclwire::accounting remove_thread [::thread::id]}
        } [list $project_root] [list $agent_package]]
    }

    method destroy_pool {} {
        if {!$pool_created} {
            return
        }
        set response [::tclwire::tpba request [dict create \
            operation destroy_pool \
            pool_key $pool_key]]
        set pool_created 0
        if {![dict get $response ok]} {
            error [dict get $response error]
        }
        return
    }

    method accept {channel peer_host peer_port} {
        after idle [list [self] dispatch_accept $channel $peer_host $peer_port]
    }

    method dispatch_accept {channel peer_host peer_port} {
        set connection_id [incr next_connection_id]
        set acquire_response [::tclwire::tpba request \
                                        [dict create operation acquire_worker \
                                                     pool_key  $pool_key]]
        if {![dict get $acquire_response ok]} {
            set last_accept_error [dict get $acquire_response error]
            catch {close $channel}
            return
        }
        set tid [dict get $acquire_response result]
        if {$tid eq {}} {
            set last_accept_error "connection-agent pool is exhausted: $pool_key"
            catch {close $channel}
            return
        }
        set detached 0

        if {[catch {
            ::thread::detach $channel
            set detached 1
            ::thread::send $tid [list ::thread::attach $channel]
            dict set agent_threads $tid $connection_id
            ::thread::send $tid [list ::tclwire::start_connection_agent \
                                        $agent_class $channel $connection_id $peer_host $peer_port \
                                        [::thread::id] [list [self] connection_finished $pool_key] \
                                        $agent_args]
        } error options]} {
            set last_accept_error $error
            if {$detached} {
                catch {::thread::send $tid [list catch [list close $channel]]}
            } else {
                catch {close $channel}
            }
            if {[dict exists $agent_threads $tid]} {
                dict unset agent_threads $tid
            }
            catch {::tclwire::tpba request [dict create \
                operation release_worker \
                pool_key $pool_key \
                worker_id $tid]}
            return
        }
        return
    }

    method connection_finished {finished_pool_key connection_id worker_id} {
        if {[dict exists $agent_threads $worker_id]} {
            dict unset agent_threads $worker_id
        }
        if {$pool_created && $finished_pool_key eq $pool_key} {
            set response [::tclwire::tpba request [dict create \
                operation release_worker \
                pool_key $pool_key \
                worker_id $worker_id]]
            if {![dict get $response ok]} {
                set last_accept_error [dict get $response error]
            }
        }
        return
    }

    method endpoint {} {
        return [dict create host $host port $port]
    }

    method listener {} {
        return $listener
    }

    method agent_threads {} {
        set live [dict create]
        dict for {tid connection_id} $agent_threads {
            if {[::thread::exists $tid]} {
                dict set live $tid $connection_id
            }
        }
        set agent_threads $live
        return $agent_threads
    }

    method last_accept_error {} {
        return $last_accept_error
    }

    method pool_key {} {
        return $pool_key
    }
}

package provide tclwire::transport_reactor 0.1
