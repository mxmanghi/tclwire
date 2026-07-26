# application_tools.tcl --
#
# Request-scoped helper commands for content generator applications.

namespace eval ::tclwire {}

namespace eval ::tclwire::tools {
    variable request_descriptor {}

    proc begin {descriptor} {
        variable request_descriptor
        if {[catch {dict size $descriptor}]} {
            error "request descriptor must be a dictionary"
        }
        set request_descriptor $descriptor
        return
    }

    proc end {} {
        variable request_descriptor
        set request_descriptor {}
        return
    }

    proc current_request {} {
        variable request_descriptor
        if {$request_descriptor eq {}} {
            error "no current application request is active"
        }
        return $request_descriptor
    }

    proc request_scheme {descriptor} {
        if {[dict exists $descriptor scheme]} {
            return [dict get $descriptor scheme]
        }
        if {[dict exists $descriptor protocol]} {
            switch -exact -- [dict get $descriptor protocol] {
                https { return https }
                http  { return http }
            }
        }
        return http
    }

    proc request_authority {descriptor} {
        if {![dict exists $descriptor headers host]} {
            error "current application request has no Host header"
        }
        set authority [string trim [dict get $descriptor headers host]]
        if {$authority eq {}} {
            error "current application request has an empty Host header"
        }
        return $authority
    }

    proc origin_url {} {
        set descriptor [current_request]
        return "[request_scheme $descriptor]://[request_authority $descriptor]"
    }

    proc script_path {descriptor} {
        if {![dict exists $descriptor path]} {
            error "current application request has no path"
        }
        set path [dict get $descriptor path]
        if {$path eq {}} {
            return /
        }
        return $path
    }

    proc script_url {} {
        set descriptor [current_request]
        return "[origin_url][script_path $descriptor]"
    }

    proc directory_url {} {
        set url [script_url]
        if {[string match */ $url]} {
            return $url
        }
        set slash [string last / $url]
        return [string range $url 0 $slash]
    }

    proc makeurl {args} {
        if {[llength $args] > 1} {
            error "wrong # args: should be \"makeurl ?path?\""
        }
        if {[llength $args] == 0} {
            return [script_url]
        }

        set path [lindex $args 0]
        if {[string match /* $path]} {
            return "[origin_url]$path"
        }
        return "[directory_url]$path"
    }

    proc load_env {{array_name env}} {
        upvar 1 $array_name target
        set values [array get ::env]
        unset -nocomplain target
        array set target $values
        return
    }

    namespace export directory_url load_env makeurl origin_url script_url
}

package provide tclwire::application::tools 0.1
