# tpba_control.tcl --
#
# Thread-Pool Broker Agent lifecycle API for the runtime supervisor.

package require Thread
package require tclwire::constants 0.1
package require tclwire::accounting 1.2

namespace eval ::tclwire {}

namespace eval ::tclwire::tpba {
    ::tclwire::define_constant agent_script_path \
        [file normalize [file join [file dirname [info script]] tpba_agent.tcl]]
    ::tclwire::define_constant project_root \
        [file dirname [file dirname [file normalize [info script]]]]

    proc thread_id {} {
        return [::tsv::get tclwire tpba_thread_id]
    }

    proc thread_exists {tid} {
        if {[catch {::thread::exists $tid} exists]} {
            return 0
        }
        return $exists
    }

    proc is_running {} {
        set tid [thread_id]
        return [thread_exists $tid]
    }

    proc start {} {
        variable agent_script_path
        variable project_root

        set existing [thread_id]
        if {[thread_exists $existing]} {
            error "TPBA thread is already running: $existing"
        }
        ::tsv::set tclwire tpba_thread_id {}

        set tid [::thread::create {
            package require Thread
            ::thread::wait
        }]

        try {
            ::thread::send $tid [list lappend auto_path $project_root]
            ::thread::send $tid {package require tclwire::tpba 0.1}
            ::thread::send $tid [list source $agent_script_path]
            ::thread::send $tid ::tclwire::tpba::agent_initialize
        } on error {message options} {
            catch {
                ::thread::send -async $tid [list ::thread::release $tid]
            }
            return -options $options $message
        }

        ::tsv::set tclwire tpba_thread_id $tid
        return $tid
    }

    proc stop {} {
        set tid [thread_id]
        ::tsv::set tclwire tpba_thread_id {}

        if {![thread_exists $tid]} {
            return {}
        }

        if {[catch {
            ::thread::send $tid ::tclwire::tpba::agent_shutdown
        } message options]} {
            if {[thread_exists $tid]} {
                return -options $options $message
            }
        }

        wait_for_exit $tid
        return $tid
    }

    proc reset {} {
        stop
        return [start]
    }

    proc request {command} {
        set tid [require_thread]
        return [::thread::send $tid \
            [list ::tclwire::tpba::agent_execute_command $command]]
    }

    proc notify_workload_transition {pool_key transition_id} {
        set pool_key [string trim $pool_key]
        set transition_id [string trim $transition_id]
        if {![string length $pool_key]} {
            error "workload notification pool key must not be empty"
        }
        if {![string length $transition_id]} {
            error "workload notification transition id must not be empty"
        }
        set notification [list [::thread::id] $pool_key $transition_id]
        if {[llength $notification] != 3} {
            error "workload notification must be {thread_id pool_key transition_id}"
        }
        return [request [dict create \
            operation thread_workload_changed \
            notification $notification]]
    }

    proc require_thread {} {
        set tid [thread_id]
        if {![thread_exists $tid]} {
            error "TPBA thread is not running"
        }
        return $tid
    }

    proc wait_for_exit {tid {timeout_ms 2000}} {
        set deadline [expr {[clock milliseconds] + $timeout_ms}]
        while {[::thread::exists $tid] && [clock milliseconds] < $deadline} {
            after 10
        }
        if {[::thread::exists $tid]} {
            error "TPBA thread did not stop within ${timeout_ms}ms"
        }
        return
    }

    namespace export start stop reset request \
                     thread_id is_running \
                     notify_workload_transition
    namespace ensemble create
}

package provide tclwire::tpba::control 0.1
