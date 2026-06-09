# logger_client.tcl --
#
# Minimal Logging Agent client API for producer threads.

package require Thread

namespace eval ::tclwire {}

namespace eval ::tclwire::logger {
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

    proc log {protocol message} {
        write "$protocol $message"
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

    namespace export thread_id is_running write log log_value
    namespace ensemble create
}

package provide tclwire::logger::client 0.1
