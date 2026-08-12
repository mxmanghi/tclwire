# stdchans.tcl --
#
# TclWire standard-channel application environment.

package require tclwire::application::io 0.1
package require tclwire::environment 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}

oo::class create ::tclwire::envs::StdchansEnvironment {
    superclass ::tclwire::ApplicationEnvironment

    method name {} {
        return stdchans
    }

    method path_namespaces {} {
        return {::tclwire::envs::stdchans}
    }

    method do_install {} {
        ::tclwire::envs::stdchans::install_channel_wrappers
        return
    }

    method do_uninstall {} {
        ::tclwire::envs::stdchans::uninstall_channel_wrappers
        return
    }
}

namespace eval ::tclwire::envs::stdchans {
    variable environment_object [::tclwire::envs::StdchansEnvironment new]
    variable native_puts_command ::tclwire::envs::stdchans::__native_puts
    variable native_flush_command ::tclwire::envs::stdchans::__native_flush
    variable stdout_body_mode text

    proc object {} {
        variable environment_object
        return $environment_object
    }

    proc name {} {
        tailcall [object] name
    }

    proc requires {} {
        return {}
    }

    proc path_namespaces {} {
        tailcall [object] path_namespaces
    }

    proc enabled {} {
        tailcall [object] enabled
    }

    proc configuration {args} {
        tailcall [object] configuration {*}$args
    }

    proc application_configuration {} {
        tailcall [object] application_configuration
    }

    proc install {} {
        tailcall [object] install
    }

    proc uninstall {} {
        tailcall [object] uninstall
    }

    proc transaction_active {} {
        set context [::tclwire::io context]
        return [dict get $context active]
    }

    proc install_channel_wrappers {} {
        variable native_puts_command
        variable native_flush_command

        if {[info commands $native_puts_command] eq {}} {
            rename ::puts $native_puts_command
            proc ::puts {args} {
                tailcall ::tclwire::envs::stdchans::puts {*}$args
            }
        }
        if {[info commands $native_flush_command] eq {}} {
            rename ::flush $native_flush_command
            proc ::flush {args} {
                tailcall ::tclwire::envs::stdchans::flush {*}$args
            }
        }
        return
    }

    proc uninstall_channel_wrappers {} {
        variable native_puts_command
        variable native_flush_command

        if {[info commands $native_puts_command] ne {}} {
            rename ::puts {}
            rename $native_puts_command ::puts
        }
        if {[info commands $native_flush_command] ne {}} {
            rename ::flush {}
            rename $native_flush_command ::flush
        }
        return
    }

    proc native_puts {args} {
        variable native_puts_command
        if {[info commands $native_puts_command] ne {}} {
            if {[catch {uplevel 1 [list $native_puts_command {*}$args]} \
                    message options]} {
                return -options $options \
                    [string map [list $native_puts_command ::puts] $message]
            }
            return
        }
        tailcall ::puts {*}$args
    }

    proc native_flush {args} {
        variable native_flush_command
        if {[info commands $native_flush_command] ne {}} {
            if {[catch {uplevel 1 [list $native_flush_command {*}$args]} \
                    message options]} {
                return -options $options \
                    [string map [list $native_flush_command ::flush] $message]
            }
            return
        }
        tailcall ::flush {*}$args
    }

    proc stdout_body_mode {} {
        variable stdout_body_mode
        return $stdout_body_mode
    }

    proc set_stdout_body_mode {mode} {
        variable stdout_body_mode

        if {$mode ni {text binary}} {
            error "unknown stdout body mode: $mode"
        }
        set previous $stdout_body_mode
        set stdout_body_mode $mode
        return $previous
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
            tailcall native_puts {*}$original_args
        }

        if {$channel eq "stdout" && [transaction_active]} {
            if {[stdout_body_mode] eq "binary"} {
                if {!$nonewline} {
                    append data "\n"
                }
                ::tclwire::io out $data binary
            } else {
                if {$nonewline} {
                    ::tclwire::io puts -nonewline stdout $data
                } else {
                    ::tclwire::io puts stdout $data
                }
            }
            return
        }

        tailcall native_puts {*}$original_args
    }

    proc flush {args} {
        if {([llength $args] == 1) && \
            ([lindex $args 0] eq "stdout") && \
            [transaction_active]} {
            ::tclwire::io flush
            return
        }

        tailcall native_flush {*}$args
    }

    namespace export object name requires path_namespaces \
                     application_configuration configuration \
                     enabled install uninstall puts flush \
                     stdout_body_mode set_stdout_body_mode
    namespace ensemble create
}

package provide tclwire::stdchans 0.1
