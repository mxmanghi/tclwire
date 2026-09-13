# http_path.tcl --
#
# Percent encoding and decoding for HTTP URL paths.

package require tclwire::constants 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::http {}

namespace eval ::tclwire::http::path {
    # Encode one path segment. RFC 3986 unreserved octets remain literal;
    # every other UTF-8 octet is percent-encoded. In particular, spaces are
    # encoded as %20 rather than the form/query encoding '+'.
    proc encode_component {component} {
        set encoded {}
        binary scan [encoding convertto utf-8 $component] cu* bytes
        foreach byte $bytes {
            if {($byte >= 0x30 && $byte <= 0x39) ||
                    ($byte >= 0x41 && $byte <= 0x5a) ||
                    ($byte >= 0x61 && $byte <= 0x7a) ||
                    $byte == 0x2d ||
                    $byte == 0x2e ||
                    $byte == 0x5f ||
                    $byte == 0x7e} {
                append encoded [format %c $byte]
            } else {
                append encoded %[format %02X $byte]
            }
        }
        return $encoded
    }

    # Encode a complete path while retaining its slash separators.
    proc encode {path} {
        set encoded_components {}
        foreach component [split $path /] {
            lappend encoded_components [encode_component $component]
        }
        return [join $encoded_components /]
    }

    proc decode {path} {
        set bytes $::tclwire::constants::empty_bytearray
        for {set i 0} {$i < [string length $path]} {incr i} {
            set character [string index $path $i]
            if {$character eq "\x00"} {
                error "URL path contains a null byte"
            }
            if {$character eq "%"} {
                if {$i + 2 >= [string length $path]} {
                    error "incomplete percent escape in URL path"
                }
                set hex [string range $path $i+1 $i+2]
                if {![regexp {^[0-9A-Fa-f]{2}$} $hex]} {
                    error "invalid percent escape in URL path"
                }
                if {[string equal -nocase $hex 00]} {
                    error "URL path contains a null byte"
                }
                append bytes [binary format H2 $hex]
                incr i 2
            } else {
                append bytes [encoding convertto utf-8 $character]
            }
        }
        return [encoding convertfrom utf-8 $bytes]
    }

    namespace export decode encode encode_component
    namespace ensemble create
}

package provide tclwire::http::path 0.1
