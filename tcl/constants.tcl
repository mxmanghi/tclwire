# constants.tcl --
#
# Shared TclWire values with intentionally selected internal representations.

namespace eval ::tclwire {
    if {[llength [info commands const]]} {
        const empty_bytearray [binary format a* {}]
    } else {
        variable empty_bytearray [binary format a* {}]
    }
}

package provide tclwire::constants 0.1
