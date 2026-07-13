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

namespace eval ::tclwire::console_client {
    variable socket_path [file normalize /tmp/tclwire.sock]
    variable cmdcount    0
    variable history_file [file normalize ~/.tclwire-history]
    variable history_limit 200
    variable readline_eof 0
    variable commands {
        PS        {List thread accounting and status.}
        SERVICES  {List running services with ports and descriptions.}
        CONN      {List connections; optionally filter by -port or -remote.}
        CWORK     {List connection worker workloads.}
        CONF      {Show the effective runtime configuration.}
        LOGROTATE {Reopen the access and error log files.}
        SHUT      {Request an orderly server shutdown.}
        HELP      {List available console commands.}
        EXIT      {Leave the console client.}
    }
    variable timestamp_columns {
        last_run_start last_run_end created_on opened_at closed_at
    }
    proc usage {{channel stdout}} {
        puts $channel "Usage: tclsh utils/tclwire_console.tcl ?--unix-socket path? ?--command command? ?command ...?"
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

    proc disconnect {channel} {
        # unix_sockets 0.5 aborts Tcl when channels are explicitly closed on
        # this platform. Let interpreter teardown release the socket.
        return
    }

    proc is_exit_command {command} {
        return [expr {[string toupper [string trim $command]] eq "EXIT"}]
    }

    proc is_help_command {command} {
        return [expr {[string toupper [string trim $command]] eq "HELP"}]
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
        if {![string is integer -strict $value]} {
            return $value
        }
        if {$value == 0} {
            return {}
        }
        return [clock format $value -format "%d-%m-%Y %H:%M:%S"]
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
        set matrix [list $columns]
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

    proc interactive {channel} {
        variable cmdcount
        variable readline_eof
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
                    print_help
                    incr cmdcount
                    continue
                }
                if {[catch {
                    set response [send_command $channel $line]
                    print_response $response
                } message]} {
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
        if {[llength $command] > 0 && [is_exit_command [join $command " "]]} {
            exit 0
        }
        if {[llength $command] > 0 && [is_help_command [join $command " "]]} {
            print_help
            exit 0
        }
        set channel [connect]
        try {
            if {[llength $command] > 0} {
                set response [send_command $channel [join $command " "]]
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
