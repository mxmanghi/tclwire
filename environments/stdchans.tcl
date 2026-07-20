# stdchans.tcl --
#
# TclWire standard-channel application environment.

package require tclwire::application::io 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::stdchans {
    variable installed 0
    variable native_puts {}
    variable native_flush {}

    proc name {} {
        return stdchans
    }

    proc requires {} {
        return {}
    }

    proc enabled {} {
        variable installed
        return $installed
    }

    proc install {} {
        variable installed
        variable native_puts
        variable native_flush

        if {$installed} {
            return
        }
        set native_puts ::tclwire::stdchans::native_puts
        set native_flush ::tclwire::stdchans::native_flush
        if {[info commands $native_puts] ne {} ||
                [info commands $native_flush] ne {}} {
            error "stdchans native command aliases already exist"
        }

        rename ::puts $native_puts
        rename ::flush $native_flush
        proc ::puts args {
            ::tclwire::stdchans::puts {*}$args
        }
        proc ::flush args {
            ::tclwire::stdchans::flush {*}$args
        }
        set installed 1
        return
    }

    proc uninstall {} {
        variable installed
        variable native_puts
        variable native_flush

        if {!$installed} {
            return
        }
        rename ::puts {}
        rename ::flush {}
        rename $native_puts ::puts
        rename $native_flush ::flush
        set installed 0
        set native_puts {}
        set native_flush {}
        return
    }

    proc transaction_active {} {
        set context [::tclwire::io context]
        return [dict get $context active]
    }

    proc puts {args} {
        variable native_puts

        set original_args $args
        set nonewline 0
        if {[llength $args] > 0 && [lindex $args 0] eq "-nonewline"} {
            set nonewline 1
            set args [lrange $args 1 end]
        }

        if {[llength $args] == 1} {
            set channel stdout
            set data [lindex $args 0]
        } elseif {[llength $args] == 2} {
            set channel [lindex $args 0]
            set data [lindex $args 1]
        } else {
            tailcall $native_puts {*}$original_args
        }

        if {$channel eq "stdout" && [transaction_active]} {
            if {$nonewline} {
                ::tclwire::io puts -nonewline stdout $data
            } else {
                ::tclwire::io puts stdout $data
            }
            return
        }

        tailcall $native_puts {*}$original_args
    }

    proc flush {args} {
        variable native_flush

        if {[llength $args] == 1 &&
                [lindex $args 0] eq "stdout" &&
                [transaction_active]} {
            ::tclwire::io flush
            return
        }

        tailcall $native_flush {*}$args
    }

    namespace export name requires enabled install uninstall puts flush
    namespace ensemble create
}

package provide tclwire::stdchans 0.1
