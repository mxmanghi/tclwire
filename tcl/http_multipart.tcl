# http_multipart.tcl --
#
# MIME multipart parsing for HTTP request bodies.

package require tclwire::http::message 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::http::multipart {

    # -- parse_part_headers

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
                [string range $field 0 $separator-1]]]
            dict set parameters $name \
                [::tclwire::http::message unquote_parameter \
                    [string range $field $separator+1 end]]
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
            if {$marker == 0 || [string range $body $marker-2 $marker-1] eq "\r\n"} {
                set line_end [string first "\r\n" $body $marker]
                if {$line_end < 0} {
                    set line_end [string length $body]
                    set next $line_end
                } else {
                    set next [expr {$line_end + 2}]
                }
                set line [string trimright \
                    [string range $body $marker $line_end-1] \
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
            [string range $part_body 0 $header_end-1]]
        set body [string range $part_body $header_end+4 end]
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
                    [string range $body $part_end-1 $part_end] \
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
                    [file join $upload_area tclwire-upload]]
                try {
                    chan configure $channel -translation binary -encoding binary
                    puts -nonewline $channel [dict get $part body]
                } finally {
                    close $channel
                }
                dict set part body_storage spooled_file
                dict set part path $path
                dict set part body_path $path
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

    proc cleanup_files {parts} {
        set failures {}
        foreach part $parts {
            if {![dict exists $part body_storage] ||
                    [dict get $part body_storage] ne "spooled_file" ||
                    ![dict exists $part path]} {
                continue
            }
            set path [dict get $part path]
            if {![file exists $path] &&
                    [catch {file lstat $path path_info}]} {
                continue
            }
            if {[catch {file delete $path} message options]} {
                lappend failures [dict create \
                    path $path message $message options $options]
            }
        }
        return $failures
    }

    namespace export parse form_fields field_values files store_files cleanup_files
    namespace ensemble create
}

