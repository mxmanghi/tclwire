# runtime_lifecycle.tcl --
#
# Runtime lifecycle and public inspection API.
#
# This module starts and stops the runtime subsystems in dependency order:
# logger, TPBA, chore scheduler, diagnostics, application chores, transport
# reactors, and console reactor. It also owns the namespace state variables
# active, active_config, shutdown_requested, transport_reactors,
# console_reactor, and application_dispatcher.

namespace eval ::tclwire::runtime {
    proc start {argv} {
        variable active
        variable active_config
        variable shutdown_requested
        variable transport_reactors
        variable console_reactor
        variable application_dispatcher

        if {$active} {
            error "TclWire runtime is already active"
        }

        set config [prepare_config $argv]
        if {[dict get $config help]} {
            return $config
        }

        ::tclwire::accounting initialize
        set transport_reactors [dict create]
        set console_reactor {}
        set logger_started 0
        set tpba_started 0
        set chore_started 0
        set server_chores_enabled [config_has_server_chores $config]
        set application_chores_enabled [config_has_application_chores $config]
        try {

            ::tclwire::logger start $config
            set logger_started 1

            ::tclwire::tpba start
            set tpba_started 1

            if {[dict get $config chores_enabled] ||
                    [dict get $config diagnostics_enabled] ||
                    $server_chores_enabled ||
                    $application_chores_enabled} {
                ::tclwire::chore start [dict create chore_interval_ms [dict get $config chore_interval_ms]]
                set chore_started 1
            }

            if {$server_chores_enabled} {
                ::tclwire::chore register [server_chore_specs $config]
            }

            if {[dict get $config diagnostics_enabled]} {
                ::tclwire::diagnostics start $config
            }

            if {$application_chores_enabled} {
                ::tclwire::chore register [application_chore_specs $config]
            }

            set configured_services {}
            foreach service [dict get $config services] {
                set service_id [dict get $service id]
                if {$service_id in $configured_services} {
                    error "duplicate service endpoint: $service_id"
                }
                lappend configured_services $service_id
                set reactor [create_transport_reactor $config $service]
                dict set transport_reactors $service_id $reactor
                $reactor start
            }

            set console_reactor [::tclwire::ConsoleReactor new -path [dict get $config unix_socket] \
                                                               -shutdowncommand [list ::tclwire::runtime::request_shutdown]]
            $console_reactor start

        } on error {message options} {
            catch {::tclwire::diagnostics stop}
            if {$chore_started} {
                catch {::tclwire::chore stop}
            }
            if {[info object isa object $console_reactor]} {
                catch {$console_reactor destroy}
                set console_reactor {}
            }
            dict for {protocol reactor} $transport_reactors {
                catch {$reactor destroy}
            }
            set transport_reactors [dict create]
            if {[info object isa object $application_dispatcher]} {
                catch {$application_dispatcher destroy}
                set application_dispatcher {}
            }
            if {$tpba_started} {
                catch {::tclwire::tpba stop}
            }
            if {$logger_started} {
                catch {::tclwire::logger stop}
            }
            return -options $options $message
        }

        set active_config $config
        set active 1
        set shutdown_requested 0
        return $config
    }

    proc stop {} {
        variable active
        variable active_config
        variable shutdown_requested
        variable transport_reactors
        variable console_reactor
        variable application_dispatcher

        catch {::tclwire::diagnostics stop}
        catch {::tclwire::chore stop}
        if {[info object isa object $console_reactor]} {
            catch {$console_reactor destroy}
            set console_reactor {}
        }
        dict for {protocol reactor} $transport_reactors {
            catch {$reactor destroy}
        }
        set transport_reactors [dict create]
        if {[info object isa object $application_dispatcher]} {
            catch {$application_dispatcher destroy}
            set application_dispatcher {}
        }
        set tpba_error {}
        if {[catch {::tclwire::tpba stop} message options]} {
            set tpba_error [list $message $options]
        }
        catch {::tclwire::logger stop}

        set active 0
        set active_config {}
        set shutdown_requested 1

        if {$tpba_error ne {}} {
            lassign $tpba_error message options
            return -options $options $message
        }
        return
    }

    proc is_running {} {
        variable active
        return $active
    }

    proc config {} {
        variable active_config
        return $active_config
    }

    proc transport_reactor {{protocol http} {port {}}} {
        variable transport_reactors
        if {$port ne {}} {
            set service_id "$protocol:$port"
            if {![dict exists $transport_reactors $service_id]} {
                return {}
            }
            return [dict get $transport_reactors $service_id]
        }

        set matches {}
        dict for {service_id reactor} $transport_reactors {
            if {[string match "${protocol}:*" $service_id]} {
                lappend matches $reactor
            }
        }
        if {[llength $matches] == 0} {
            return {}
        }
        if {[llength $matches] > 1} {
            error "multiple '$protocol' services are active; specify a port"
        }
        return [lindex $matches 0]
    }

    proc transport_reactors {} {
        variable transport_reactors
        return $transport_reactors
    }

    proc console_reactor {} {
        variable console_reactor
        return $console_reactor
    }

    proc application_dispatcher {} {
        variable application_dispatcher
        return $application_dispatcher
    }

    proc request_shutdown {} {
        variable shutdown_requested
        set shutdown_requested 1
        return
    }

    proc run {argv} {
        variable shutdown_requested

        set config [start $argv]
        if {[dict get $config help]} {
            usage
            return $config
        }

        try {
            vwait [namespace which -variable shutdown_requested]
        } finally {
            stop
        }
        return $config
    }

    namespace export usage  parse_args prepare_config start stop is_running \
                     config transport_reactor transport_reactors request_shutdown run implemented_protocols \
                     default_protocols application_dispatcher console_reactor
    namespace ensemble create
}
