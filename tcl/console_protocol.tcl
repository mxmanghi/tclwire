# console_protocol.tcl --
#
# Line-oriented TclWire console command protocol and JSON response helpers.

package require json
package require json::write
package require tclwire::accounting 1.2
package require tclwire::logger::control 0.1

namespace eval ::tclwire::console {
    variable ps_columns {
        thread_id status family running_workload cumulative_workload
        combined_workload last_run_start last_run_end created_on command http_host
    }
    variable connection_columns {
        connection_key status protocol service_id listener_port peer_host peer_port
        worker_thread_id current_transaction_id current_command request_count
        bytes_in bytes_out opened_at
    }
    variable connection_debug_columns {
        closed_at close_reason transport_error
    }
    variable conf_columns {
        scope name value
    }
    variable active_config {}

    proc configure {config} {
        variable active_config
        set active_config $config
        return
    }

    proc configuration_metadata {} {
        return [dict create \
            debug_connection [expr {[debug_connection_configured] ? "true" : "false"}]]
    }

    proc debug_connection_configured {} {
        variable active_config
        set debug_connection [::tclwire::accounting debug_connection_enabled]
        if {[dict exists $active_config debug_connection]} {
            set debug_connection [dict get $active_config debug_connection]
        }
        return [expr {$debug_connection ? 1 : 0}]
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

    proc table_message {command columns rows {extra {}} {object_extra {}}} {
        set fields [list \
            "\"ok\":true" \
            "\"type\":\"table\"" \
            "\"command\":[json_string $command]" \
            "\"columns\":[json_array_strings $columns]" \
            "\"rows\":[json_array_objects $rows]"]
        dict for {key value} $extra {
            lappend fields "[json_string $key]:[json_value $value]"
        }
        dict for {key value} $object_extra {
            lappend fields "[json_string $key]:[json_object $value]"
        }
        return "\{[join $fields ,]\}"
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
        variable connection_debug_columns
        set columns $connection_columns
        set include_closed [debug_connection_configured]
        if {$include_closed} {
            set columns [concat $columns $connection_debug_columns]
        }
        set rows {}
        dict for {connection_key record} \
                [::tclwire::accounting get_connections_database] {
            if {!$include_closed &&
                    [dict get $record status] in {closed failed}} {
                continue
            }
            if {[dict exists $filter port] &&
                    [dict get $record listener_port] ne [dict get $filter port]} {
                continue
            }
            if {[dict exists $filter remote] &&
                    [dict get $record peer_host] ne [dict get $filter remote]} {
                continue
            }
            lappend rows [row_from_dict $columns $record]
        }
        return $rows
    }

    proc connection_table {filter} {
        variable connection_columns
        variable connection_debug_columns
        set columns $connection_columns
        set debug_connection [debug_connection_configured]
        if {$debug_connection} {
            set columns [concat $columns $connection_debug_columns]
        }
        return [table_message CONN $columns [connection_rows $filter] \
            [dict create] [dict create configuration [configuration_metadata]]]
    }

    proc parse_connection_args {args} {
        set filter [dict create]
        for {set i 0} {$i < [llength $args]} {incr i} {
            set option [lindex $args $i]
            switch -exact -- $option {
                -port {
                    incr i
                    if {$i >= [llength $args]} {
                        error "missing value after -port"
                    }
                    set value [lindex $args $i]
                    if {![string is integer -strict $value] ||
                            $value < 1 || $value > 65535} {
                        error "invalid port: $value"
                    }
                    dict set filter port $value
                }
                -remote {
                    incr i
                    if {$i >= [llength $args]} {
                        error "missing value after -remote"
                    }
                    set value [lindex $args $i]
                    if {$value eq {}} {
                        error "remote address must not be empty"
                    }
                    dict set filter remote $value
                }
                default {
                    error "unknown CONN option: $option"
                }
            }
        }
        return $filter
    }

    proc add_conf_row {rows_var scope name value} {
        upvar 1 $rows_var rows
        lappend rows [dict create scope $scope name $name value $value]
        return
    }

    proc conf_rows {} {
        variable active_config
        set rows {}
        if {$active_config eq {}} {
            add_conf_row rows global debug_connection \
                [dict get [configuration_metadata] debug_connection]
            return $rows
        }

        dict for {name value} $active_config {
            if {$name in {services applications}} {
                continue
            }
            add_conf_row rows global $name $value
        }
        foreach service [dict get $active_config services] {
            if {[dict exists $service id]} {
                set scope "service:[dict get $service id]"
            } else {
                set scope "service:[dict get $service protocol]:[dict get $service port]"
            }
            dict for {name value} $service {
                add_conf_row rows $scope $name $value
            }
        }
        dict for {application_id descriptor} [dict get $active_config applications] {
            set hosts [list $application_id]
            if {[dict exists $descriptor hosts]} {
                set hosts [dict get $descriptor hosts]
            }
            foreach host $hosts {
                set scope "host:$host"
                add_conf_row rows $scope application_id $application_id
                dict for {name value} $descriptor {
                    add_conf_row rows $scope $name $value
                }
            }
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
                if {[catch {parse_connection_args {*}$args} message]} {
                    return [error_message $command bad_arguments \
                        $message]
                }
                return [connection_table $message]
            }
            CONF {
                variable conf_columns
                if {[llength $args] != 0} {
                    return [error_message $command bad_arguments \
                        "CONF accepts no arguments"]
                }
                return [table_message $command $conf_columns [conf_rows] \
                    [dict create] [dict create configuration [configuration_metadata]]]
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

    namespace export configure dispatch error_message ok_message table_message \
        ps_rows connection_rows conf_rows
    namespace ensemble create
}

package provide tclwire::console::protocol 0.1
