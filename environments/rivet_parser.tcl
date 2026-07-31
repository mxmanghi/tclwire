# rivet_parser.tcl --
#
# Thin Tcl compatibility layer for Apache Rivet's standalone parser package.

package require fileutil

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::tclwire::envs::rivet {}
namespace eval ::tclwire::envs::rivet::parser {}
namespace eval ::rivet {}

namespace eval ::tclwire::envs::rivet::parser {
    proc append_literal {script_variable literal} {
        upvar 1 $script_variable script
        if {$literal eq {}} {
            return
        }
        append script [list puts -nonewline $literal] "\n"
        return
    }

    proc parse_template {template} {
        set script {}
        set offset 0
        set length [string length $template]

        while {$offset < $length} {
            set start [string first "<?" $template $offset]
            if {$start < 0} {
                append_literal script [string range $template $offset end]
                break
            }

            append_literal script [string range $template $offset $start-1]
            set code_start [expr {$start + 2}]
            set echo 0
            if {[string index $template $code_start] eq "="} {
                set echo 1
                incr code_start
            }

            set end [string first "?>" $template $code_start]
            if {$end < 0} {
                error "unterminated Rivet template Tcl block"
            }

            set code [string range $template $code_start $end-1]
            if {$echo} {
                append script [list puts -nonewline] " " $code "\n"
            } else {
                append script $code "\n"
            }
            set offset [expr {$end + 2}]
        }

        return $script
    }

    proc read_template_file {path {encoding {}}} {
        if {$encoding eq {}} {
            return [fileutil::cat $path]
        }
        if {$encoding ni [encoding names]} {
            error "unknown encoding \"$encoding\""
        }
        set channel [open $path r]
        try {
            chan configure $channel -encoding $encoding -translation binary
            return [read $channel]
        } finally {
            close $channel
        }
    }

    proc parserivetdata {data} {
        return [parse_template $data]
    }

    proc parserivet {filename} {
        set script [parse_template [read_template_file $filename]]
        return "namespace eval request {\n$script\n}\n"
    }

    proc install_commands {} {
        namespace eval ::rivet {}

        proc ::rivet::parserivetdata {data} {
            tailcall ::tclwire::envs::rivet::parser::parserivetdata $data
        }

        proc ::rivet::parserivet {filename} {
            tailcall ::tclwire::envs::rivet::parser::parserivet $filename
        }
        return
    }
}

::tclwire::envs::rivet::parser::install_commands

if {[package provide rivetparser] eq {}} {
    package provide rivetparser 1.0
}
if {[package provide librivetparser] eq {}} {
    package provide librivetparser 1.0
}
