# rivet.tcl --
#
# TclWire Apache Rivet compatibility application environment.

source [file join [file dirname [info script]] rivet_app.tcl]

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}

namespace eval ::tclwire::envs::rivet {
    variable installed 0

    proc name {} {
        return rivet
    }

    proc requires {} {
        return {stdchans}
    }

    proc path_namespaces {} {
        return {::rivet}
    }

    proc application_class {} {
        return ::tclwire::envs::rivet::Application
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
        namespace eval ::Rivet {}
        namespace eval ::rivet {}
        set installed 1
        return
    }

    proc uninstall {} {
        variable installed

        if {!$installed} {
            return
        }
        catch {namespace delete ::rivet}
        catch {namespace delete ::Rivet}
        set installed 0
        return
    }

    namespace export name requires path_namespaces application_class \
        enabled install uninstall
    namespace ensemble create
}

package provide tclwire::rivet 0.1
