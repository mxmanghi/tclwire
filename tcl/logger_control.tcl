# logger_control.tcl --
#
# Logging Agent lifecycle API for the runtime supervisor.

package require Thread
package require tclwire::constants 0.1
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    variable current_config {}
    ::tclwire::define_constant agent_script_path \
        [file normalize [file join [file dirname [info script]] logger_agent.tcl]]

    proc service_logfile_map {config} {
        set access_log [dict get $config logfile]
        set error_log [dict get $config logerr]
        set logfiles [dict create default [list $access_log $error_log]]

        if {[dict exists $config services]} {
            foreach service [dict get $config services] {
                if {![dict exists $service id]} {
                    continue
                }
                set service_access $access_log
                set service_error $error_log
                if {[dict exists $service logfile]} {
                    set service_access [dict get $service logfile]
                }
                if {[dict exists $service logerr]} {
                    set service_error [dict get $service logerr]
                }
                dict set logfiles [dict get $service id] \
                    [list $service_access $service_error]
                if {[dict exists $service protocol]} {
                    dict set logfiles [dict get $service protocol] \
                        [list $service_access $service_error]
                }
            }
        }

        if {[dict exists $config applications]} {
            dict for {application_id descriptor} [dict get $config applications] {
                set application_access $access_log
                set application_error $error_log
                if {[dict exists $descriptor logfile]} {
                    set application_access [dict get $descriptor logfile]
                }
                if {[dict exists $descriptor logerr]} {
                    set application_error [dict get $descriptor logerr]
                }
                dict set logfiles $application_id \
                    [list $application_access $application_error]
            }
        }
        return $logfiles
    }

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
        set logfiles [dict create]
        if {[dict exists $config logfiles]} {
            set logfiles [dict get $config logfiles]
        } else {
            set logfiles [service_logfile_map $config]
        }
        set normalized_logfiles [dict create]
        dict for {client paths} $logfiles {
            if {[llength $paths] != 2} {
                error "logger paths for '$client' must be a two-element list"
            }
            lassign $paths access_log error_log
            if {[string trim $access_log] eq {}} {
                set access_log [dict get $config logfile]
            }
            if {[string trim $error_log] eq {}} {
                set error_log [dict get $config logerr]
            }
            dict set normalized_logfiles $client \
                [list [file normalize $access_log] [file normalize $error_log]]
        }
        if {![dict exists $normalized_logfiles default]} {
            dict set normalized_logfiles default \
                [list [dict get $config logfile] [dict get $config logerr]]
        }
        dict set config logfiles $normalized_logfiles
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
                [dict get $config logfile] [dict get $config logerr] \
                [dict get $config logfiles]]
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
