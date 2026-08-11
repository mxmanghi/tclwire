#!/usr/bin/env tclsh
#
# tclwire_console.tcl --
#
# Interactive TclWire console client.

set project_root [file dirname [file dirname [file normalize [info script]]]]
if {$project_root ni $::auto_path} {
    lappend ::auto_path $project_root
}

package require unix_sockets
package require json
package require tclreadline
package require tclwire::runtime 0.1
package require tclwire::configuration_tree 0.1

namespace eval ::tclwire::console_client {
    variable socket_path [file normalize /tmp/tclwire.sock]
    variable channel      {}
    variable config_file  tclwire.toml.example
    variable config_file_explicit 0
    variable application_id {}
    variable cmdcount    0
    variable history_file [file normalize ~/.tclwire-history]
    variable history_limit 200
    variable readline_eof 0
    variable commands {
        PS        {List thread accounting and status.}
        SERVICES  {List running services with ports and descriptions.}
        CONN      {List connections; optionally filter by -port or -remote.}
        CWORK     {List connection worker workloads.}
        CONF      {Show the effective local application configuration.}
        SERVERCONF {Show the server-provided runtime configuration table.}
        LOGROTATE {Reopen the access and error log files.}
        SHUT      {Request an orderly server shutdown.}
        RECONNECT {Reconnect to the console socket.}
        HELP      {List available console commands.}
        EXIT      {Leave the console client.}
    }
    variable timestamp_columns {
        last_run_start last_run_end created_on opened_at closed_at
    }
    variable column_labels {
        thread_id Thread
        status Status
        family Family
        running_workload Workload
        cumulative_workload {Cumulative WL}
        run_time_ms {Run ms}
        last_run_start {Last Run}
        created_on Created
        command Command
        http_host Host
        connection_key Connection
        protocol Protocol
        service_id Service
        listener_port Port
        peer_host Host
        peer_port {Remote Port}
        worker_thread_id Worker
        current_transaction_id {Last Transaction}
        current_command Command
        request_count Count
        bytes_in Input
        bytes_out Output
        opened_at Started
    }
    proc usage {{channel stdout}} {
        puts $channel "Usage: tclsh utils/tclwire_console.tcl ?--config path? ?--application id? ?--unix-socket path? ?--command command? ?command ...?"
        puts $channel ""
        print_help $channel
    }

    proc help_text {} {
        variable commands
        set lines {Commands:}
        dict for {command description} $commands {
            lappend lines [format "  %-9s %s" $command $description]
        }
        return [join $lines "\n"]
    }

    proc print_help {{channel stdout}} {
        puts $channel [help_text]
    }

