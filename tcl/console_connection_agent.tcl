# console_connection_agent.tcl --
#
# Console socket connection handler.

package require TclOO
package require Thread
package require tclwire::accounting 1.2
package require tclwire::console::protocol 0.1
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ConsoleConnectionAgent {
    variable channel connection_key connection_id socket_path shutdown_command
    variable closed input_buffer

    constructor {conn_channel id key path shutdown_callback} {
        if {$key eq {}} {
            error "console connection agent requires connection key"
        }
        set channel $conn_channel
        set connection_id $id
        set connection_key $key
        set socket_path $path
        set shutdown_command $shutdown_callback
        set closed 0
        set input_buffer {}

        chan configure $channel -blocking 0 -buffering line \
            -translation lf -encoding utf-8
        chan event $channel readable [list [self] readable]
    }

    destructor {
        my close
    }

    method readable {} {
        if {$closed} {
            return
        }
        if {[eof $channel]} {
            my close
            return
        }
        set data [read $channel]
        if {$data eq {}} {
            return
        }
        append input_buffer $data
        catch {
            set record [::tclwire::accounting get_connection_record $connection_key]
            set bytes_in [expr {
                $record eq {} ? [string length $data] :
                [dict get $record bytes_in] + [string length $data]
            }]
            ::tclwire::accounting update_connection $connection_key \
                [dict create bytes_in $bytes_in]
        }

        while {[set newline [string first "\n" $input_buffer]] >= 0} {
            set line [string trimright \
                [string range $input_buffer 0 [expr {$newline - 1}]] "\r"]
            set input_buffer [string range $input_buffer [expr {$newline + 1}] end]
            my handle_command $line
            if {$closed} {
                break
            }
        }
        return
    }

    method handle_command {line} {
        set words [regexp -all -inline {\S+} [string trim $line]]
        if {[llength $words] > 0} {
            catch {
                ::tclwire::accounting increment_connection_request_count \
                    $connection_key \
                    [dict create \
                        current_command [string toupper [lindex $words 0]]]
            }
        }
        set response [::tclwire::console dispatch $line]
        my write_response $response

        if {[llength $words] > 0 &&
                [string toupper [lindex $words 0]] eq "SHUT"} {
            after idle [list {*}$shutdown_command]
        }
        return
    }

    method write_response {response} {
        if {$closed} {
            return 0
        }
        append response "\n"
        if {[catch {
            puts -nonewline $channel $response
            flush $channel
        }]} {
            catch {
                set close_record [::tclwire::accounting record_connection_closed $connection_key \
                    [dict create status failed close_reason write_failed \
                                 transport_error write_failed]]
                ::tclwire::logger log_connection_closed $close_record
            }
            my close
            return 0
        }
        catch {
            set record [::tclwire::accounting get_connection_record $connection_key]
            set bytes_out [expr {
                $record eq {} ? [string length $response] :
                [dict get $record bytes_out] + [string length $response]
            }]
            ::tclwire::accounting update_connection $connection_key \
                [dict create bytes_out $bytes_out current_command {}]
        }
        return 1
    }

    method close {} {
        if {$closed} {
            return
        }
        set closed 1
        catch {chan event $channel readable {}}
        # unix_sockets 0.5 aborts Tcl when socket channels are closed
        # directly on this platform. Disable events and let interpreter
        # teardown release the channel.
        catch {
            set close_record [::tclwire::accounting record_connection_closed \
                $connection_key [dict create close_reason closed]]
            ::tclwire::logger log_connection_closed $close_record
        }
        return
    }

    method connection_id {} {
        return $connection_id
    }

    method connection_key {} {
        return $connection_key
    }
}

package provide tclwire::console::connection_agent 0.1
