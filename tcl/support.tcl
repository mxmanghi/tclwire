# support.tcl --
#
# Minimal support helpers for the repackaged TclWire runtime.

namespace eval ::tclwire {}

namespace eval ::tclwire::support {
    variable project_root [file dirname [file dirname [file normalize [info script]]]]
    variable debug 0

    proc project_root {} {
        variable project_root
        return $project_root
    }

    proc env_or_default {name default_value} {
        if {[info exists ::env($name)] && $::env($name) ne {}} {
            return $::env($name)
        }
        return $default_value
    }

    proc default_doc_root {} {
        return [file normalize [env_or_default TCLWIRE_DOC_ROOT /tmp/tclwire]]
    }

    proc default_ftp_root {} {
        return [file normalize [env_or_default TCLWIRE_FTP_ROOT [default_doc_root]]]
    }

    proc runtime_doc_source {} {
        variable project_root
        return [file join $project_root runtime-doc]
    }

    proc prepare_doc_root {doc_root {source_root {}}} {
        variable project_root

        set doc_root [file normalize $doc_root]
        if {[file exists $doc_root] && ![file isdirectory $doc_root]} {
            error "document root exists but is not a directory: $doc_root"
        }
        if {[file exists $doc_root]} {
            return $doc_root
        }

        file mkdir $doc_root
        if {$source_root eq {}} {
            set source_root [runtime_doc_source]
        }
        exec [info nameofexecutable] [file join $project_root utils md2html.tcl] \
            --input $source_root \
            --output $doc_root
        return $doc_root
    }

    proc prepare_ftp_root {ftp_root} {
        variable project_root

        set ftp_root [file normalize $ftp_root]
        if {[file exists $ftp_root] && ![file isdirectory $ftp_root]} {
            error "FTP root exists but is not a directory: $ftp_root"
        }
        if {![file exists $ftp_root]} {
            file mkdir $ftp_root
        }

        foreach {source target_name} [list \
                [file join $project_root index.html] index.html \
                [file join $project_root tests tcl9.png] tcl9.png] {
            set target [file join $ftp_root $target_name]
            if {[file isfile $source] && ![file exists $target]} {
                file copy $source $target
            }
        }
        return $ftp_root
    }

    proc configure_debug {{enabled 0}} {
        variable debug
        set debug [expr {$enabled ? 1 : 0}]
        return $debug
    }

    proc debug_enabled {} {
        variable debug
        return $debug
    }

    proc debug {args} {
        if {[debug_enabled]} {
            puts stderr [join $args {}]
        }
        return
    }

    namespace export project_root env_or_default default_doc_root runtime_doc_source \
        default_ftp_root prepare_doc_root prepare_ftp_root configure_debug \
        debug_enabled debug
    namespace ensemble create
}

package provide tclwire::support 0.1
