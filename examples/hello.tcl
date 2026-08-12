package require tclwire::application 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::app {}

oo::class create Hello {
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
        ::tclwire::io response 200 OK [list "Content-Type: text/html; charset=[my encoding]"] \
                               text [my encoding]

        ::tclwire::io out "<html><head><title>Hello from Tclwire</title></head>"
        ::tclwire::io out "<div>$message</div>\n"

        ::tclwire::io out "<table>"
        ::tclwire::io out "<tr><td>Namespace</td><td>[namespace current]</td></tr>"
        ::tclwire::io out "<tr><td>App Object</td><td>[self]</td></tr>"
        ::tclwire::io out "<tr><td>App class</td><td>[info object class [self]]</td></tr>"
        ::tclwire::io out "<tr><td>App namespace</td><td>[info object namespace [self]]</td></tr>"
        ::tclwire::io out "</table><hr />"

        puts "<pre> stdchans present: [::tclwire::cga::has_environment stdchans]</pre>"
        if {[::tclwire::cga::has_environment stdchans]} {
            puts "<pre>running within the stdchans environment. I'm sending output with puts</pre>"
            set n 5
            while {[incr n -1] > 0} {
                puts -nonewline ".....$n"
                flush stdout
                after 500
            }
        } else {
            puts "<pre>We are not running within the stdchans environment</pre>"
        }
        ::tclwire::io out "</html>"

        return
    }
}

oo::class create ::tclwire::Hello {
    superclass ::tclwire::app::Hello
}

package provide tclwire::hello 0.1
