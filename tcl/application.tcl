# application.tcl --
#
# Default TclWire content application.

package require TclOO
package require tclwire::application::io 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::CApplication {
    method handle_request {request_descriptor} {
        ::tclwire::io out \
            {<html><head><title>Hello World</title></head><body><h2>Hello world from <b>TclWire</b></h2></body></html>}
        return
    }
}

package provide tclwire::application 0.1
