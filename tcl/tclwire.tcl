#!/usr/bin/env tclsh
#
# tclwire.tcl --
#
# TclWire runtime package and executable entry point.
#
# The runtime implementation is split into focused modules sourced below. This
# file keeps package loading, namespace bootstrap, package provide, and direct
# script execution in one place so existing callers can continue to either
# `package require tclwire::runtime` or execute `tcl/tclwire.tcl`.

set ::tclwire_runtime_root [file dirname [file dirname [file normalize [info script]]]]
set ::auto_path [linsert [lsearch -all -inline -not -exact \
    $::auto_path $::tclwire_runtime_root] 0 $::tclwire_runtime_root]

package require tclwire::support 0.1
package require tclwire::constants 0.1
package require tclwire::accounting 1.2
package require tclwire::tpba::control 0.1
package require tclwire::logger::control 0.1
package require tclwire::application_dispatcher 0.1
package require tclwire::transport_reactor 0.1
package require tclwire::console::reactor 0.1
package require tclwire::chore 0.1
package require tclwire::diagnostics 0.1
package require tomlfile 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::runtime {
    variable active 0
    variable active_config {}
    variable shutdown_requested 0
    variable transport_reactors [dict create]
    variable console_reactor {}
    variable application_dispatcher {}
}

foreach script {
    runtime_protocols.tcl
    runtime_config.tcl
    runtime_chores.tcl
    runtime_services.tcl
    runtime_lifecycle.tcl
} {
    source [file join [file dirname [info script]] $script]
}

package provide tclwire::runtime 0.1

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {::tclwire::runtime run $::argv} message options]} {
        if {[dict get $options -errorcode] eq {TCLWIRE USAGE}} {
            puts stderr $message
            ::tclwire::runtime usage stderr
        } else {
            puts stderr [dict get $options -errorinfo]
        }
        exit 1
    }
}

unset ::tclwire_runtime_root
