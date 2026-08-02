# http_query.tcl --
#
# Reusable URL query decoding for HTTP applications.

namespace eval ::tclwire {}

namespace eval ::tclwire::http::query {
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
            } elseif {$byte == 0x20} {
                append encoded +
            } else {
                append encoded %[format %02x $byte]
            }
        }
        return $encoded
    }

    proc encode {pairs} {
        set fields {}
        foreach {name value} $pairs {
            lappend fields "[encode_component $name]=[encode_component $value]"
        }
        return [join $fields &]
    }

    proc decode_component {urlencoded_component} {
        set decoded_bytes [binary format a* {}]

        for {set character_index 0} {
            $character_index < [string length $urlencoded_component]
        } {incr character_index} {
            set character [string index $urlencoded_component $character_index]
            if {$character eq "+"} {
                append decoded_bytes " "
            } elseif {$character eq "%"} {
                if {$character_index + 2 >= [string length $urlencoded_component]} {
                    error "incomplete percent escape in URL query"
                }
                set hexadecimal_octet [string range $urlencoded_component \
                    $character_index+1 \
                    $character_index+2]
                if {![regexp {^[0-9A-Fa-f]{2}$} $hexadecimal_octet]} {
                    error "invalid percent escape in URL query"
                }
                append decoded_bytes [binary format H2 $hexadecimal_octet]
                incr character_index 2
            } else {
                append decoded_bytes [encoding convertto utf-8 $character]
            }
        }

        return [encoding convertfrom utf-8 $decoded_bytes]
    }

    proc decode {urlencoded_query} {
        set parameters [dict create]

        foreach urlencoded_field [split $urlencoded_query &] {
            if {$urlencoded_field eq {}} {
                continue
            }

            set separator_index [string first = $urlencoded_field]
            if {$separator_index < 0} {
                set urlencoded_name $urlencoded_field
                set urlencoded_value {}
            } else {
                set urlencoded_name [string range $urlencoded_field \
                    0 $separator_index-1]
                set urlencoded_value [string range $urlencoded_field \
                    $separator_index+1 end]
            }
            dict set parameters \
                [decode_component $urlencoded_name] \
                [decode_component $urlencoded_value]
        }

        return $parameters
    }

    namespace export decode decode_component encode encode_component
    namespace ensemble create
}

package provide tclwire::http::query 0.1
