# rivet_parser.tcl --
#
# Thin Tcl compatibility layer for Apache Rivet's standalone parser package.

package require fileutil
package require tclwire::template_cache 0.1

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
        set literal_start 0
        set code_start -1
        set opening_delimiter -1

        # Each match has three index pairs: the complete delimiter, the opening
        # delimiter capture, and the closing delimiter capture.  Captures that
        # did not participate are {-1 -1}, which makes the stream self-tagging.
        set delimiters [regexp -indices -all -inline {(<\?)|(\?>)} $template]
        foreach {delimiter opening closing} $delimiters {
            lassign $delimiter delimiter_start delimiter_end
            lassign $opening opening_start

            if {$opening_start >= 0} {
                if {$code_start >= 0} {
                    error "unexpected Rivet template opening delimiter at character $delimiter_start"
                }
                append_literal script \
                    [string range $template $literal_start $delimiter_start-1]
                set code_start [expr {$delimiter_end + 1}]
                set opening_delimiter $delimiter_start
                continue
            }

            if {$code_start < 0} {
                error "unexpected Rivet template closing delimiter at character $delimiter_start"
            }

            set code [string range $template $code_start $delimiter_start-1]
            if {[string index $template $code_start] eq "="} {
                append script [list puts -nonewline] " " [string range $code 1 end] "\n"
            } else {
                append script $code "\n"
            }
            set literal_start [expr {$delimiter_end + 1}]
            set code_start          -1
            set opening_delimiter   -1
        }

        if {$code_start >= 0} {
            error "unterminated Rivet template Tcl block beginning at character $opening_delimiter"
        }
        append_literal script [string range $template $literal_start end]

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

    proc parse_template_file {path {encoding {}}} {
        return [parse_template [read_template_file $path $encoding]]
    }

    proc parserivetdata {data} {
        return [parse_template $data]
    }

    proc parserivet {filename} {
        set script [parse_template [read_template_file $filename]]
        return "namespace eval ::request {\n$script\n}\n"
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
