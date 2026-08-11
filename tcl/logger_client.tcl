# logger_client.tcl --
#
# Minimal Logging Agent client API for producer threads.

package require Thread
package require TclOO
package require tclwire::constants 0.1
package require tclwire::shared_state 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    ::tclwire::define_constant levels \
            [list trace8 trace7 trace6 trace5 \
                  trace4 trace3 trace2 trace1 \
                  debug info notice warn error \
                  crit alert emerg]

    proc valid_levels {} {
        variable levels
        return $levels
    }

    proc normalize_level {level} {
        variable levels
        set level [string tolower [string trim $level]]
        if {$level ni $levels} {
            error "unknown log level: $level"
        }
        return $level
    }

    proc level_rank {level} {
        variable levels
        return [lsearch -exact $levels [normalize_level $level]]
    }

    proc configure_levels {config} {
        ::tclwire::shared_state initialize
        set global info
        if {[dict exists $config log_level]} {
            set global [normalize_level [dict get $config log_level]]
        }

        set services [dict create]
        if {[dict exists $config services]} {
            foreach service [dict get $config services] {
                if {[dict exists $service id] && [dict exists $service log_level]} {
                    dict set services [dict get $service id] \
                        [normalize_level [dict get $service log_level]]
                }
            }
        }

        set applications [dict create]
        set host_clients [dict create]
        set hosts [dict create]
        if {[dict exists $config applications]} {
            dict for {application_id descriptor} [dict get $config applications] {
                if {[dict exists $descriptor hosts]} {
                    foreach host [dict get $descriptor hosts] {
                        set normalized_host [normalize_host $host]
                        if {[dict exists $descriptor log_level]} {
                            dict set hosts $normalized_host \
                                [normalize_level [dict get $descriptor log_level]]
                        }
                        dict set host_clients $normalized_host $application_id
                    }
                }
                if {![dict exists $descriptor log_level]} {
                    continue
                }
                set level [normalize_level [dict get $descriptor log_level]]
                dict set applications $application_id $level
            }
        }

        ::tsv::set tclwire logger_levels \
            [dict create global $global services $services \
                         applications $applications hosts $hosts]
        ::tsv::set tclwire logger_client_routes \
            [dict create hosts $host_clients]
        return [::tsv::get tclwire logger_levels]
    }

    proc clear_levels {} {
        ::tclwire::shared_state initialize
        ::tsv::set tclwire logger_levels {}
        ::tsv::set tclwire logger_client_routes {}
        return
    }

    proc normalize_host {host} {
        set host [string tolower [string trim $host]]
        if {[regexp {^\[([^\]]+)\](?::[0-9]+)?$} $host -> address]} {
            return $address
        }
        regsub {:[0-9]+$} $host {} host
        return $host
    }

    proc effective_level {{context {}}} {
        set configured {}
        catch {set configured [::tsv::get tclwire logger_levels]}
        if {$configured eq {}} {
            return info
        }
        set level [dict get $configured global]
        if {[dict exists $context service_id] &&
                [dict exists $configured services [dict get $context service_id]]} {
            set level [dict get $configured services [dict get $context service_id]]
        }
        if {[dict exists $context application_id] &&
                [dict exists $configured applications [dict get $context application_id]]} {
            set level [dict get $configured applications [dict get $context application_id]]
        }
        if {[dict exists $context host]} {
            set host [normalize_host [dict get $context host]]
            if {[dict exists $configured hosts $host]} {
                set level [dict get $configured hosts $host]
            }
        }
        return $level
    }

    proc should_log {level {context {}}} {
        return [expr {
            [level_rank $level] >= [level_rank [effective_level $context]]
        }]
    }

    proc client_for_context {context {fallback default}} {
        if {[dict exists $context application_id]} {
            return [dict get $context application_id]
        }
        if {[dict exists $context service_id]} {
            return [dict get $context service_id]
        }
        if {[dict exists $context host]} {
            set routes {}
            catch {set routes [::tsv::get tclwire logger_client_routes]}
            set host [normalize_host [dict get $context host]]
            if {[dict exists $routes hosts $host]} {
                return [dict get $routes hosts $host]
            }
        }
        return $fallback
    }

    proc thread_id {} {
        return [::tsv::get tclwire logger_thread_id]
    }

    proc is_running {} {
        set tid [thread_id]
        return [expr {$tid ne {} && [::thread::exists $tid]}]
    }

    proc getlogger {} {
        if {[namespace which ::tclwire::app::application_active] ne {} &&
                [::tclwire::app::application_active]} {
            set logger [::tclwire::app::application_get logger]
            if {[info object isa object $logger]} {
                return $logger
            }
        }
        if {[namespace exists ::tclwire::cga]} {
            set variable_name ::tclwire::cga::logger
            if {[info exists $variable_name]} {
                set logger [set $variable_name]
                if {[info object isa object $logger]} {
                    return $logger
                }
            }
        }
        error "no TclWire logger client is active"
    }

    oo::class create Client {
        variable client

        constructor {client_id} {
            set client_id [string trim $client_id]
            if {$client_id eq {}} {
                error "logger client id must not be empty"
            }
            set client $client_id
        }

        method id {} {
            return $client
        }

        method write {line} {
            set tid [::tclwire::logger::require_thread]
            ::thread::send -async $tid \
                [list ::tclwire::logger::agent_write_message \
                    [list $client access $line]]
            return
        }

        method write_error {line} {
            set tid [::tclwire::logger::require_thread]
            ::thread::send -async $tid \
                [list ::tclwire::logger::agent_write_message \
                    [list $client error $line]]
            return
        }

        method log {message {level info} {context {}}} {
            if {$context eq {}} {
                set context [dict create service_id $client application_id $client]
            }
            if {[::tclwire::logger::should_log $level $context]} {
                my write "$client $message"
            }
            return
        }

        method log_error {source message {level error} {context {}}} {
            if {$context eq {}} {
                set context [dict create service_id $client application_id $client]
            }
            if {[::tclwire::logger::should_log $level $context]} {
                my write_error "$source level=$level $message"
            }
            return
        }

        method log_connection_closed {record} {
            if {$record eq {}} {
                return
            }
            set context [dict create service_id $client]
            foreach {source target} {service_id service_id peer_host remote} {
                if {[dict exists $record $source]} {
                    dict set context $target [dict get $record $source]
                }
            }
            if {[dict exists $record worker_thread_id] &&
                    [dict get $record worker_thread_id] ne {}} {
                set account [::tclwire::accounting get_thread_account \
                    [dict get $record worker_thread_id]]
                if {[dict get $account http_host] ne {}} {
                    dict set context host [dict get $account http_host]
                }
            }
            set fields [list "connection=[::tclwire::logger::log_value [dict get $record connection_key]]"  \
                             "protocol=[::tclwire::logger::log_value [dict get $record protocol]]"          \
                             "service=[::tclwire::logger::log_value [dict get $record service_id]]"         \
                             "remote=[::tclwire::logger::log_value [dict get $record peer_host]]"           \
                             "status=[::tclwire::logger::log_value [dict get $record status]]"              \
                             "reason=[::tclwire::logger::log_value [dict get $record close_reason]]"        \
                             "bytes_in=[dict get $record bytes_in]"                      \
                             "bytes_out=[dict get $record bytes_out]"]
            if {[dict exists $record transport_error] && [dict get $record transport_error] ne {}} {
                lappend fields \
                    "transport_error=[::tclwire::logger::log_value [dict get $record transport_error]]"
            }
            set message [join $fields " "]
            my log_error connection $message debug $context
            return
        }
    }

    proc log_error {source message {level error} {context {}}} {
        set logger [getlogger]
        tailcall $logger log_error $source $message $level $context
    }

    proc log_value {value} {
        return [string map [list "\\" "\\\\" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $value]
    }

    proc require_thread {} {
        set tid [thread_id]
        if {$tid eq {} || ![::thread::exists $tid]} {
            error "logger thread is not running"
        }
        return $tid
    }

    namespace export Client clear_levels configure_levels effective_level \
                     getlogger is_running log_error log_value normalize_level \
                     should_log thread_id valid_levels
    namespace ensemble create
}

package provide tclwire::logger::client 0.1
