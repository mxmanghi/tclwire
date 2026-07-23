# constants.tcl --
#
# Shared TclWire values with intentionally selected internal representations.

namespace eval ::tclwire {
    proc define_constant {name value} {
        if {[string match *::* $name]} {
            error "constant variable name must be unqualified: $name"
        }
        if {[llength [info commands ::const]]} {
            uplevel 1 [list ::const $name $value]
        } else {
            uplevel 1 [list variable $name $value]
        }
    }

    define_constant empty_bytearray [binary format a* {}]
}

package provide tclwire::constants 0.1
