# transport_reactor.tcl --
#
# Listener and TPBA-managed connection-agent dispatcher.
#
# Class boundary:
#
#   TransportReactor owns one listening socket for one configured service
#   endpoint.  It accepts client channels, asks the Thread Pools Broker Agent
#   (TPBA) for a connection-agent worker, moves each accepted channel into that
#   worker thread, and keeps listener-side bookkeeping until the connection
#   reports that it has finished.
#
#   TransportReactor does not implement HTTP, FTP, proxy, TLS application
#   behavior, or request parsing.  Those concerns belong to the protocol-specific
#   connection-agent class selected by -agentclass and started in the worker
#   thread with ::tclwire::start_connection_agent.  TransportReactor also does
#   not decide pool sizing itself; it sends pool policy and workload transitions
#   to TPBA, which owns worker lifecycle and capacity accounting.
#
# The comments below call out "pivots": points where ownership intentionally
# changes hands.  The important pivots are listener setup, accepted channel to
# pending descriptor, descriptor to worker reservation, channel ownership from
# listener thread to worker thread, and finally live connection back to completed
# accounting.

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
            -maxconnperthread 5
            -connmaxwait 1000
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        foreach {name minimum} {-maxworkers 1 -maxconnperthread 1 -connmaxwait 0} {
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
        set service_id [expr {$options(-serviceid) eq {} ? "$options(-protocol):$port" : $options(-serviceid)}]
        set pool_descriptor [dict create kind           connection_agent \
                                         protocol       $options(-protocol) \
                                         family         $options(-protocol) \
                                         name           $service_id \
                                         agent_class    $agent_class]
        set pool_policy [dict create minimum_workers 0 \
                                     maximum_workers $options(-maxworkers) \
                                     max_conn_per_thread $options(-maxconnperthread)]
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
        # Start is the service activation boundary.  Before this method returns,
        # the reactor has created a TPBA pool for this service and opened the
        # listening socket.  If either step fails, the service is not partially
        # active: a listener failure destroys the just-created pool.
        #
        # Pivot: configuration becomes runtime resources here.  After this point
        # TPBA may create connection-agent worker threads and the Tcl socket
        # event loop may call accept for new client channels.
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

        # Transport-level validation only.  The reactor checks that secure
        # services have the files and TclTLS package needed by worker-side TLS
        # setup.  The actual TLS import/handshake happens later in
        # ::tclwire::start_connection_agent, after the channel has moved to the
        # worker interpreter.

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

        # Stop is the reverse of start.  Close the listener first so no new
        # channels arrive, ask active connection-agent workers to stop, wait
        # briefly for their completion callbacks, close any channels still
        # waiting for a worker, then destroy the TPBA pool.
        #
        # Class boundary: the reactor requests shutdown, but each connection
        # agent owns the protocol-specific close behavior for its client
        # channel.

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
        # Script used by TPBA-created worker threads.  It loads the project and
        # protocol-specific connection-agent package, defines the shutdown hook
        # TPBA will call, then waits for commands.  Accepted channels are not
        # embedded in this script; they are attached later by dispatch_connection.
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
            catch {::tclwire::tpba notify_workload_transition %s thread-exit}
            ::tclwire::accounting remove_thread [::thread::id]
        } [list $project_root] [list $agent_package] [list $pool_key]]
    }

    method destroy_pool {} {
        # Pool lifecycle boundary.  TPBA owns the actual worker registry and
        # thread shutdown.  The reactor records whether it asked for a pool so
        # repeated stop/destroy paths can be harmless.
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
        # Tcl's socket -server callback runs in the event loop at accept time.
        # Defer real work until idle so the callback stays short and all
        # connection setup follows the same dispatch_accept path.
        #
        # Pivot: raw socket callback becomes a reactor-managed accept event.
        after idle [list [self] dispatch_accept $channel $peer_host $peer_port]
    }

    method dispatch_accept {channel peer_host peer_port} {
        # Assign the service-local connection id and wrap the accepted channel
        # plus peer information in a descriptor.  From this point on, retry and
        # logging code can treat new and deferred connections the same way.
        #
        # Pivot: accepted channel becomes a connection descriptor.
        set connection_id [incr next_connection_id]
        set descriptor [dict create channel       $channel      \
                                    peer_host     $peer_host    \
                                    peer_port     $peer_port    \
                                    connection_id $connection_id \
                                    attempts      0             \
                                    accepted_at   [clock milliseconds]]
        my dispatch_connection $descriptor
        return
    }

    method dispatch_connection {descriptor} {
        # Try to turn a pending connection descriptor into a running connection
        # agent.  The steps are deliberately ordered:
        #
        #   1. Ask TPBA for a worker in this service pool.
        #   2. If no worker is currently available, keep the channel open in the
        #      pending queue for a bounded retry window.
        #   3. Reserve workload capacity on the selected worker.
        #   4. Record listener-side connection accounting.
        #   5. Move channel ownership from this interpreter to the worker.
        #   6. Asynchronously start the protocol-specific connection agent.
        #
        # Pivot: this is the central handoff from transport acceptance to
        # connection-agent execution.  After thread::detach/thread::attach
        # succeeds, the worker thread owns socket I/O and the reactor only keeps
        # bookkeeping needed for completion and diagnostics.
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

        # No worker id means the pool is at capacity.  This is not yet a
        # protocol failure: keep the accepted channel pending and retry until
        # connmaxwait has been exhausted.
        if {$tid eq {}} {
            set last_accept_error "connection-agent pool is exhausted: $pool_key"
            my defer_connection $descriptor
            return
        }

        # Reserve a connection slot before handing the channel to the worker.
        # If startup later fails before the connection opens, the callback path
        # reports connection-reservation-cancelled to undo this reservation.
        set tpba_msg [dict create operation    thread_workload_changed \
                                  notification [list $tid $pool_key new-connection-processing]]

        set reservation_response [::tclwire::tpba request $tpba_msg]

        if {![dict get $reservation_response ok]} {
            set last_accept_error [dict get $reservation_response error]
            catch {close $channel}
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
            # Channel ownership pivot.  Tcl channels can be used by only one
            # interpreter at a time.  Detach from the listener interpreter,
            # synchronously attach in the worker interpreter, then send the
            # async command that constructs the connection-agent object there.
            ::thread::detach $channel
            set detached     1
            ::thread::send $tid [list ::thread::attach $channel]
            dict set agent_threads $tid $connection_id 1
            dict set agent_connection_keys $tid $connection_id $connection_key
            ::thread::send -async $tid [list ::tclwire::start_connection_agent $agent_class $channel \
                                                                               $connection_id $connection_key \
                                                                               $peer_host $peer_port \
                                                                               [::thread::id] \
                                                                               [list [self] connection_finished $pool_key] \
                                                                               $pool_key \
                                                                               $agent_args $transport_config]
        } error options]} {
            # Failure during the handoff must clean up both sides of the
            # boundary: close the channel in whichever interpreter currently
            # owns it, remove listener-side maps, cancel the TPBA reservation,
            # and release the worker.
            set last_accept_error $error
            if {$detached} {
                catch {::thread::send $tid [list catch [list close $channel]]}
            } else {
                catch {close $channel}
            }
            if {[dict exists $agent_threads $tid $connection_id]} {
                dict unset agent_threads $tid $connection_id
                if {[dict exists $agent_threads $tid] &&
                        [dict size [dict get $agent_threads $tid]] == 0} {
                    dict unset agent_threads $tid
                }
            }
            if {[dict exists $agent_connection_keys $tid $connection_id]} {
                dict unset agent_connection_keys $tid $connection_id
                if {[dict exists $agent_connection_keys $tid] &&
                        [dict size [dict get $agent_connection_keys $tid]] == 0} {
                    dict unset agent_connection_keys $tid
                }
            }
            catch {

                set close_status [dict create status failed close_reason dispatch_failed transport_error $error]
                set close_record [::tclwire::accounting record_connection_closed $connection_key \
                                                                                 ::tclwire::logger \
                                                                                 log_connection_closed \
                                                                                 $close_record \
                                                                                 $close_status]

            }
            catch {::tclwire::tpba request [dict create \
                operation thread_workload_changed \
                notification [list $tid $pool_key connection-reservation-cancelled]]}
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
        # Bounded back-pressure path for temporary pool exhaustion.  The reactor
        # keeps the accepted channel open while waiting for a worker to free up.
        # Once the configured retry budget is exhausted, the channel is closed
        # without ever crossing into a connection-agent worker.
        #
        # Pivot: runnable connection descriptor becomes queued pending work.
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
        # Deferred connections are transport events, not protocol events.  Log
        # them here with service and peer context so pool saturation can be
        # diagnosed without involving any protocol-specific connection agent.

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
        # Keep one retry timer active.  Pending descriptors stay in FIFO order;
        # reschedule_pending_connections will try to dispatch the current queue
        # and then schedule another timer only if anything is still pending.
        if {$pending_rescheduler ne {} || [llength $pending_connections] == 0} {
            return
        }
        set pending_rescheduler \
                [after $pending_retry_after_ms [list [self] reschedule_pending_connections]]
        return
    }

    method reschedule_pending_connections {} {
        # Retry queued accepts after the short delay.  The queue is cleared
        # before dispatching so connections that still cannot acquire a worker
        # re-enter through defer_connection with an incremented attempt count.
        #
        # Pivot: queued pending work becomes ordinary dispatch work again.
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
        # Shutdown/error boundary for queued accepts.  These channels have not
        # been handed to worker interpreters, so the listener thread still owns
        # them and can close them directly.
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

    method connection_finished {finished_pool_key connection_id worker_id \
            {workload_released 0} {connection_opened 1}} {
        # Completion callback from a connection-agent worker.  The worker owns
        # protocol shutdown and channel close; this method owns listener-side
        # maps, connection close accounting, and the final TPBA release boundary.
        #
        # Pivot: a live worker-owned connection becomes completed reactor
        # bookkeeping.  The flags tell the reactor whether the worker already
        # reported the workload transition.  Normal closes usually report
        # connection-closed from the worker; startup failures usually need this
        # method to cancel the earlier reservation.
        set removed_connection 0
        if {[dict exists $agent_connection_keys $worker_id $connection_id]} {
            set connection_key \
                [dict get $agent_connection_keys $worker_id $connection_id]
            dict unset agent_connection_keys $worker_id $connection_id
            if {[dict exists $agent_connection_keys $worker_id] &&
                    [dict size [dict get $agent_connection_keys $worker_id]] == 0} {
                dict unset agent_connection_keys $worker_id
            }
            catch {
                set close_record \
                    [::tclwire::accounting record_connection_closed $connection_key [dict create close_reason finished]]
                ::tclwire::logger log_connection_closed $close_record
            }
        }
        if {[dict exists $agent_threads $worker_id $connection_id]} {
            dict unset agent_threads $worker_id $connection_id
            set removed_connection 1
        }
        if {[dict exists $agent_threads $worker_id] &&
                [dict size [dict get $agent_threads $worker_id]] == 0} {
            dict unset agent_threads $worker_id
        }
        if {$pool_created && ($finished_pool_key eq $pool_key) &&
                $removed_connection && !$workload_released} {
            set transition_id [expr {
                $connection_opened
                    ? "connection-closed"
                    : "connection-reservation-cancelled"
            }]
            set response [::tclwire::tpba request \
                                [dict create operation      thread_workload_changed \
                                             notification   [list $worker_id $pool_key $transition_id]]]
            if {![dict get $response ok]} {
                set last_accept_error [dict get $response error]
            }
        }
        if {$pool_created && ($finished_pool_key eq $pool_key) &&
                ![dict exists $agent_threads $worker_id]} {
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
        dict for {tid connections} $agent_threads {
            if {[::thread::exists $tid]} {
                dict set live $tid [dict keys $connections]
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

    method diagnostic_snapshot {} {
        set worker_connection_count 0
        dict for {tid connections} $agent_threads {
            incr worker_connection_count [dict size $connections]
        }
        return [dict create \
            service_id $service_id \
            protocol $protocol \
            endpoint [my endpoint] \
            listener_active [expr {$listener ne {}}] \
            pool_key $pool_key \
            agent_worker_threads [dict size $agent_threads] \
            worker_connections $worker_connection_count \
            pending_connections [llength $pending_connections] \
            pending_retry_after_ms $pending_retry_after_ms \
            pending_max_attempts $pending_max_attempts \
            last_accept_error $last_accept_error]
    }

    unexport validate_transport_config dispatch_connection defer_connection \
        schedule_pending_connections close_pending_connections \
        log_deferred_connection
}

package provide tclwire::transport_reactor 0.1
