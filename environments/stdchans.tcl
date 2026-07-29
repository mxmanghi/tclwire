# stdchans.tcl --
#
# TclWire standard-channel application environment.

package require tclwire::application::io 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}

namespace eval ::tclwire::envs::stdchans {
    variable installed 0

    proc name {} {
        return stdchans
    }

    proc requires {} {
        return {}
    }

    proc path_namespaces {} {
        return [list [namespace current]]
    }

    proc enabled {} {
        variable installed
        return $installed
    }

    proc install {} {
        variable installed

        if {$installed} {
            return
        }
        set installed 1
        return
    }

    proc uninstall {} {
        variable installed

        if {!$installed} {
            return
        }
        set installed 0
        return
    }

    proc transaction_active {} {
        set context [::tclwire::io context]
        return [dict get $context active]
    }

    proc puts {args} {
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
            tailcall ::puts {*}$original_args
        }

        if {$channel eq "stdout" && [transaction_active]} {
            if {$nonewline} {
                ::tclwire::io puts -nonewline stdout $data
            } else {
                ::tclwire::io puts stdout $data
            }
            return
        }

        tailcall ::puts {*}$original_args
    }

    proc flush {args} {
        if {[llength $args] == 1 &&
                [lindex $args 0] eq "stdout" &&
                [transaction_active]} {
            ::tclwire::io flush
            return
        }

        tailcall ::flush {*}$args
    }

    namespace export name requires path_namespaces enabled install uninstall puts flush
    namespace ensemble create
}

package provide tclwire::stdchans 0.1
