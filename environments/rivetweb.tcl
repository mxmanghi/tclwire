package require tclwire::environment 0.1
package require tclwire::logger::client
package require tclwire::rivet

source [file join [file dirname [info script]] rivetweb_app.tcl]

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::rivetweb {}

oo::class create ::tclwire::envs::Rivetweb {
    superclass ::tclwire::ApplicationEnvironment

    method name {} { return rivetweb }

    method requires {} { return rivet }

    method path_namespaces {} {
        return { ::rivetweb }
    }

    method environment_configuration_defaults {{application_descriptor {}}} {
        set defaults [dict create]
        if {[dict exists $application_descriptor docroot]} {
            dict set defaults rivetweb website_root \
                [dict get $application_descriptor docroot]
        }
        return $defaults
    }

    method do_install {} {
        set configuration [my configuration]
        set logger [::tclwire::logger::getlogger]
        $logger log_error rivetweb "rivetweb conf $configuration" info
        if {[dict exists $configuration rivetweb_root]} {
            set ::rweb_root [dict get $configuration rivetweb_root]
        } else {
            set ::rweb_root "rivetweb"
        }
        if {[dict exists $configuration website_root]} {
            set ::website_root [dict get $configuration website_root]
        } else {
            set ::website_root [file join rivetweb website]
        }
        set auto_path [list $::website_root $::rweb_root {*}$::auto_path]

        namespace eval :: { source [file join $::rweb_root init.tcl] }
        return
    }

    method do_uninstall {} {
        return
    }

    method application_class {} {
        return ::tclwire::envs::app::Rivetweb
    }

    method application_file {} {
        return [file normalize [file join [file dirname [info script]] rivetweb_app.tcl]]
    }
}

namespace eval ::tclwire::envs::rivetweb {
    variable rivetweb_o [::tclwire::envs::Rivetweb new]

    proc object {} {
        variable rivetweb_o
        return $rivetweb_o
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

    namespace export object name requires path_namespaces \
                     application_class application_file \
                     application_configuration configuration enabled install uninstall
    namespace ensemble create
}

package provide tclwire::rivetweb 0.1
