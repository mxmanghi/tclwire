# console_protocol.tcl --
#
# Line-oriented TclWire console command protocol and JSON response helpers.

package require json
package require json::write
package require tclwire::accounting 1.2
package require tclwire::logger::control 0.1

namespace eval ::tclwire::console {
    variable ps_columns {
        thread_id status family last_run_start last_run_end created_on command http_host
    }
    variable connection_columns {
        connection_key status protocol service_id listener_port peer_host peer_port
        worker_thread_id current_transaction_id current_command request_count
        bytes_in bytes_out opened_at closed_at close_reason transport_error
    }

    proc json_string {value} {
        return [::json::write::string $value]
    }

    proc json_value {value} {
        if {$value eq {}} {
            return null
        }
        if {[string is integer -strict $value]} {
            return $value
        }
        if {[string is double -strict $value]} {
            return $value
        }
        if {$value in {true false}} {
            return $value
        }
        return [json_string $value]
    }

    proc json_object {dict_value} {
        set parts {}
        dict for {key value} $dict_value {
            lappend parts "[json_string $key]:[json_value $value]"
        }
        return "\{[join $parts ,]\}"
    }

    proc json_array_strings {values} {
        set encoded {}
        foreach value $values {
            lappend encoded [json_string $value]
        }
        return "\[[join $encoded ,]\]"
    }

    proc json_array_objects {rows} {
        set encoded {}
        foreach row $rows {
            lappend encoded [json_object $row]
        }
        return "\[[join $encoded ,]\]"
    }

    proc ok_message {command message} {
        return "\{[join [list \
            "\"ok\":true" \
            "\"type\":\"ok\"" \
            "\"command\":[json_string $command]" \
            "\"message\":[json_string $message]"] ,]\}"
    }

    proc table_message {command columns rows} {
        return "\{[join [list \
            "\"ok\":true" \
            "\"type\":\"table\"" \
            "\"command\":[json_string $command]" \
            "\"columns\":[json_array_strings $columns]" \
            "\"rows\":[json_array_objects $rows]"] ,]\}"
    }

    proc error_message {command code message} {
        set error [json_object [dict create code $code message $message]]
        return "\{[join [list \
            "\"ok\":false" \
            "\"type\":\"error\"" \
            "\"command\":[json_string $command]" \
            "\"error\":$error"] ,]\}"
    }

    proc row_from_dict {columns source} {
        set row [dict create]
        foreach column $columns {
            if {[dict exists $source $column]} {
                dict set row $column [dict get $source $column]
            } else {
                dict set row $column {}
            }
        }
        return $row
    }

    proc ps_rows {} {
        variable ps_columns
        set rows {}
        dict for {thread_id account} [::tclwire::accounting get_threads_database] {
            dict set account thread_id $thread_id
            lappend rows [row_from_dict $ps_columns $account]
        }
        return $rows
    }

    proc connection_rows {{filter {}}} {
        variable connection_columns
        set rows {}
        dict for {connection_key record} \
                [::tclwire::accounting get_connections_database] {
            if {[dict exists $filter port] &&
                    [dict get $record listener_port] ne [dict get $filter port]} {
                continue
            }
            if {[dict exists $filter remote] &&
                    [dict get $record peer_host] ne [dict get $filter remote]} {
                continue
            }
            lappend rows [row_from_dict $connection_columns $record]
        }
        return $rows
    }

    proc dispatch {line} {
        variable ps_columns
        variable connection_columns

        set words [regexp -all -inline {\S+} [string trim $line]]
        if {[llength $words] == 0} {
            return [error_message {} empty_command "empty console command"]
        }
        set command [string toupper [lindex $words 0]]
        set args [lrange $words 1 end]

        switch -exact -- $command {
            PS {
                if {[llength $args] != 0} {
                    return [error_message $command bad_arguments \
                        "PS accepts no arguments"]
                }
                return [table_message $command $ps_columns [ps_rows]]
            }
            CONN {
                if {[llength $args] == 0} {
                    return [table_message $command $connection_columns \
                        [connection_rows]]
                }
                if {[llength $args] != 2} {
                    return [error_message $command bad_arguments \
                        "CONN accepts no arguments, '-port <portn>', or '-remote <remote-ip>'"]
                }
                lassign $args option value
                switch -exact -- $option {
                    -port {
                        if {![string is integer -strict $value] ||
                                $value < 1 || $value > 65535} {
                            return [error_message $command bad_arguments \
                                "invalid port: $value"]
                        }
                        return [table_message $command $connection_columns \
                            [connection_rows [dict create port $value]]]
                    }
                    -remote {
                        if {$value eq {}} {
                            return [error_message $command bad_arguments \
                                "remote address must not be empty"]
                        }
                        return [table_message $command $connection_columns \
                            [connection_rows [dict create remote $value]]]
                    }
                    default {
                        return [error_message $command bad_arguments \
                            "unknown CONN option: $option"]
                    }
                }
            }
            SHUT {
                if {[llength $args] != 0} {
                    return [error_message $command bad_arguments \
                        "SHUT accepts no arguments"]
                }
                return [ok_message $command "shutdown requested"]
            }
            LOGROTATE {
                if {[llength $args] != 0} {
                    return [error_message $command bad_arguments \
                        "LOGROTATE accepts no arguments"]
                }
                if {[catch {::tclwire::logger rotate} message]} {
                    return [error_message $command logger_error $message]
                }
                return [ok_message $command "logs reopened"]
            }
            default {
                return [error_message $command unknown_command \
                    "unknown console command: $command"]
            }
        }
    }

    namespace export dispatch error_message ok_message table_message \
        ps_rows connection_rows
    namespace ensemble create
}

package provide tclwire::console::protocol 0.1
