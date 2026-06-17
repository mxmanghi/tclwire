# logger_client.tcl --
#
# Minimal Logging Agent client API for producer threads.

package require Thread
package require tclwire::shared_state 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    variable levels {trace8 trace7 trace6 trace5 trace4 trace3 trace2 trace1 debug info notice warn error crit alert emerg}

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

        set hosts [dict create]
        if {[dict exists $config applications]} {
            dict for {application_id descriptor} [dict get $config applications] {
                if {![dict exists $descriptor log_level]} {
                    continue
                }
                set level [normalize_level [dict get $descriptor log_level]]
                if {[dict exists $descriptor hosts]} {
                    foreach host [dict get $descriptor hosts] {
                        dict set hosts [normalize_host $host] $level
                    }
                }
            }
        }

        ::tsv::set tclwire logger_levels \
            [dict create global $global services $services hosts $hosts]
        return [::tsv::get tclwire logger_levels]
    }

    proc clear_levels {} {
        ::tclwire::shared_state initialize
        ::tsv::set tclwire logger_levels {}
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

    proc thread_id {} {
        return [::tsv::get tclwire logger_thread_id]
    }

    proc is_running {} {
        set tid [thread_id]
        return [expr {$tid ne {} && [::thread::exists $tid]}]
    }

    proc write {line} {
        set tid [require_thread]
        ::thread::send -async $tid [list ::tclwire::logger::agent_write $line]
        return
    }

    proc write_error {line} {
        set tid [require_thread]
        ::thread::send -async $tid \
            [list ::tclwire::logger::agent_write_error $line]
        return
    }

    proc log {protocol message {level info} {context {}}} {
        if {[should_log $level $context]} {
            write "$protocol $message"
        }
    }

    proc log_error {source message {level error} {context {}}} {
        if {[should_log $level $context]} {
            write_error "$source level=$level $message"
        }
    }

    proc log_connection_closed {record} {
        if {$record eq {}} {
            return
        }
        set context [dict create]
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
        set message [join [list \
            "connection=[log_value [dict get $record connection_key]]" \
            "protocol=[log_value [dict get $record protocol]]" \
            "service=[log_value [dict get $record service_id]]" \
            "remote=[log_value [dict get $record peer_host]]" \
            "status=[log_value [dict get $record status]]" \
            "reason=[log_value [dict get $record close_reason]]" \
            "bytes_in=[dict get $record bytes_in]" \
            "bytes_out=[dict get $record bytes_out]"] " "]
        log_error connection $message debug $context
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

    namespace export clear_levels configure_levels effective_level \
        is_running log log_connection_closed log_error log_value \
        normalize_level should_log thread_id valid_levels write write_error
    namespace ensemble create
}

package provide tclwire::logger::client 0.1
