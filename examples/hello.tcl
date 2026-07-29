package require tclwire::application 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::app {}

oo::class create ::tclwire::app::Hello {
    superclass ::tclwire::CApplication

    variable message

    constructor {application_descriptor} {
        next $application_descriptor

        set message "Hello from TclWire"
        set options [[my configuration_object] class_configuration [info object class [self]]]
        if {[dict exists $options message]} {
            set message [dict get $options message]
        }
    }

    method handle_request {request} {
        ::tclwire::io response  200 OK \
                                [list "Content-Type: text/plain; charset=[my encoding]"] \
                                text    \
                                [my encoding]

        ::tclwire::io out "$message\n"
        return
    }
}

oo::class create ::tclwire::Hello {
    superclass ::tclwire::app::Hello
}

package provide tclwire::hello 0.1
