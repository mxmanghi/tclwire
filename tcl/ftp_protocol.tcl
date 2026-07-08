# ftp_protocol.tcl --
#
# FTP control-channel command parser and reply formatter.

package require TclOO

namespace eval ::tclwire {}

oo::class create ::tclwire::FtpProtocolSession {
    method extract_commands {buffer} {
        set commands {}
        while {[set line_end [string first "\n" $buffer]] >= 0} {
            set line [string range $buffer 0 $line_end-1]
            set buffer [string range $buffer $line_end+1 end]
            set line [string trimright $line "\r"]
            if {$line eq {}} {
                continue
            }
            lappend commands [my parse_command $line]
        }
        return [dict create commands $commands remainder $buffer]
    }

    method parse_command {line} {
        if {![regexp {^([^[:space:]]+)(?:[[:space:]]+(.*))?$} \
                $line -> command argument]} {
            error "invalid FTP command"
        }
        if {![info exists argument]} {
            set argument {}
        }
        return [dict create \
            command [string toupper $command] \
            argument [string trim $argument]]
    }

    method format_reply {code message} {
        if {![string is integer -strict $code] || $code < 100 || $code > 599} {
            error "invalid FTP reply code: $code"
        }
        if {[string first "\n" $message] >= 0 ||
                [string first "\r" $message] >= 0} {
            error "FTP reply message must be a single line"
        }
        return "$code $message\r\n"
    }
}

package provide tclwire::ftp::protocol 0.1
