package require tclwire::environment 0.1
package require tclwire::logger::client

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

    method do_install {} {
        set configuration [my configuration]
        ::tclwire::logger log_error rivetweb "rivetweb conf $configuration" info
        if {[dict exists $configuration rivetweb_root]} {
            set ::rweb_root [dict get $configuration rivetweb_root]
        } else {
            set ::rweb_root "rivetweb"
        }

        set ::website_root [file normalize [file join $::rweb_root website]]
        namespace eval :: { source [file join $::rweb_root init.tcl] }

        set auto_path [list $::website_root $rivetweb_root {*}$::auto_path]
        return
    }

    method do_uninstall {} {
        return
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
                     application_configuration configuration enabled install uninstall
    namespace ensemble create
}

package provide tclwire::rivetweb 0.1
