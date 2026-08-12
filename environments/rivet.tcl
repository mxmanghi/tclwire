# rivet.tcl --
#
# TclWire Apache Rivet compatibility application environment.

package require tclwire::environment 0.1

source [file join [file dirname [info script]] rivet_app.tcl]

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}

oo::class create ::tclwire::envs::RivetEnvironment {
    superclass ::tclwire::ApplicationEnvironment
    variable application_file_path previous_exit_command

    constructor {path} {
        next
        set application_file_path $path
        set previous_exit_command {}
    }

    method name {} {
        return rivet
    }

    method requires {} {
        return {stdchans}
    }

    method path_namespaces {} {
        return {::rivet}
    }

    method application_class {} {
        return ::tclwire::envs::app::Rivet
    }

    method application_file {} {
        variable application_file_path
        return $application_file_path
    }

    method do_install {} {
        variable previous_exit_command

        namespace eval ::Rivet {}
        ::tclwire::envs::rivet::install_commands
        set previous_exit_command [::tclwire::cga::configure_exit_command \
            [list ::tclwire::envs::rivet::exit_request]]
        return
    }

    method do_uninstall {} {
        variable previous_exit_command

        ::tclwire::cga::configure_exit_command $previous_exit_command
        set previous_exit_command {}
        catch {namespace delete ::tclwire::envs::rivet::hooks}
        catch {namespace delete ::rivet}
        catch {namespace delete ::Rivet}
        return
    }
}

namespace eval ::tclwire::envs::rivet {
    variable environment_object [::tclwire::envs::RivetEnvironment new \
        [file normalize [file join [file dirname [info script]] rivet_app.tcl]]]

    proc object {} {
        variable environment_object
        return $environment_object
    }

    proc name {} {
        tailcall [object] name
    }

    proc requires {} {
        tailcall [object] requires
    }

    proc path_namespaces {} {
        tailcall [object] path_namespaces
    }

    proc application_class {} {
        tailcall [object] application_class
    }

    proc application_file {} {
        tailcall [object] application_file
    }

    proc enabled {} {
        tailcall [object] enabled
    }

    proc install {} {
        tailcall [object] install
    }

    proc uninstall {} {
        tailcall [object] uninstall
    }

    namespace export object name requires path_namespaces \
                     application_class application_file \
                     enabled install uninstall
    namespace ensemble create
}

package provide tclwire::rivet 0.1
