# http_request.tcl --
#
# Read-only application view of a transported HTTP request descriptor.

package require TclOO
package require tclwire::http::message 0.1
package require tclwire::http::multipart 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpRequest {
    variable descriptor
    variable multipart_parts_cache
    variable multipart_parts_cached

    constructor {request_descriptor} {
        if {[catch {dict size $request_descriptor}]} {
            error "HTTP request descriptor must be a dictionary"
        }
        set descriptor $request_descriptor
        set multipart_parts_cache {}
        set multipart_parts_cached 0
    }

    method required {field} {
        if {![dict exists $descriptor $field]} {
            error "HTTP request descriptor is missing $field"
        }
        return [dict get $descriptor $field]
    }

    method snapshot {} { return $descriptor }

    method optional {field default_value} {
        if {[dict exists $descriptor $field]} {
            return [dict get $descriptor $field]
        }
        return $default_value
    }

    method method {} {
        return [my required method]
    }

    method target {} {
        return [my required target]
    }

    method path {} {
        return [my required path]
    }

    method query {} {
        return [my optional query {}]
    }

    method query_parameters {} {
        return [my optional query_dict [dict create]]
    }

    method query_dict {} {
        return [my query_parameters]
    }

    method query_parameter {name {default_value {}}} {
        set parameters [my query_parameters]
        if {[dict exists $parameters $name]} {
            return [dict get $parameters $name]
        }
        return $default_value
    }

    method version {} {
        return [my required version]
    }

    method headers {} {
        return [my optional headers [dict create]]
    }

    method header {name {default_value {}}} {
        set name [string tolower $name]
        set headers [my headers]
        if {[dict exists $headers $name]} {
            return [dict get $headers $name]
        }
        return $default_value
    }

    method content_type {{default_value {}}} {
        return [my header content-type $default_value]
    }

    method content_type_info {} {
        set value [my content_type]
        if {$value eq {}} {
            error "HTTP request has no Content-Type"
        }
        return [::tclwire::http::message parse_content_type $value]
    }

    method media_type {{default_value {}}} {
        set value [my content_type]
        if {$value eq {}} {
            return $default_value
        }
        return [dict get \
            [::tclwire::http::message parse_content_type $value] media_type]
    }

    method content_type_parameter {name {default_value {}}} {
        set value [my content_type]
        if {$value eq {}} {
            return $default_value
        }
        set parameters [dict get \
            [::tclwire::http::message parse_content_type $value] parameters]
        set name [string tolower $name]
        if {[dict exists $parameters $name]} {
            return [dict get $parameters $name]
        }
        return $default_value
    }

    method is_multipart {} {
        set value [my content_type]
        if {$value eq {}} {
            return 0
        }
        return [expr {
            [string match multipart/* \
                [dict get \
                    [::tclwire::http::message parse_content_type $value] \
                    media_type]]
        }]
    }

    method body_media {} {
        return [my optional body_media raw]
    }

    method body_storage {} {
        return [my optional body_storage none]
    }

    method body {} {
        if {[my body_storage] ne "in_memory"} {
            error "HTTP request body is not stored in memory"
        }
        return [my optional body {}]
    }

    method body_path {} {
        if {[my body_storage] ne "spooled_file"} {
            error "HTTP request body is not stored in a spooled file"
        }
        return [my required body_path]
    }

    method body_size {} {
        return [my optional body_size 0]
    }

    method multipart_parts {} {
        variable multipart_parts_cache
        variable multipart_parts_cached

        if {!$multipart_parts_cached} {
            if {[dict exists $descriptor multipart_parts]} {
                set multipart_parts_cache [dict get $descriptor multipart_parts]
            } else {
                set multipart_parts_cache [::tclwire::http::multipart parse \
                    [my content_type] [my body]]
            }
            set multipart_parts_cached 1
        }
        return $multipart_parts_cache
    }

    method form_fields {} {
        return [::tclwire::http::multipart form_fields \
            [my multipart_parts]]
    }

    method form_values {name} {
        return [::tclwire::http::multipart field_values \
            [my multipart_parts] $name]
    }

    method form_value {name {default_value {}}} {
        set values [my form_values $name]
        if {[llength $values] == 0} {
            return $default_value
        }
        return [lindex $values end]
    }

    method uploaded_files {{name {}}} {
        return [::tclwire::http::multipart files \
            [my multipart_parts] $name]
    }

    method uploaded_file {name} {
        set files [my uploaded_files $name]
        if {[llength $files] == 0} {
            return {}
        }
        return [lindex $files 0]
    }

    method trailers {} {
        return [my optional trailers [dict create]]
    }

    method trailer {name {default_value {}}} {
        set name [string tolower $name]
        set trailers [my trailers]
        if {[dict exists $trailers $name]} {
            return [dict get $trailers $name]
        }
        return $default_value
    }

    method connection_id {} {
        return [my optional connection_id {}]
    }

    method transaction_id {} {
        return [my required transaction_id]
    }

    method remote_host {} {
        return [my optional remote_host {}]
    }

    method remote_port {} {
        return [my optional remote_port {}]
    }

    method application_id {} {
        return [my optional application_id {}]
    }

    unexport optional required
}

package provide tclwire::http::request 0.1
