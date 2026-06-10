# application.tcl --
#
# Default TclWire content application.

package require TclOO
package require tclwire::application::io 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::CApplication {
    variable configuration document_root

    constructor {application_descriptor} {
        if {[catch {dict size $application_descriptor}]} {
            error "application descriptor must be a dictionary"
        }
        if {![dict exists $application_descriptor docroot]} {
            error "application descriptor is missing docroot"
        }
        set configuration $application_descriptor
        set document_root [file normalize \
            [dict get $application_descriptor docroot]]
    }

    method configuration {} {
        return $configuration
    }

    method document_root {} {
        return $document_root
    }

    method handle_request {request_descriptor} {
        ::tclwire::io out \
            {<html><head><title>Hello World</title></head><body><h2>Hello world from <b>TclWire</b></h2></body></html>}
        return
    }
}

package provide tclwire::application 0.1
