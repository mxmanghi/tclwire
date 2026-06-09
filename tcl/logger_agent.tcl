# logger_agent.tcl --
#
# Runtime loaded only inside the Logging Agent thread.

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
    variable logchan {}
    variable logfile {}

    proc timestamp {} {
        return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    }

    proc agent_initialize {path} {
        variable logchan
        variable logfile

        if {$logchan ne {}} {
            error "logger agent is already initialized"
        }

        set logfile [file normalize $path]
        file mkdir [file dirname $logfile]
        set logchan [open $logfile a]
        chan configure $logchan -buffering line -translation lf -encoding utf-8
        return $logfile
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

    proc agent_shutdown {} {
        variable logchan
        variable logfile

        if {$logchan ne {}} {
            catch {close $logchan}
            set logchan {}
        }
        set logfile {}
        after 0 [list ::thread::release [::thread::id]]
        return
    }
}
