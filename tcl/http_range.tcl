# http_range.tcl --
#
# Reusable HTTP byte-range parsing and multipart response construction.

namespace eval ::tclwire::http::range {
    # Classify the raw value following the `Range:` field name. For example,
    # `Range: bytes=2-5,8-9` supplies `bytes=2-5,8-9` as range_value.
    proc classify {range_value total_length} {
        if {![string is integer -strict $total_length] || $total_length < 0} {
            error "invalid representation length"
        }
        if {![regexp -nocase {^([^=]+)=(.*)$} \
                [string trim $range_value] -> unit range_set]} {
            return [dict create status malformed ranges {}]
        }
        if {![string equal -nocase [string trim $unit] bytes]} {
            return [dict create status unsupported ranges {}]
        }
        if {[string trim $range_set] eq {}} {
            return [dict create status malformed ranges {}]
        }

        set ranges {}
        foreach item [split $range_set ,] {
            set item [string trim $item]
            if {![regexp {^([0-9]*)-([0-9]*)$} $item -> first last] ||
                    ($first eq {} && $last eq {})} {
                return [dict create status malformed ranges {}]
            }

            if {$first eq {}} {
                if {$last == 0 || $total_length == 0} {
                    continue
                }
                set start [expr {max(0, $total_length - $last)}]
                set end [expr {$total_length - 1}]
            } else {
                set start $first
                if {$start >= $total_length} {
                    continue
                }
                if {$last eq {}} {
                    set end [expr {$total_length - 1}]
                } else {
                    if {$start > $last} {
                        continue
                    }
                    set end [expr {min($last, $total_length - 1)}]
                }
            }
            lappend ranges [list $start $end]
        }

        if {[llength $ranges] == 0} {
            return [dict create status unsatisfiable ranges {}]
        }
        return [dict create status satisfiable ranges $ranges]
    }

    proc multipart_part {
        data start end content_type total_length boundary
    } {
        set part [binary format a* {}]
        append part "--$boundary\r\n"
        append part "Content-Type: $content_type\r\n"
        append part "Content-Range: bytes $start-$end/$total_length\r\n\r\n"
        append part $data "\r\n"
        return $part
    }

    proc multipart_end {boundary} {
        return "--$boundary--\r\n"
    }

    proc boundary {} {
        return "tclwire-[pid]-[clock clicks]"
    }

    namespace export classify multipart_part multipart_end boundary
    namespace ensemble create
}

package provide tclwire::http::range 0.1
