# service_logging.tcl --
#
# Shared request logging helpers.

namespace eval ::tclwire {
    variable logger_logchan {}
}

proc ::tclwire::timestamp {} {
    return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
}

proc ::tclwire::log_value {value} {
    return [string map [list "\\" "\\\\" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $value]
}

proc ::tclwire::write_log_line {line} {
    variable logger_logchan

    set stamped_line "[timestamp] $line"
    puts $logger_logchan $stamped_line
    flush $logger_logchan
}

proc ::tclwire::log_from_worker {protocol message} {
    write_log_line "$protocol $message"
}

proc ::tclwire::start_logfile {config} {
    variable logger_logchan

    set logfile [dict get $config logfile]

    file mkdir [file dirname $logfile]

    set logger_logchan [open $logfile a]
    chan configure $logger_logchan -buffering line -translation lf -encoding utf-8
}

proc ::tclwire::stop_logfile {} {
    variable logger_logchan

    if {$logger_logchan ne {}} {
        catch {close $logger_logchan}
        set logger_logchan {}
    }
}
