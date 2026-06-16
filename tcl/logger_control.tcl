# logger_control.tcl --
#
# Logging Agent lifecycle API for the runtime supervisor.

package require Thread
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    variable current_config {}
    variable agent_script_path [file normalize \
        [file join [file dirname [info script]] logger_agent.tcl]]

    proc normalize_config {config} {
        if {[catch {dict size $config}]} {
            error "logger configuration must be a dictionary"
        }
        if {![dict exists $config logfile]} {
            error "logger configuration is missing logfile"
        }
        if {![dict exists $config logerr]} {
            dict set config logerr [file normalize /tmp/tclwire-err.log]
        }

        set path [dict get $config logfile]
        if {[string trim $path] eq {}} {
            error "logger logfile must not be empty"
        }
        set error_path [dict get $config logerr]
        if {[string trim $error_path] eq {}} {
            error "logger logerr must not be empty"
        }

        dict set config logfile [file normalize $path]
        dict set config logerr [file normalize $error_path]
        return $config
    }

    proc start {config} {
        variable current_config
        variable agent_script_path

        set config [normalize_config $config]
        set existing [thread_id]
        if {$existing ne {} && [::thread::exists $existing]} {
            error "logger thread is already running: $existing"
        }
        ::tsv::set tclwire logger_thread_id {}

        set tid [::thread::create {
            package require Thread
            ::thread::wait
        }]

        try {
            ::thread::send $tid [list source $agent_script_path]
            ::thread::send $tid [list ::tclwire::logger::agent_initialize \
                [dict get $config logfile] [dict get $config logerr]]
        } on error {message options} {
            catch {
                ::thread::send -async $tid [list ::thread::release $tid]
            }
            return -options $options $message
        }

        set current_config $config
        configure_levels $config
        ::tsv::set tclwire logger_thread_id $tid
        return $tid
    }

    proc stop {} {
        set tid [thread_id]
        ::tsv::set tclwire logger_thread_id {}
        clear_levels

        if {$tid eq {} || ![::thread::exists $tid]} {
            return {}
        }

        if {[catch {
            ::thread::send $tid ::tclwire::logger::agent_shutdown
        } message options]} {
            if {[::thread::exists $tid]} {
                return -options $options $message
            }
        }

        wait_for_exit $tid
        return $tid
    }

    proc reset {{config {}}} {
        variable current_config

        if {$config eq {}} {
            if {$current_config eq {}} {
                error "logger has no configuration to reset"
            }
            set config $current_config
        }

        set config [normalize_config $config]
        stop
        return [start $config]
    }

    proc rotate {} {
        set tid [require_thread]
        return [::thread::send $tid ::tclwire::logger::agent_rotate]
    }

    proc wait_for_exit {tid {timeout_ms 2000}} {
        set deadline [expr {[clock milliseconds] + $timeout_ms}]
        while {[::thread::exists $tid] && [clock milliseconds] < $deadline} {
            after 10
        }
        if {[::thread::exists $tid]} {
            error "logger thread did not stop within ${timeout_ms}ms"
        }
        return
    }

    namespace export start stop reset rotate
    namespace ensemble create
}

package provide tclwire::logger::control 0.1
