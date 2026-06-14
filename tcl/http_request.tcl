# http_request.tcl --
#
# Read-only application view of a transported HTTP request descriptor.

package require TclOO

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpRequest {
    variable descriptor

    constructor {request_descriptor} {
        if {[catch {dict size $request_descriptor}]} {
            error "HTTP request descriptor must be a dictionary"
        }
        set descriptor $request_descriptor
    }

    method required {field} {
        if {![dict exists $descriptor $field]} {
            error "HTTP request descriptor is missing $field"
        }
        return [dict get $descriptor $field]
    }

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

    method body_mode {} {
        return [my optional body_mode none]
    }

    method body {} {
        if {[my body_mode] ne "in_memory"} {
            error "HTTP request body is not stored in memory"
        }
        return [my optional body {}]
    }

    method body_size {} {
        return [my optional body_size 0]
    }

    method trailers {} {
        return [my optional trailers [dict create]]
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
