# -- logger.tcl
#
#

package require TclOO
catch {package require syslog}
::oo::class create ::tclwire::logger {
    variable log_command

    constructor {} {
        if {[catch {package present syslog}]} {
            set log_command "puts"
        } else {
            if {[info exists ::tcl_interactive] && $::tcl_interactive} {
                set log_command [list syslog -perror -ident tclwire -facility user]
            } else {
                set log_command [list syslog -ident tclwire -facility user]
            }
        }
    }

    method log {msg {severity info}} {
        eval [list {*}$log_command $severity "[incr msg_num] - $msg"]
    }

}
