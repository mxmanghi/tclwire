# logger_agent.tcl --
#
# Runtime loaded only inside the Logging Agent thread.

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    variable logchan {}
    variable logfile {}
    variable errchan {}
    variable logerr {}

    proc timestamp {} {
        return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    }

    proc open_log_channels {} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr

        file mkdir [file dirname $logfile]
        set logchan [open $logfile a]
        chan configure $logchan -buffering line -translation lf -encoding utf-8

        file mkdir [file dirname $logerr]
        set errchan [open $logerr a]
        chan configure $errchan -buffering line -translation lf -encoding utf-8
        return
    }

    proc close_log_channels {} {
        variable logchan
        variable errchan

        if {$logchan ne {}} {
            catch {close $logchan}
            set logchan {}
        }
        if {$errchan ne {}} {
            catch {close $errchan}
            set errchan {}
        }
        return
    }

    proc agent_initialize {path {error_path {}}} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr

        if {$logchan ne {} || $errchan ne {}} {
            error "logger agent is already initialized"
        }

        set logfile [file normalize $path]
        if {$error_path eq {}} {
            set error_path [file normalize /tmp/tclwire-err.log]
        }
        set logerr [file normalize $error_path]

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

    proc agent_write {line} {
        variable logchan

        if {$logchan eq {}} {
            error "logger agent is not initialized"
        }

        puts $logchan "[timestamp] $line"
        flush $logchan
        return
    }

    proc agent_write_error {line} {
        variable errchan

        if {$errchan eq {}} {
            error "logger error channel is not initialized"
        }

        puts $errchan "[timestamp] $line"
        flush $errchan
        return
    }

    proc agent_shutdown {} {
        variable logchan
        variable logfile
        variable errchan
        variable logerr

        close_log_channels
        set logfile {}
        set logerr {}
        after 0 [list ::thread::release [::thread::id]]
        return
    }
}
