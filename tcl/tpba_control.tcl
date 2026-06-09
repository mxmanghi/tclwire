# tpba_control.tcl --
#
# Thread-Pool Broker Agent lifecycle API for the runtime supervisor.

package require Thread
package require tclwire::accounting 1.2

namespace eval ::tclwire {}

namespace eval ::tclwire::tpba {
    variable agent_script_path [file normalize \
        [file join [file dirname [info script]] tpba_agent.tcl]]
    variable project_root [file dirname [file dirname [file normalize [info script]]]]

    proc thread_id {} {
        return [::tsv::get tclwire tpba_thread_id]
    }

    proc is_running {} {
        set tid [thread_id]
        return [expr {$tid ne {} && [::thread::exists $tid]}]
    }

    proc start {} {
        variable agent_script_path
        variable project_root

        set existing [thread_id]
        if {$existing ne {} && [::thread::exists $existing]} {
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

        if {$tid eq {} || ![::thread::exists $tid]} {
            return {}
        }

        if {[catch {
            ::thread::send $tid ::tclwire::tpba::agent_shutdown
        } message options]} {
            if {[::thread::exists $tid]} {
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

    proc request {request} {
        set tid [require_thread]
        return [::thread::send $tid \
            [list ::tclwire::tpba::agent_request $request]]
    }

    proc require_thread {} {
        set tid [thread_id]
        if {$tid eq {} || ![::thread::exists $tid]} {
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

    namespace export start stop reset request thread_id is_running
    namespace ensemble create
}

package provide tclwire::tpba::control 0.1