oo::class create ::tclwire::http::multipart::IncrementalParser {
    variable boundary upload_area state buffer parts
    variable current_part current_channel current_path current_body

    constructor {content_type area} {
        set content_info [::tclwire::http::message parse_content_type $content_type]
        set media_type [dict get $content_info media_type]
        if {![string match multipart/* $media_type]} {
            error "request Content-Type is not multipart"
        }
        if {![dict exists $content_info parameters boundary] ||
             [dict get $content_info parameters boundary] eq {}} {
            error "multipart Content-Type is missing boundary"
        }
        if {$area eq {}} {
            error "multipart upload area must not be empty"
        }
        file mkdir $area
        if {![file isdirectory $area] || ![file writable $area]} {
            error "multipart upload area is not writable: $area"
        }
        set boundary [dict get $content_info parameters boundary]
        set upload_area $area
        set state first_boundary
        set buffer [binary format a* {}]
        set parts {}
        set current_part {}
        set current_channel {}
        set current_path {}
        set current_body [binary format a* {}]
    }

    destructor {
        my abort
    }

    method abort {} {
        if {[info exists current_channel] && ($current_channel ne {})} {
            catch {close $current_channel}
            set current_channel {}
        }
        if {[info exists current_path] && $current_path ne {}} {
            catch {file delete $current_path}
            set current_path {}
        }
        if {[info exists parts]} {
            foreach part $parts {
                if {[dict exists $part body_storage] &&
                        [dict get $part body_storage] eq "spooled_file" &&
                        [dict exists $part path]} {
                    catch {file delete [dict get $part path]}
                }
            }
        }
        return
    }

    method append {bytes} {
        if {$state eq "complete"} {
            if {$bytes ne {}} {
                error "multipart data after closing boundary"
            }
            return
        }
        append buffer $bytes
        my parse_available
        return
    }

    method parse_available {} {
        while 1 {
            switch -exact -- $state {
                first_boundary {
                    if {![my consume_boundary_line 1]} { return }
                }
                part_headers {
                    set header_end [string first "\r\n\r\n" $buffer]
                    if {$header_end < 0} { return }
                    set header_block [string range $buffer 0 $header_end-1]
                    set buffer [string range $buffer $header_end+4 end]
                    my start_part $header_block
                    set state part_body
                }
                part_body {
                    if {![my consume_part_body]} { return }
                }
                complete {
                    return
                }
                default {
                    error "invalid multipart parser state: $state"
                }
            }
        }
    }

    method consume_boundary_line {first} {
        set delimiter "--$boundary"
        set line_end [string first "\r\n" $buffer]
        if {$line_end < 0} { return 0 }
        set line [string trimright [string range $buffer 0 $line_end-1] " \t"]
        if {$line eq $delimiter} {
            set buffer [string range $buffer $line_end+2 end]
            set state part_headers
            return 1
        }
        if {$line eq "${delimiter}--"} {
            set buffer [string range $buffer $line_end+2 end]
            set state complete
            return 1
        }
        if {$first} {
            error "multipart boundary was not found"
        }
        error "invalid multipart boundary"
    }

    method start_part {header_block} {
        set headers [::tclwire::http::multipart::parse_part_headers $header_block]
        set disposition [::tclwire::http::multipart::parse_content_disposition \
            [::tclwire::http::message header_value \
                $headers content-disposition]]
        set current_part [dict create headers $headers]
        if {[dict exists $headers content-type]} {
            dict set current_part content_type [dict get $headers content-type]
        }
        if {[dict get $disposition type] ne {}} {
            dict set current_part disposition [dict get $disposition type]
        }
        foreach field {name filename} {
            if {[dict exists $disposition parameters $field]} {
                dict set current_part $field [dict get $disposition parameters $field]
            }
        }
        set current_body [binary format a* {}]
        set current_channel {}
        set current_path {}
        if {[dict exists $current_part filename]} {
            set current_channel \
                    [file tempfile current_path [file join $upload_area tclwire-upload]]
            chan configure $current_channel -translation binary -encoding binary
        }
        return
    }

    method append_part_data {bytes} {
        if {$bytes eq {}} { return }
        if {$current_channel ne {}} {
            puts -nonewline $current_channel $bytes
        } else {
            append current_body $bytes
        }
        return
    }

    method finish_part {} {
        if {$current_channel ne {}} {
            close $current_channel
            set current_channel {}
            dict set current_part body_storage spooled_file
            dict set current_part path $current_path
            dict set current_part body_path $current_path
            dict set current_part body_size [file size $current_path]
            set current_path {}
        } else {
            dict set current_part body $current_body
        }
        lappend parts $current_part
        set current_part {}
        set current_body [binary format a* {}]
        return
    }

    method consume_part_body {} {
        set marker "\r\n--$boundary"
        set marker_at [string first $marker $buffer]
        if {$marker_at < 0} {
            set keep [expr {[string length $marker] + 4}]
            set flush_length [expr {[string length $buffer] - $keep}]
            if {$flush_length > 0} {
                my append_part_data [string range $buffer 0 $flush_length-1]
                set buffer [string range $buffer $flush_length end]
            }
            return 0
        }

        set line_start [expr {$marker_at + 2}]
        set line_end [string first "\r\n" $buffer $line_start]
        if {$line_end < 0} { return 0 }

        my append_part_data [string range $buffer 0 $marker_at-1]
        my finish_part

        set line [string trimright [string range $buffer $line_start $line_end-1] " \t"]
        set buffer [string range $buffer $line_end+2 end]
        if {$line eq "--$boundary"} {
            set state part_headers
            return 1
        }
        if {$line eq "--$boundary--"} {
            set state complete
            return 1
        }
        error "invalid multipart boundary"
    }

    method finish {} {
        my parse_available
        if {$state ne "complete"} {
            error "multipart closing boundary was not found"
        }
        set result $parts
        # Ownership of spooled part files passes to the completed request
        # descriptor.  The parser must not delete them during destruction.
        set parts {}
        return $result
    }
}

package provide tclwire::http::multipart 0.1
