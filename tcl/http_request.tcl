# http_request.tcl --
#
# Read-only application view of a transported HTTP request descriptor.

package require TclOO
package require tclwire::http::message 0.1
package require tclwire::http::multipart 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::http::cookie {
    proc validate_name {name} {
        if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name]} {
            error "invalid HTTP cookie name"
        }
        return
    }

    proc validate_value {value} {
        if {![regexp {^[\x21-\x7e]*$} $value] ||
                [regexp {[";,\\]} $value]} {
            error "invalid HTTP cookie value"
        }
        return
    }

    proc validate_path {path} {
        if {![string match /* $path] ||
                [regexp {[\x00-\x20\x7f;]} $path]} {
            error "invalid HTTP cookie path"
        }
        return
    }

    proc validate_domain {domain} {
        if {$domain eq {} ||
                [regexp {[\x00-\x20\x7f;]} $domain] ||
                [string first ";" $domain] >= 0} {
            error "invalid HTTP cookie domain"
        }
        return
    }

    proc validate_expiration {expiration} {
        if {[string is entier -strict $expiration]} {
            set seconds $expiration
        } elseif {[catch {clock scan $expiration} seconds]} {
            error "invalid HTTP cookie expiration"
        }
        if {[catch {
            clock format $seconds -gmt 1 -locale C \
                -format {%a, %d %b %Y %H:%M:%S GMT}
        }]} {
            error "invalid HTTP cookie expiration"
        }
        return
    }

    proc parse_header {value} {
        set cookies {}
        foreach field [split $value ";"] {
            set field [string trim $field]
            if {$field eq {}} {
                continue
            }
            set separator [string first = $field]
            if {$separator < 1} {
                error "invalid HTTP Cookie header"
            }
            set name [string trim [string range $field 0 $separator-1]]
            set cookie_value [string trim [string range $field $separator+1 end]]
            validate_name $name
            validate_value $cookie_value
            lappend cookies [list $name $cookie_value]
        }
        return $cookies
    }
}

oo::class create ::tclwire::CookieJar {
    variable cookies

    constructor {{initial_cookies {}}} {
        set cookies [dict create]
        foreach cookie $initial_cookies {
            my set {*}$cookie
        }
    }

    method get {name {default_value {}}} {
        ::tclwire::http::cookie::validate_name $name
        if {[dict exists $cookies $name]} {
            return [dict get $cookies $name value]
        }
        return $default_value
    }

    method set {name value args} {
        ::tclwire::http::cookie::validate_name $name
        my validate $value

        set options {}
        if {[llength $args] % 2 != 0} {
            error {wrong # args: should be "CookieJar set name value ?-path uriPath? ?-expires expiration?"}
        }
        foreach {option option_value} $args {
            switch -exact -- $option {
                -path {
                    ::tclwire::http::cookie::validate_path $option_value
                    lappend options $option $option_value
                }
                -expires {
                    ::tclwire::http::cookie::validate_expiration $option_value
                    lappend options $option $option_value
                }
                -domain {
                    ::tclwire::http::cookie::validate_domain $option_value
                    lappend options $option $option_value
                }
                -secure -
                -HttpOnly {
                    if {![string is boolean -strict $option_value]} {
                        error "invalid HTTP cookie option value: $option"
                    }
                    lappend options $option [expr {!!$option_value}]
                }
                default {
                    error "unknown HTTP cookie option: $option"
                }
            }
        }

        dict set cookies $name [dict create value $value options $options]
        return $value
    }

    method validate {value} {
        ::tclwire::http::cookie::validate_value $value
        return $value
    }

    method unset {name} {
        ::tclwire::http::cookie::validate_name $name
        dict unset cookies $name
        return
    }

    method serialize {} {
        set serialized {}
        dict for {name spec} $cookies {
            lappend serialized [list $name [dict get $spec value] \
                {*}[dict get $spec options]]
        }
        return $serialized
    }
}

oo::class create ::tclwire::HttpRequest {
    variable request_descriptor
    variable cookie_jar
    variable multipart_parts_cache
    variable multipart_parts_cached

    constructor {descriptor} {
        if {[catch {dict size $descriptor}]} {
            error "HTTP request descriptor must be a dictionary"
        }
        if {[dict exists $descriptor path] && ![dict exists $descriptor url_path]} {
            dict set descriptor url_path [dict get $descriptor path]
        }
        set request_descriptor $descriptor
        set cookie_jar {}
        set multipart_parts_cache {}
        set multipart_parts_cached 0
    }

    destructor {
        if {$cookie_jar ne {}} {
            $cookie_jar destroy
        }
    }

    method required {field} {
        if {![dict exists $request_descriptor $field]} {
            error "HTTP request descriptor is missing $field"
        }
        return [dict get $request_descriptor $field]
    }

    method snapshot {} { return $request_descriptor }

    method optional {field default_value} {
        if {[dict exists $request_descriptor $field]} {
            return [dict get $request_descriptor $field]
        }
        return $default_value
    }

    method method {} {
        return [my required method]
    }

    method target {} {
        return [my required target]
    }

    method url_path {} {
        return [my required url_path]
    }

    method path {args} {
        switch -exact -- [llength $args] {
            0 {
                return [my required path]
            }
            1 {
                set path [lindex $args 0]
            }
            default {
                error {wrong # args: should be "HttpRequest path ?path?"}
            }
        }
        if {![string match "/*" $path]} {
            error "HTTP request path must be absolute"
        }
        dict set request_descriptor path $path
        return $path
    }

    method local_path {args} {
        switch -exact -- [llength $args] {
            0 {
                return [my optional local_path {}]
            }
            1 {
                set path [lindex $args 0]
            }
            default {
                error {wrong # args: should be "HttpRequest local_path ?path?"}
            }
        }

        if {[llength $args] == 1} {
            if {$path eq {}} {
                if {[dict exists $request_descriptor local_path]} {
                    dict unset request_descriptor local_path
                }
                return {}
            }
            set path [file normalize $path]
            dict set request_descriptor local_path $path
            return $path
        }
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

    method cookie_jar {} {
        if {$cookie_jar eq {}} {
            set cookie_jar [::tclwire::CookieJar new \
                [::tclwire::http::cookie::parse_header [my header cookie]]]
        }
        return $cookie_jar
    }

    method scheme {} {
        switch -exact -- [my optional protocol http] {
            https { return https }
            default { return http }
        }
    }

    method authority {} {
        set authority [string trim [my header host]]
        if {$authority eq {}} {
            error "HTTP request has no Host header"
        }
        return $authority
    }

    method origin {} {
        return "[my scheme]://[my authority]"
    }

    method absolute_url {{path {}}} {
        if {$path eq {}} {
            set path [my target]
        }
        if {[string match /* $path]} {
            return "[my origin]$path"
        }

        set directory [my path]
        if {![string match */ $directory]} {
            set slash [string last / $directory]
            set directory [string range $directory 0 $slash]
        }
        return "[my origin]$directory$path"
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
        if {!$multipart_parts_cached} {
            if {[dict exists $request_descriptor multipart_parts]} {
                set multipart_parts_cache [dict get $request_descriptor multipart_parts]
            } else {
                set multipart_parts_cache [::tclwire::http::multipart parse \
                    [my content_type] [my body]]
            }
            set multipart_parts_cached 1
        }
        return $multipart_parts_cache
    }

    method optional_multipart_parts {} {
        if {![my is_multipart]} {
            return {}
        }
        return [my multipart_parts]
    }

    method form_fields {} {
        return [::tclwire::http::multipart form_fields \
            [my optional_multipart_parts]]
    }

    method form_values {name} {
        return [::tclwire::http::multipart field_values \
            [my optional_multipart_parts] $name]
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
            [my optional_multipart_parts] $name]
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

    unexport optional optional_multipart_parts required
}

package provide tclwire::http::request 0.1
