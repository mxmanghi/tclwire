# diagnostics.tcl --
#
# Pluggable runtime diagnostics for freeze and saturation investigations.

package require TclOO
package require Thread
package require tclwire::accounting     1.2
package require tclwire::chore          0.1
package require tclwire::logger::client 0.1
package require tclwire::tpba::control  0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::DiagnosticProbe {
    method name {} {
        return [namespace tail [self class]]
    }

    method sample {} {
        return [dict create]
    }
}

oo::class create ::tclwire::EventLoopProbe {
    superclass ::tclwire::DiagnosticProbe

    variable started_at
    variable last_sample_at
    variable sample_count
    variable last_lag_ms

    constructor {} {
        set started_at      [clock milliseconds]
        set last_sample_at  $started_at
        set sample_count    0
        set last_lag_ms     0
    }

    method name {} {
        return event_loop
    }

    method sample {{expected_interval_ms 0}} {
        set now     [clock milliseconds]
        set elapsed [expr {$now - $last_sample_at}]
        if {($expected_interval_ms > 0) && ($sample_count > 0)} {
            set last_lag_ms [expr {$elapsed - $expected_interval_ms}]
        } else {
            set last_lag_ms 0
        }
        set last_sample_at $now
        incr sample_count
        return [dict create samples             $sample_count \
                            uptime_ms           [expr {$now - $started_at}] \
                            sample_elapsed_ms   $elapsed \
                            timer_lag_ms        $last_lag_ms]
    }
}

oo::class create ::tclwire::AccountingProbe {
    superclass ::tclwire::DiagnosticProbe

    method name {} {
        return accounting
    }

    method sample {} {
        set thread_counts [dict create]
        dict for {thread_id record} [::tclwire::accounting get_threads_database] {
            set status [dict get $record status]
            if {![dict exists $thread_counts $status]} {
                dict set thread_counts $status 0
            }
            dict incr thread_counts $status
        }

        set connection_counts [dict create]
        dict for {connection_key record} [::tclwire::accounting get_connections_database] {
            set status [dict get $record status]
            if {![dict exists $connection_counts $status]} {
                dict set connection_counts $status 0
            }
            dict incr connection_counts $status
        }

        return [dict create threads         [dict size [::tclwire::accounting get_threads_database]] \
                            thread_status   $thread_counts \
                            connections     [dict size [::tclwire::accounting get_connections_database]] \
                            connection_status $connection_counts]
    }
}

oo::class create ::tclwire::TpbaProbe {
    superclass ::tclwire::DiagnosticProbe

    method name {} {
        return tpba
    }

    method sample {} {
        if {![::tclwire::tpba is_running]} {
            return [dict create running 0]
        }
        set response [::tclwire::tpba request [dict create operation diagnostics]]
        if {![dict get $response ok]} {
            return [dict create running 1 error [dict get $response error]]
        }
        return [dict merge [dict create running 1] [dict get $response result]]
    }
}

