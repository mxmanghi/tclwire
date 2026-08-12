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
    variable native_fconfigure_command ::tclwire::envs::stdchans::__native_fconfigure
    variable native_chan_command ::tclwire::envs::stdchans::__native_chan
    variable stdout_body_mode text
    variable stdout_configuration [::fconfigure stdout]

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
        variable native_fconfigure_command
        variable native_chan_command

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
        if {[info commands $native_fconfigure_command] eq {}} {
            rename ::fconfigure $native_fconfigure_command
            proc ::fconfigure {args} {
                tailcall ::tclwire::envs::stdchans::fconfigure {*}$args
            }
        }
        if {[info commands $native_chan_command] eq {}} {
            rename ::chan $native_chan_command
            proc ::chan {args} {
                tailcall ::tclwire::envs::stdchans::chan {*}$args
            }
        }
        return
    }

    proc uninstall_channel_wrappers {} {
        variable native_puts_command
        variable native_flush_command
        variable native_fconfigure_command
        variable native_chan_command

        if {[info commands $native_puts_command] ne {}} {
            rename ::puts {}
            rename $native_puts_command ::puts
        }
        if {[info commands $native_flush_command] ne {}} {
            rename ::flush {}
            rename $native_flush_command ::flush
        }
        if {[info commands $native_fconfigure_command] ne {}} {
            rename ::fconfigure {}
            rename $native_fconfigure_command ::fconfigure
        }
        if {[info commands $native_chan_command] ne {}} {
            rename ::chan {}
            rename $native_chan_command ::chan
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

    proc native_fconfigure {args} {
        variable native_fconfigure_command
        if {[info commands $native_fconfigure_command] ne {}} {
            if {[catch {uplevel 1 [list $native_fconfigure_command {*}$args]} \
                    message options]} {
                return -options $options \
                    [string map [list $native_fconfigure_command ::fconfigure] $message]
            }
            return $message
        }
        tailcall ::fconfigure {*}$args
    }

    proc native_chan {args} {
        variable native_chan_command
        if {[info commands $native_chan_command] ne {}} {
            if {[catch {uplevel 1 [list $native_chan_command {*}$args]} \
                    message options]} {
                return -options $options \
                    [string map [list $native_chan_command ::chan] $message]
            }
            return $message
        }
        tailcall ::chan {*}$args
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

    proc auto_chunked_on_flush {} {
        if {[catch {
            set options [::tclwire::app::environment_configuration stdchans]
        }]} {
            return 0
        }
        if {![dict exists $options auto_chunked_on_flush]} {
            return 0
        }
        return [expr {[dict get $options auto_chunked_on_flush] ? 1 : 0}]
    }

    proc stdout_option_names {} {
        variable stdout_configuration
        return [dict keys $stdout_configuration]
    }

    proc stdout_configure_error_message {option} {
        return "bad option \"$option\": should be one of [join [stdout_option_names] {, }]"
    }

    proc validate_stdout_configuration {option value} {
        switch -exact -- $option {
            -blocking {
                if {![string is boolean -strict $value]} {
                    return -code error -errorcode {TCL VALUE BOOLEAN} \
                        "expected boolean value but got \"$value\""
                }
                return [expr {!!$value}]
            }
            -buffering {
                if {$value ni {full line none}} {
                    error "bad value for -buffering: must be one of full, line, or none"
                }
                return $value
            }
            -buffersize {
                if {![string is integer -strict $value]} {
                    return -code error -errorcode {TCL VALUE INTEGER} \
                        "expected integer but got \"$value\""
                }
                return $value
            }
            -encoding {
                if {$value ne "binary" && $value ni [encoding names]} {
                    return -code error -errorcode [list TCL LOOKUP ENCODING $value] \
                        "unknown encoding \"$value\""
                }
                return $value
            }
            -eofchar {
                if {[llength $value] > 2} {
                    error "bad value for -eofchar: should be a list of zero, one, or two elements"
                }
                return $value
            }
            -translation {
                set translations {auto binary cr lf crlf platform}
                if {[llength $value] < 1 || [llength $value] > 2} {
                    error "bad value for -translation: must be a one or two element list"
                }
                foreach item $value {
                    if {$item ni $translations} {
                        error "bad value for -translation: must be one of auto, binary, cr, lf, crlf, or platform"
                    }
                }
                return $value
            }
            default {
                error [stdout_configure_error_message $option]
            }
        }
    }

    proc update_stdout_body_mode_from_configuration {} {
        variable stdout_configuration

        if {[dict get $stdout_configuration -encoding] eq "binary"} {
            set_stdout_body_mode binary
            return
        }
        set translation [dict get $stdout_configuration -translation]
        if {[lindex $translation end] eq "binary"} {
            set_stdout_body_mode binary
            return
        }
        set_stdout_body_mode text
        return
    }

    proc stdout_fconfigure {args} {
        variable stdout_configuration

        switch -exact -- [llength $args] {
            0 {
                return $stdout_configuration
            }
            1 {
                set option [lindex $args 0]
                if {![dict exists $stdout_configuration $option]} {
                    error [stdout_configure_error_message $option]
                }
                return [dict get $stdout_configuration $option]
            }
            default {
                if {[llength $args] % 2 != 0} {
                    return -code error -errorcode {TCL WRONGARGS} \
                        {wrong # args: should be "fconfigure channelId ?-option value ...?"}
                }
                set updated $stdout_configuration
                foreach {option value} $args {
                    dict set updated $option \
                        [validate_stdout_configuration $option $value]
                }
                set stdout_configuration $updated
                update_stdout_body_mode_from_configuration
                return
            }
        }
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
            set channel_event_flags [dict create auto_chunked_on_flush 0]
            if {[auto_chunked_on_flush]} {
                dict set channel_event_flags auto_chunked_on_flush 1
            }
            ::tclwire::io flush $channel_event_flags
            return
        }

        tailcall native_flush {*}$args
    }

    proc fconfigure {args} {
        if {[llength $args] == 0} {
            tailcall native_fconfigure {*}$args
        }
        set channel [lindex $args 0]
        if {$channel eq "stdout"} {
            tailcall stdout_fconfigure {*}[lrange $args 1 end]
        }
        tailcall native_fconfigure {*}$args
    }

    proc chan_puts_channel {args} {
        if {[llength $args] > 0 && [lindex $args 0] eq "-nonewline"} {
            set args [lrange $args 1 end]
        }

        switch -exact -- [llength $args] {
            1 {
                return stdout
            }
            2 {
                return [lindex $args 0]
            }
            default {
                return {}
            }
        }
    }

    proc chan {args} {
        if {[llength $args] == 0} {
            tailcall native_chan {*}$args
        }

        set subcommand [lindex $args 0]
        set subargs [lrange $args 1 end]
        switch -exact -- $subcommand {
            configure {
                if {[llength $subargs] == 0} {
                    tailcall native_chan {*}$args
                }
                set channel [lindex $subargs 0]
                if {$channel ne "stdout"} {
                    tailcall native_chan {*}$args
                }
                tailcall stdout_fconfigure {*}[lrange $subargs 1 end]
            }
            flush {
                if {[llength $subargs] != 1} {
                    tailcall native_chan {*}$args
                }
                set channel [lindex $subargs 0]
                if {$channel ne "stdout"} {
                    tailcall native_chan {*}$args
                }
                if {[transaction_active]} {
                    tailcall flush stdout
                }
                tailcall native_chan {*}$args
            }
            puts {
                set puts_args $subargs
                set channel [chan_puts_channel {*}$puts_args]
                if {$channel eq {}} {
                    tailcall native_chan {*}$args
                }
                if {$channel ne "stdout"} {
                    tailcall native_chan {*}$args
                }
                tailcall puts {*}$puts_args
            }
        }
        tailcall native_chan {*}$args
    }

    namespace export object name requires path_namespaces \
                     application_configuration configuration \
                     enabled install uninstall puts flush fconfigure chan \
                     stdout_body_mode set_stdout_body_mode \
                     auto_chunked_on_flush
    namespace ensemble create
}

package provide tclwire::stdchans 0.1
