# logger_agent.tcl --
#
# Runtime loaded only inside the Logging Agent thread.

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    variable logchan {}
    variable logfile {}
    variable errchan {}
    variable logerr {}
    variable logfile_by_client
    variable logerr_by_client
    variable logfile_path_by_client
    variable logerr_path_by_client
    variable handle_by_path
    array set logfile_by_client {}
    array set logerr_by_client {}
    array set logfile_path_by_client {}
    array set logerr_path_by_client {}
    array set handle_by_path {}

    proc timestamp {} {
        return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    }

    proc open_one_log_channel {path} {
        file mkdir [file dirname $path]
        set channel [open $path a]
        chan configure $channel -buffering line -translation lf -encoding utf-8
        return $channel
    }

    proc open_log_channels {} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr
        variable logfile_by_client
        variable logerr_by_client
        variable logfile_path_by_client
        variable logerr_path_by_client
        variable handle_by_path

        array unset handle_by_path
        array set handle_by_path {}
        foreach client [array names logfile_path_by_client] {
            set path $logfile_path_by_client($client)
            if {![info exists handle_by_path($path)]} {
                set handle_by_path($path) [open_one_log_channel $path]
            }
            set logfile_by_client($client) $handle_by_path($path)
        }
        foreach client [array names logerr_path_by_client] {
            set path $logerr_path_by_client($client)
            if {![info exists handle_by_path($path)]} {
                set handle_by_path($path) [open_one_log_channel $path]
            }
            set logerr_by_client($client) $handle_by_path($path)
        }

        set logchan $logfile_by_client(default)
        set errchan $logerr_by_client(default)
        return
    }

    proc close_log_channels {} {
        variable logchan
        variable errchan
        variable handle_by_path

        foreach path [array names handle_by_path] {
            catch {close $handle_by_path($path)}
        }
        array unset handle_by_path
        array set handle_by_path {}
        set logchan {}
        set errchan {}
        return
    }

    proc agent_initialize {path {error_path {}} {client_paths {}}} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr
        variable logfile_by_client
        variable logerr_by_client
        variable logfile_path_by_client
        variable logerr_path_by_client

        if {$logchan ne {} || $errchan ne {}} {
            error "logger agent is already initialized"
        }

        set logfile [file normalize $path]
        if {$error_path eq {}} {
            set error_path [file normalize /tmp/tclwire-err.log]
        }
        set logerr [file normalize $error_path]

        if {$client_paths eq {}} {
            set client_paths [dict create default [list $logfile $logerr]]
        }
        array unset logfile_by_client
        array unset logerr_by_client
        array unset logfile_path_by_client
        array unset logerr_path_by_client
        array set logfile_by_client {}
        array set logerr_by_client {}
        array set logfile_path_by_client {}
        array set logerr_path_by_client {}
        dict for {client paths} $client_paths {
            lassign $paths access_path error_log_path
            set logfile_path_by_client($client) [file normalize $access_path]
            set logerr_path_by_client($client) [file normalize $error_log_path]
        }
        if {![info exists logfile_path_by_client(default)]} {
            set logfile_path_by_client(default) $logfile
            set logerr_path_by_client(default) $logerr
        }

        open_log_channels

        return [dict create logfile $logfile logerr $logerr]
    }

    proc agent_rotate {} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr

        if {$logchan eq {} || $errchan eq {} ||
                $logfile eq {} || $logerr eq {}} {
            error "logger agent is not initialized"
        }

        close_log_channels
        open_log_channels
        return [dict create logfile $logfile logerr $logerr]
    }

    proc client_channel {client stream} {
        variable logfile_by_client
        variable logerr_by_client

        switch -exact -- $stream {
            access {
                if {[info exists logfile_by_client($client)]} {
                    return $logfile_by_client($client)
                }
                return $logfile_by_client(default)
            }
            error {
                if {[info exists logerr_by_client($client)]} {
                    return $logerr_by_client($client)
                }
                return $logerr_by_client(default)
            }
            default {
                error "unknown logger stream: $stream"
            }
        }
    }

    proc agent_write_message {message} {
        if {[llength $message] != 3} {
            error "logger message must be a three-element list"
        }
        lassign $message client stream line
        set channel [client_channel $client $stream]
        puts $channel "[timestamp] $line"
        flush $channel
        return
    }

    proc agent_write {line} {
        variable logchan

        if {$logchan eq {}} {
            error "logger agent is not initialized"
        }

        tailcall agent_write_message [list default access $line]
    }

    proc agent_write_error {line} {
        variable errchan

        if {$errchan eq {}} {
            error "logger error channel is not initialized"
        }

        tailcall agent_write_message [list default error $line]
    }

    proc agent_shutdown {} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr
        variable logfile_by_client
        variable logerr_by_client
        variable logfile_path_by_client
        variable logerr_path_by_client

        close_log_channels
        array unset logfile_by_client
        array unset logerr_by_client
        array unset logfile_path_by_client
        array unset logerr_path_by_client
        array set logfile_by_client {}
        array set logerr_by_client {}
        array set logfile_path_by_client {}
        array set logerr_path_by_client {}
        set logfile {}
        set logerr {}
        after 0 [list ::thread::release [::thread::id]]
        return
    }
}