oo::class create ::tclwire::DiagnosticChore {
    superclass ::tclwire::Chore

    variable max_age_ms last_alert_sequence last_ok_sequence probes

    constructor args {
        array set options {
            -name       diagnostics
            -maxage_ms  10000
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        if {![string is integer -strict $options(-maxage_ms)] || ($options(-maxage_ms) < 100)} {
            error "event-loop watchdog max age must be an integer >= 100"
        }
        next -name $options(-name)
        set max_age_ms $options(-maxage_ms)
        set last_alert_sequence {}
        set last_ok_sequence    {}
        set probes [list [::tclwire::EventLoopProbe new]    \
                         [::tclwire::AccountingProbe new]   \
                         [::tclwire::TpbaProbe new]]
    }

    destructor {
        foreach probe $probes {
            catch {$probe destroy}
        }
    }

    method run {wakeup} {
        set heartbeat_status [my check_heartbeat $wakeup]
        set samples [dict create]
        foreach probe $probes {
            set name [$probe name]
            if {[catch {my sample_probe $probe $wakeup} sample]} {
                set sample [dict create error $sample]
            }
            dict set samples $name $sample
        }

        set snapshot [dict create sequence  [dict get $wakeup sequence] \
                                  now_ms    [dict get $wakeup now_ms]   \
                                  scheduler_thread_id [dict get $wakeup scheduler_thread_id] \
                                  heartbeat $heartbeat_status \
                                  probes    $samples]

        ::tsv::set tclwire diagnostics_snapshot $snapshot
        return [dict create ok 1 snapshot $snapshot]
    }

    method sample_probe {probe wakeup} {
        if {[info object isa typeof $probe ::tclwire::EventLoopProbe]} {
            return [$probe sample [dict get $wakeup interval_ms]]
        }
        return [$probe sample]
    }

    method check_heartbeat {wakeup} {
        if {[catch {::tsv::get tclwire diagnostics_heartbeat} heartbeat] || ($heartbeat eq {})} {
            return [my alert $wakeup [dict create reason missing_heartbeat]]
        }
        set now                 [dict get $wakeup    now_ms]
        set heartbeat_ms        [dict get $heartbeat now_ms]
        set heartbeat_sequence  [dict get $heartbeat sequence]
        set age_ms [expr {$now - $heartbeat_ms}]
        if {$age_ms > $max_age_ms} {
            return [my alert $wakeup [dict create reason      stale_heartbeat     \
                                           heartbeat_sequence $heartbeat_sequence \
                                           heartbeat_age_ms   $age_ms             \
                                           max_age_ms         $max_age_ms]]
        }

        if {$last_ok_sequence ne $heartbeat_sequence} {
            set last_ok_sequence $heartbeat_sequence
        }
        return [dict create ok               1 \
                            heartbeat_sequence $heartbeat_sequence \
                            heartbeat_age_ms $age_ms]
    }

    method alert {wakeup details} {
        if {[dict exists $details heartbeat_sequence]} {
            set sequence [dict get $details heartbeat_sequence]
        } else {
            set sequence missing
        }
        if {$last_alert_sequence eq $sequence} {
            return [dict merge [dict create ok 0 repeated 1] $details]
        }
        set last_alert_sequence $sequence
        set fields [list event=event_loop_blocked \
                         wakeup_sequence=[dict get $wakeup sequence]]

        dict for {key value} $details {
            lappend fields "$key=[my log_value $value]"
        }
        catch {
            ::tclwire::logger log_error diagnostic [join $fields " "] crit
        }
        return [dict merge [dict create ok 0 alerted 1] $details]
    }

    method log_value {value} {
        return [string map [list "\n" "\\n" "\r" "\\r" " " "_"] $value]
    }
}

namespace eval ::tclwire::diagnostics {
    variable heartbeat_timer {}
    variable heartbeat_sequence 0
    variable heartbeat_interval_ms 1000

    proc heartbeat {} {
        variable heartbeat_timer
        variable heartbeat_sequence
        variable heartbeat_interval_ms

        set heartbeat_timer {}
        incr heartbeat_sequence
        ::tsv::set tclwire diagnostics_heartbeat [dict create \
            sequence $heartbeat_sequence \
            now_ms [clock milliseconds] \
            main_thread_id [::thread::id]]
        set heartbeat_timer [after $heartbeat_interval_ms \
            ::tclwire::diagnostics::heartbeat]
        return
    }

    proc start_heartbeat {interval_ms} {
        variable heartbeat_timer
        variable heartbeat_sequence
        variable heartbeat_interval_ms

        stop_heartbeat
        set heartbeat_sequence 0
        set heartbeat_interval_ms $interval_ms
        heartbeat
        return
    }

    proc stop_heartbeat {} {
        variable heartbeat_timer
        if {$heartbeat_timer ne {}} {
            after cancel $heartbeat_timer
            set heartbeat_timer {}
        }
        catch {::tsv::set tclwire diagnostics_heartbeat {}}
        catch {::tsv::set tclwire diagnostics_snapshot {}}
        return
    }

    proc default_chore_specs {config} {
        set interval_ms [dict get $config diagnostics_interval_ms]
        set max_age_ms [expr {$interval_ms * 2}]
        if {[dict exists $config diagnostics_watchdog_max_age_ms]} {
            set max_age_ms [dict get $config diagnostics_watchdog_max_age_ms]
        }
        return [list [dict create \
            name diagnostics \
            package tclwire::diagnostics \
            class ::tclwire::DiagnosticChore \
            args [list -maxage_ms $max_age_ms]]]
    }

    proc start {config} {
        stop
        if {![dict exists $config diagnostics_enabled] ||
                ![dict get $config diagnostics_enabled]} {
            return {}
        }
        start_heartbeat [dict get $config diagnostics_interval_ms]
        return [::tclwire::chore register [default_chore_specs $config]]
    }

    proc stop {} {
        stop_heartbeat
        return
    }

    proc snapshot {} {
        set runner [::tclwire::chore status]
        if {![dict get $runner running]} {
            return [dict create enabled 0 chore_runner $runner]
        }
        if {[catch {::tsv::get tclwire diagnostics_heartbeat} heartbeat]} {
            set heartbeat {}
        }
        if {[catch {::tsv::get tclwire diagnostics_snapshot} diagnostics] ||
                $diagnostics eq {}} {
            set diagnostics {}
        }
        return [dict create enabled 1 \
                    heartbeat $heartbeat \
                    diagnostics $diagnostics \
                    chore_runner $runner]
    }

    proc rows {} {
        set snapshot [snapshot]
        set rows {}
        foreach name {enabled heartbeat diagnostics chore_runner} {
            if {[dict exists $snapshot $name]} {
                lappend rows [dict create \
                    probe runtime metric $name value [dict get $snapshot $name]]
            }
        }
        if {[dict exists $snapshot diagnostics probes]} {
            dict for {probe metrics} [dict get $snapshot diagnostics probes] {
                dict for {metric value} $metrics {
                    lappend rows [dict create \
                        probe $probe metric $metric value $value]
                }
            }
        }
        return $rows
    }

    namespace export start stop snapshot rows
    namespace ensemble create
}

package provide tclwire::diagnostics 0.1