    proc parse_args {argv} {
        variable socket_path
        variable config_file
        variable config_file_explicit
        variable application_id
        set command {}
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set arg [lindex $argv $i]
            switch -exact -- $arg {
                --help {
                    usage
                    exit 0
                }
                --unix-socket {
                    incr i
                    if {$i >= [llength $argv]} {
                        error "missing value after --unix-socket"
                    }
                    set socket_path [file normalize [lindex $argv $i]]
                }
                --config {
                    incr i
                    if {$i >= [llength $argv]} {
                        error "missing value after --config"
                    }
                    set config_file [lindex $argv $i]
                    set config_file_explicit 1
                }
                --application {
                    incr i
                    if {$i >= [llength $argv]} {
                        error "missing value after --application"
                    }
                    set application_id [lindex $argv $i]
                }
                --command {
                    incr i
                    if {$i >= [llength $argv]} {
                        error "missing value after --command"
                    }
                    set command [lindex $argv $i]
                }
                default {
                    set command [lrange $argv $i end]
                    break
                }
            }
        }
        return $command
    }

    proc connect {} {
        variable socket_path
        set channel [::unix_sockets::connect $socket_path]
        chan configure $channel -blocking 1 -buffering line \
            -translation lf -encoding utf-8
        return $channel
    }

    proc disconnect {{socket {}}} {
        variable channel
        # unix_sockets 0.5 aborts Tcl when channels are explicitly closed on
        # this platform. Let interpreter teardown release the socket.
        if {$socket eq {} || $socket eq $channel} {
            set channel {}
        }
        return
    }

    proc reconnect {} {
        variable channel
        disconnect $channel
        set channel [connect]
        return $channel
    }

    proc ensure_connected {} {
        variable channel
        if {$channel eq {}} {
            set channel [connect]
        }
        return $channel
    }

    proc is_exit_command {command} {
        return [expr {[string toupper [string trim $command]] eq "EXIT"}]
    }

    proc is_help_command {command} {
        return [expr {[string toupper [string trim $command]] eq "HELP"}]
    }

    proc is_reconnect_command {command} {
        return [expr {[string toupper [string trim $command]] eq "RECONNECT"}]
    }

    proc command_name {command} {
        set words [regexp -all -inline {\S+} [string trim $command]]
        if {[llength $words] == 0} {
            return {}
        }
        return [string toupper [lindex $words 0]]
    }

    proc is_local_command {command} {
        return [expr {[command_name $command] in {CONF HELP EXIT RECONNECT}}]
    }

    proc config_file_from_serverconf {response} {
        if {![dict get $response ok] ||
                [dict get $response type] ne "table"} {
            return {}
        }
        foreach row [dict get $response rows] {
            if {[dict get $row scope] eq "global" &&
                    [dict get $row name] eq "config_file"} {
                return [dict get $row value]
            }
        }
        return {}
    }

    proc derive_config_file_from_server {} {
        variable channel
        variable config_file
        variable config_file_explicit

        if {$config_file_explicit || $channel eq {}} {
            return
        }
        if {[catch {
            set response [send_command $channel SERVERCONF]
            set server_config_file [config_file_from_serverconf $response]
        } message]} {
            puts stderr "could not derive configuration file from server: $message"
            return
        }
        if {$server_config_file ne {}} {
            set config_file $server_config_file
        }
        return
    }

    proc config_argv {} {
        variable config_file
        if {$config_file eq "."} {
            return {}
        }
        return [list --config $config_file]
    }

    proc load_runtime_configuration {} {
        derive_config_file_from_server
        set config [::tclwire::runtime prepare_config [config_argv]]
        return $config
    }

    proc application_configuration_tree {config selected_application} {
        set dispatcher [::tclwire::ApplicationDispatcher new $config]
        try {
            set application_config \
                [$dispatcher application_configuration $selected_application]
            return [$application_config serialize]
        } finally {
            $dispatcher destroy
        }
    }

    proc environment_configuration_tree {config environment_name} {
        return [dict create \
            type tclwire.environment_configuration \
            version 1 \
            environment_id $environment_name \
            values [dict get $config environment_configs $environment_name]]
    }

    proc load_configuration_tree {{target {}}} {
        variable application_id

        set config [load_runtime_configuration]
        if {$target eq {}} {
            set target $application_id
            if {$target eq {}} {
                set target [dict get $config default_application]
            }
        }

        if {[dict exists $config applications $target]} {
            return [application_configuration_tree $config $target]
        }
        if {[dict exists $config environment_configs $target]} {
            return [environment_configuration_tree $config $target]
        }
        error "unknown application or environment: $target"
    }

    proc load_application_configuration {} {
        tailcall load_configuration_tree
    }

    proc print_local_conf {command} {
        set words [regexp -all -inline {\S+} [string trim $command]]
        if {[llength $words] > 2} {
            puts stderr "CONF accepts zero or one argument"
            return 1
        }
        set target {}
        if {[llength $words] == 2} {
            set target [lindex $words 1]
        }
        if {[catch {load_configuration_tree $target} configuration]} {
            puts stderr $configuration
            return 1
        }
        puts [::tclwire::configuration tree $configuration]
        return 0
    }

    proc print_local_command {command} {
        switch -exact -- [command_name $command] {
            CONF {
                return [print_local_conf $command]
            }
            HELP {
                print_help
                return 0
            }
            EXIT {
                return 0
            }
            RECONNECT {
                if {[catch {reconnect} message]} {
                    puts stderr $message
                    return 1
                }
                puts "reconnected"
                return 0
            }
        }
        error "unknown local command: $command"
    }

    proc send_command {channel command} {
        puts $channel $command
        flush $channel
        if {[gets $channel line] < 0} {
            error "server closed the console socket without a response"
        }
        return [::json::json2dict $line]
    }

    proc row_value {row column} {
        if {[dict exists $row $column]} {
            return [dict get $row $column]
        }
        return {}
    }

    proc format_timestamp {value} {
        if {$value eq {}} {
            return {}
        }
        if {![string is wideinteger -strict $value]} {
            return $value
        }
        if {$value == 0} {
            return {}
        }
        if {$value > 100000000000} {
            set value [expr {$value / 1000}]
        }
        return [clock format $value -format "%d-%m-%Y %H:%M:%S"]
    }

    proc display_column {column} {
        variable column_labels
        if {[dict exists $column_labels $column]} {
            return [dict get $column_labels $column]
        }
        return $column
    }

    proc display_value {row column} {
        variable timestamp_columns
        set value [row_value $row $column]
        if {$column in $timestamp_columns} {
            return [format_timestamp $value]
        }
        return $value
    }

    proc matrix_from_response {response} {
        set columns [dict get $response columns]
        set matrix [list [lmap column $columns {
            display_column $column
        }]]
        foreach row [dict get $response rows] {
            lappend matrix [lmap column $columns {
                display_value $row $column
            }]
        }
        return $matrix
    }

    proc fallback_table {matrix} {
        set widths {}
        foreach row $matrix {
            for {set i 0} {$i < [llength $row]} {incr i} {
                set value [lindex $row $i]
                set width [string length $value]
                if {[llength $widths] <= $i} {
                    lappend widths $width
                } elseif {$width > [lindex $widths $i]} {
                    lset widths $i $width
                }
            }
        }
        set border +
        foreach width $widths {
            append border [string repeat - [expr {$width + 2}]] +
        }
        set lines {}
        lappend lines $border
        set row_index 0
        foreach row $matrix {
            set cells {}
            for {set i 0} {$i < [llength $row]} {incr i} {
                set value [lindex $row $i]
                lappend cells " [format "%-*s" [lindex $widths $i] $value] "
            }
            lappend lines "|[join $cells |]|"
            if {$row_index == 0} {
                lappend lines $border
            }
            incr row_index
        }
        lappend lines $border
        return [join $lines "\n"]
    }

    proc print_table {response} {
        set matrix [matrix_from_response $response]
        puts [fallback_table $matrix]
    }

    proc print_response {response} {
        if {![dict get $response ok]} {
            set error [dict get $response error]
            puts stderr "[dict get $error code]: [dict get $error message]"
            return 1
        }
        switch -exact -- [dict get $response type] {
            table {
                print_table $response
            }
            ok {
                puts [dict get $response message]
            }
            default {
                puts $response
            }
        }
        return 0
    }

    proc trim_history_file {} {
        variable history_file
        variable history_limit

        if {![file exists $history_file]} {
            return
        }
        set channel [open $history_file r]
        try {
            chan configure $channel -encoding utf-8 -translation lf
            set lines [split [read $channel] "\n"]
        } finally {
            close $channel
        }
        if {[llength $lines] > 0 && [lindex $lines end] eq {}} {
            set lines [lrange $lines 0 end-1]
        }
        if {[llength $lines] > $history_limit} {
            set lines [lrange $lines end-[expr {$history_limit - 1}] end]
        }
        set channel [open $history_file w]
        try {
            chan configure $channel -encoding utf-8 -translation lf
            puts $channel [join $lines "\n"]
        } finally {
            close $channel
        }
        return
    }

    proc load_history {} {
        variable history_file
        variable history_limit
        set ::tclreadline::historyLength $history_limit
        catch {::tclreadline::readline initialize $history_file}
        return
    }

    proc save_history {} {
        variable history_file
        variable history_limit
        set ::tclreadline::historyLength $history_limit
        catch {::tclreadline::readline write $history_file}
        catch {trim_history_file}
        return
    }

    proc interactive {initial_channel} {
        variable channel
        variable cmdcount
        variable readline_eof
        set channel $initial_channel
        load_history
        set readline_eof 0
        set previous_eofchar [::tclreadline::readline eofchar]
        ::tclreadline::readline eofchar \
            [list set ::tclwire::console_client::readline_eof 1]
        try {
            while 1 {
                if {[catch {
                    ::tclreadline::readline read "tclwire\[$cmdcount\]> "
                } line options]} {
                    if {[eof stdin]} {
                        break
                    }
                    return -options $options $line
                }
                if {$readline_eof || [eof stdin] || [is_exit_command $line]} {
                    break
                }
                if {[string trim $line] eq {}} {
                    continue
                }
                ::tclreadline::readline add $line
                if {[is_help_command $line]} {
                    print_local_command $line
                    incr cmdcount
                    continue
                }
                if {[is_reconnect_command $line]} {
                    print_local_command $line
                    incr cmdcount
                    continue
                }
                if {[command_name $line] eq "CONF"} {
                    print_local_command $line
                    incr cmdcount
                    continue
                }
                if {[catch {
                    set response [send_command [ensure_connected] $line]
                    print_response $response
                } message]} {
                    disconnect $channel
                    puts stderr $message
                }
                incr cmdcount
            }
        } finally {
            catch {::tclreadline::readline eofchar $previous_eofchar}
            save_history
        }
    }

    proc main {argv} {
        set command [parse_args $argv]
        variable channel
        set command_line [join $command " "]
        if {[llength $command] > 0 && [is_exit_command $command_line]} {
            exit 0
        }
        if {[llength $command] > 0 &&
                [is_local_command $command_line] &&
                [command_name $command_line] ne "CONF"} {
            exit [print_local_command $command_line]
        }
        if {[catch {connect} connected_channel]} {
            set channel {}
            puts stderr "could not connect to TclWire console at $::tclwire::console_client::socket_path: $connected_channel"
        } else {
            set channel $connected_channel
        }
        try {
            if {[llength $command] > 0 && [is_local_command $command_line]} {
                exit [print_local_command $command_line]
            }
            if {[llength $command] > 0} {
                set response [send_command [ensure_connected] $command_line]
                exit [print_response $response]
            }
            interactive $channel
        } finally {
            disconnect $channel
        }
    }
}

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {::tclwire::console_client::main $::argv} message options]} {
        puts stderr $message
        ::tclwire::console_client::usage stderr
        exit 1
    }
}
