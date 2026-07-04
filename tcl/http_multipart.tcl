# http_multipart.tcl --
#
# In-memory MIME multipart parsing for HTTP request bodies.

package require tclwire::http::message 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::http::multipart {
    proc parse_part_headers {header_block} {
        set headers [dict create]
        foreach line [split $header_block "\r\n"] {
            if {$line eq {}} {
                continue
            }
            if {![regexp {^([^:]+):\s*(.*)$} $line -> name value]} {
                error "invalid multipart header"
            }
            dict set headers [string tolower [string trim $name]] $value
        }
        return $headers
    }

    proc parse_content_disposition {value} {
        if {$value eq {}} {
            return [dict create type {} parameters [dict create]]
        }
        set fields [::tclwire::http::message split_parameters $value]
        set disposition_type [string tolower [string trim [lindex $fields 0]]]
        set parameters [dict create]
        foreach field [lrange $fields 1 end] {
            if {$field eq {}} {
                continue
            }
            set separator [string first = $field]
            if {$separator < 1} {
                error "invalid Content-Disposition parameter"
            }
            set name [string tolower [string trim \
                [string range $field 0 [expr {$separator - 1}]]]]
            dict set parameters $name \
                [::tclwire::http::message unquote_parameter \
                    [string range $field [expr {$separator + 1}] end]]
        }
        return [dict create type $disposition_type parameters $parameters]
    }

    proc delimiter_at {body boundary start} {
        set delimiter "--$boundary"
        set delimiter_length [string length $delimiter]
        set cursor $start

        while 1 {
            set marker [string first $delimiter $body $cursor]
            if {$marker < 0} {
                return {}
            }
            if {$marker == 0 ||
                    [string range $body [expr {$marker - 2}] \
                        [expr {$marker - 1}]] eq "\r\n"} {
                set line_end [string first "\r\n" $body $marker]
                if {$line_end < 0} {
                    set line_end [string length $body]
                    set next $line_end
                } else {
                    set next [expr {$line_end + 2}]
                }
                set line [string trimright \
                    [string range $body $marker [expr {$line_end - 1}]] \
                    " \t"]
                if {$line eq $delimiter} {
                    return [dict create final 0 marker $marker next $next]
                }
                if {$line eq "${delimiter}--"} {
                    return [dict create final 1 marker $marker next $next]
                }
            }
            set cursor [expr {$marker + $delimiter_length}]
        }
    }

    proc parse_part {part_body} {
        set header_end [string first "\r\n\r\n" $part_body]
        if {$header_end < 0} {
            error "multipart part headers are incomplete"
        }
        set headers [parse_part_headers \
            [string range $part_body 0 [expr {$header_end - 1}]]]
        set body [string range $part_body [expr {$header_end + 4}] end]
        set disposition [parse_content_disposition \
            [::tclwire::http::message header_value \
                $headers content-disposition]]
        set result [dict create headers $headers body $body]
        if {[dict exists $headers content-type]} {
            dict set result content_type [dict get $headers content-type]
        }
        if {[dict get $disposition type] ne {}} {
            dict set result disposition [dict get $disposition type]
        }
        foreach field {name filename} {
            if {[dict exists $disposition parameters $field]} {
                dict set result $field [dict get $disposition parameters $field]
            }
        }
        return $result
    }

    proc parse {content_type body} {
        set content_info [::tclwire::http::message parse_content_type $content_type]
        set media_type [dict get $content_info media_type]
        if {![string match multipart/* $media_type]} {
            error "request Content-Type is not multipart"
        }
        if {![dict exists $content_info parameters boundary] ||
                [dict get $content_info parameters boundary] eq {}} {
            error "multipart Content-Type is missing boundary"
        }
        set boundary [dict get $content_info parameters boundary]

        set first [delimiter_at $body $boundary 0]
        if {$first eq {}} {
            error "multipart boundary was not found"
        }
        if {[dict get $first final]} {
            return {}
        }

        set parts {}
        set cursor [dict get $first next]
        while 1 {
            set next [delimiter_at $body $boundary $cursor]
            if {$next eq {}} {
                error "multipart closing boundary was not found"
            }

            set part_end [expr {[dict get $next marker] - 1}]
            if {$part_end >= 1 &&
                    [string range $body [expr {$part_end - 1}] $part_end] \
                        eq "\r\n"} {
                incr part_end -2
            }
            lappend parts [parse_part \
                [string range $body $cursor $part_end]]

            if {[dict get $next final]} {
                return $parts
            }
            set cursor [dict get $next next]
        }
    }

    proc form_fields {parts} {
        set fields [dict create]
        foreach part $parts {
            if {[dict exists $part name] && ![dict exists $part filename]} {
                dict set fields [dict get $part name] [dict get $part body]
            }
        }
        return $fields
    }

    proc field_values {parts name} {
        set values {}
        foreach part $parts {
            if {[dict exists $part name] &&
                    [dict get $part name] eq $name &&
                    ![dict exists $part filename]} {
                lappend values [dict get $part body]
            }
        }
        return $values
    }

    proc files {parts {name {}}} {
        set files {}
        foreach part $parts {
            if {![dict exists $part filename]} {
                continue
            }
            if {$name ne {} &&
                    (![dict exists $part name] || [dict get $part name] ne $name)} {
                continue
            }
            lappend files $part
        }
        return $files
    }

    proc store_files {parts upload_area} {
        if {$upload_area eq {}} {
            error "multipart upload area must not be empty"
        }
        file mkdir $upload_area
        if {![file isdirectory $upload_area] || ![file writable $upload_area]} {
            error "multipart upload area is not writable: $upload_area"
        }

        set stored {}
        try {
            foreach part $parts {
                if {![dict exists $part filename]} {
                    lappend stored $part
                    continue
                }
                set channel [file tempfile path \
                    [file join $upload_area tclwire-upload-XXXXXXXX]]
                try {
                    chan configure $channel -translation binary -encoding binary
                    puts -nonewline $channel [dict get $part body]
                } finally {
                    close $channel
                }
                dict set part body_mode spooled_file
                dict set part path $path
                dict set part body_size [string length [dict get $part body]]
                dict unset part body
                lappend stored $part
            }
        } on error {message options} {
            foreach part $stored {
                if {[dict exists $part path]} {
                    catch {file delete [dict get $part path]}
                }
            }
            return -options $options $message
        }
        return $stored
    }

    namespace export parse form_fields field_values files store_files
    namespace ensemble create
}

package provide tclwire::http::multipart 0.1
