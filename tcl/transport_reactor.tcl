# transport_reactor.tcl --
#
# Listener and TPBA-managed connection-agent dispatcher.

package require TclOO
package require Thread
package require tclwire::accounting 1.2
package require tclwire::logger::client 0.1
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::TransportReactor {
    variable listener host port next_connection_id agent_threads agent_connection_keys project_root
    variable last_accept_error pool_key pool_descriptor pool_policy pool_created
    variable agent_class agent_package agent_args transport_config service_id protocol
    variable pending_connections pending_rescheduler pending_retry_after_ms pending_max_attempts

    constructor args {
        array set options {
            -host 127.0.0.1
            -port 8990
            -protocol http
            -agentclass ::tclwire::HttpConnectionAgent
            -agentpackage tclwire::http::connection_agent
            -agentargs {}
            -transportconfig {}
            -serviceid {}
            -maxworkers 100
            -connmaxwait 1000
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        foreach {name minimum} {-maxworkers 1 -connmaxwait 0} {
            if {![string is integer -strict $options($name)] ||
                    $options($name) < $minimum} {
                error "$name must be an integer greater than or equal to $minimum"
            }
        }

        set listener        {}
        set host            $options(-host)
        set port            $options(-port)
        set next_connection_id 0
        set agent_threads   [dict create]
        set agent_connection_keys [dict create]
        set last_accept_error {}
        set project_root    [file dirname [file dirname [file normalize [info script]]]]
        set agent_class     $options(-agentclass)
        set agent_package   $options(-agentpackage)
        set agent_args      $options(-agentargs)
        set transport_config $options(-transportconfig)
        set protocol        $options(-protocol)
        set service_id [expr {$options(-serviceid) eq {} \
            ? "$options(-protocol):$port" : $options(-serviceid)}]
        set pool_descriptor [dict create kind           connection_agent \
                                         protocol       $options(-protocol) \
                                         family         $options(-protocol) \
                                         name           $service_id \
                                         agent_class    $agent_class]
        set pool_policy [dict create minimum_workers 0 \
                                     maximum_workers $options(-maxworkers)]
        set pool_key {}
        set pool_created 0
        set pending_connections {}
        set pending_rescheduler {}
        set pending_retry_after_ms 100
        set pending_max_attempts [expr {
            int(ceil(double($options(-connmaxwait)) / $pending_retry_after_ms))
        }]
    }

    destructor {
        my stop
    }

    method start {} {
        if {$listener ne {}} {
            error "Transport Reactor is already listening"
        }
        my validate_transport_config

        set pool_key "connection:$service_id"

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

    method validate_transport_config {} {
        if {$transport_config eq {} ||
                ![dict exists $transport_config secure] ||
                ![dict get $transport_config secure]} {
            return
        }
        foreach field {certfile keyfile} {
            if {![dict exists $transport_config $field] ||
                    [dict get $transport_config $field] eq {}} {
                error "secure service '$service_id' is missing $field"
            }
            if {![file isfile [dict get $transport_config $field]]} {
                error "secure service '$service_id' $field does not exist: [dict get $transport_config $field]"
            }
        }
        if {[catch {package require tls} message]} {
            error "secure service '$service_id' requires TclTLS: $message"
        }
        return
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
        set agent_connection_keys [dict create]
        my close_pending_connections reactor_stopped
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
            ::tclwire::accounting remove_thread [::thread::id]
        } [list $project_root] [list $agent_package]]
    }

    method destroy_pool {} {
        if {!$pool_created} {
            return
        }
        set response [::tclwire::tpba request [dict create operation destroy_pool pool_key $pool_key]]
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
        set descriptor [dict create \
            channel       $channel \
            peer_host     $peer_host \
            peer_port     $peer_port \
            connection_id $connection_id \
            attempts      0 \
            accepted_at   [clock milliseconds]]
        my dispatch_connection $descriptor
        return
    }

    method dispatch_connection {descriptor} {
        set channel [dict get $descriptor channel]
        set connection_id [dict get $descriptor connection_id]
        set acquire_response [::tclwire::tpba request \
                                        [dict create operation acquire_worker pool_key $pool_key]]
        if {![dict get $acquire_response ok]} {
            set last_accept_error [dict get $acquire_response error]
            catch {close $channel}
            return
        }
        set tid [dict get $acquire_response result]
        if {$tid eq {}} {
            set last_accept_error "connection-agent pool is exhausted: $pool_key"
            my defer_connection $descriptor
            return
        }
        set peer_host [dict get $descriptor peer_host]
        set peer_port [dict get $descriptor peer_port]
        set connection_key "$service_id#$connection_id"
        set secure [expr {
            $transport_config ne {} &&
            [dict exists $transport_config secure] &&
            [dict get $transport_config secure]
        }]
        catch {
            ::tclwire::accounting record_connection_opened  $connection_key \
                        [dict create    connection_id       $connection_id  \
                                        protocol            $protocol       \
                                        service_id          $service_id     \
                                        listener_host       $host           \
                                        listener_port       $port           \
                                        peer_host           $peer_host      \
                                        peer_port           $peer_port      \
                                        secure              $secure         \
                                        pool_key            $pool_key       \
                                        worker_thread_id    $tid            \
                                        agent_class         $agent_class]
        }
        set detached 0

        if {[catch {
            ::thread::detach $channel
            set detached     1
            ::thread::send $tid [list ::thread::attach $channel]
            dict set agent_threads $tid $connection_id
            dict set agent_connection_keys $tid $connection_key
            ::thread::send -async $tid [list ::tclwire::start_connection_agent $agent_class $channel \
                                                                               $connection_id $connection_key \
                                                                               $peer_host $peer_port \
                                                                               [::thread::id] [list [self] connection_finished $pool_key] \
                                                                               $pool_key \
                                                                               $agent_args $transport_config]
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
            if {[dict exists $agent_connection_keys $tid]} {
                dict unset agent_connection_keys $tid
            }
            catch {

                set close_status [dict create status failed close_reason dispatch_failed transport_error $error]
                set close_record [::tclwire::accounting record_connection_closed $connection_key \
                                                                                 ::tclwire::logger \
                                                                                 log_connection_closed \
                                                                                 $close_record \
                                                                                 $close_status]

            }
            catch {::tclwire::tpba request [dict create operation release_worker \
                                                        pool_key  $pool_key \
                                                        worker_id $tid]}
            return
        }
        if {[dict get $descriptor attempts] > 0} {
            my log_deferred_connection dispatched $descriptor $tid
        }
        return
    }

    method defer_connection {descriptor} {
        set attempts [expr {[dict get $descriptor attempts] + 1}]
        dict set descriptor attempts $attempts
        if {$attempts > $pending_max_attempts} {
            set last_accept_error \
                "connection-agent pool is exhausted after $pending_max_attempts attempts: $pool_key"
            my log_deferred_connection closed $descriptor {} crit \
                deferred_attempts_exhausted
            catch {close [dict get $descriptor channel]}
            return
        }
        lappend pending_connections $descriptor
        my log_deferred_connection queued $descriptor {} debug {}
        my schedule_pending_connections
        return
    }

    method log_deferred_connection {event descriptor worker_id {level debug} {reason {}}} {

        set fields [list    "event=connection_$event" \
                            "connection_id=[dict get $descriptor connection_id]" \
                            "service=[::tclwire::logger log_value $service_id]" \
                            "remote=[::tclwire::logger log_value [dict get $descriptor peer_host]]" \
                            "remote_port=[dict get $descriptor peer_port]" \
                            "attempts=[dict get $descriptor attempts]" \
                            "queue_depth=[llength $pending_connections]"]

        if {$worker_id ne {}} {
            lappend fields "worker_thread_id=[::tclwire::logger log_value $worker_id]"
        }
        if {$reason ne {}} {
            lappend fields "reason=[::tclwire::logger log_value $reason]"
        }
        catch {
            ::tclwire::logger log_error transport [join $fields " "] $level \
                [dict create service_id $service_id]
        }
        return

    }

    method schedule_pending_connections {} {
        if {$pending_rescheduler ne {} || [llength $pending_connections] == 0} {
            return
        }
        set pending_rescheduler \
                [after $pending_retry_after_ms [list [self] reschedule_pending_connections]]
        return
    }

    method reschedule_pending_connections {} {
        set pending_rescheduler {}
        set queue $pending_connections
        set pending_connections {}
        foreach descriptor $queue {
            my dispatch_connection $descriptor
        }
        my schedule_pending_connections
        return
    }

    method close_pending_connections {reason} {
        if {$pending_rescheduler ne {}} {
            after cancel $pending_rescheduler
            set pending_rescheduler {}
        }
        foreach descriptor $pending_connections {
            catch {close [dict get $descriptor channel]}
        }
        set pending_connections {}
        return
    }

    method connection_finished {finished_pool_key connection_id worker_id} {
        if {[dict exists $agent_connection_keys $worker_id]} {
            set connection_key [dict get $agent_connection_keys $worker_id]
            dict unset agent_connection_keys $worker_id
            catch {
                set close_record \
                    [::tclwire::accounting record_connection_closed $connection_key [dict create close_reason finished]]
                ::tclwire::logger log_connection_closed $close_record
            }
        }
        if {[dict exists $agent_threads $worker_id]} {
            dict unset agent_threads $worker_id
        }
        if {$pool_created && ($finished_pool_key eq $pool_key)} {
            set response [::tclwire::tpba request                           \
                                    [dict create operation  release_worker  \
                                                 pool_key   $pool_key       \
                                                 worker_id  $worker_id]]
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

    method pending_connections {} {
        return $pending_connections
    }

    method pending_retry_after_ms {} {
        return $pending_retry_after_ms
    }

    method pending_max_attempts {} {
        return $pending_max_attempts
    }

    unexport validate_transport_config dispatch_connection defer_connection \
        schedule_pending_connections close_pending_connections \
        log_deferred_connection
}

package provide tclwire::transport_reactor 0.1
