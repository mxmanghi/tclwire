# http_application_io.tcl --
#
# HTTP-specific response controls for Content Generator Agents.

package require tclwire::application::io 0.1

namespace eval ::tclwire::http {}

proc ::tclwire::http::no_body {} {
    ::tclwire::http::io::reset_if_needed
    ::tclwire::io discard_buffer
    ::tclwire::io::send_event no_body
    return
}

namespace eval ::tclwire::http::io {
    variable context_key {}
    variable headers {}

    proc reset_if_needed {} {
        variable context_key
        variable headers

        set context [::tclwire::io context]
        if {![dict get $context active]} {
            error "no application output transaction is active"
        }
        set current_key [list \
            [dict get $context connection_thread_id] \
            [dict get $context connection_agent_id] \
            [dict get $context transaction_id]]
        if {$context_key ne $current_key} {
            set context_key $current_key
            set headers {}
        }
        return
    }

    proc validate_header {name {value {}}} {
        if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name]} {
            error "invalid HTTP response header name"
        }
        if {[string first "\r" $value] >= 0 ||
                [string first "\n" $value] >= 0} {
            error "invalid HTTP response header value"
        }
        return
    }

    proc matching_header {left right} {
        return [string equal -nocase $left $right]
    }

    proc validate_cookie_name {name} {
        if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name]} {
            error "invalid HTTP cookie name"
        }
        return
    }

    proc validate_cookie_value {value} {
        if {![regexp {^[\x21-\x7e]*$} $value] ||
                [regexp {[";,\\]} $value]} {
            error "invalid HTTP cookie value"
        }
        return
    }

    proc validate_cookie_path {path} {
        if {![string match /* $path] ||
                [regexp {[\x00-\x20\x7f;]} $path]} {
            error "invalid HTTP cookie path"
        }
        return
    }

    proc cookie_expiration {expiration} {
        if {[string is entier -strict $expiration]} {
            set seconds $expiration
        } elseif {[catch {clock scan $expiration} seconds]} {
            error "invalid HTTP cookie expiration"
        }
        if {[catch {
            clock format $seconds -gmt 1 -locale C \
                -format {%a, %d %b %Y %H:%M:%S GMT}
        } formatted]} {
            error "invalid HTTP cookie expiration"
        }
        return $formatted
    }

    proc cookie {name value args} {
        reset_if_needed
        validate_cookie_name $name
        validate_cookie_value $value

        set path {}
        set expiration {}
        if {[llength $args] % 2 != 0} {
            error {wrong # args: should be "::tclwire::http::io cookie name value ?-path uriPath? ?-expires expiration?"}
        }
        foreach {option option_value} $args {
            switch -exact -- $option {
                -path {
                    validate_cookie_path $option_value
                    set path $option_value
                }
                -expires {
                    set expiration [cookie_expiration $option_value]
                }
                default {
                    error "unknown HTTP cookie option: $option"
                }
            }
        }

        set cookie "$name=$value"
        if {$path ne {}} {
            append cookie "; Path=$path"
        }
        if {$expiration ne {}} {
            append cookie "; Expires=$expiration"
        }
        header_add Set-Cookie $cookie
        return $cookie
    }

    proc header_set {name value} {
        variable headers
        reset_if_needed
        validate_header $name $value

        set updated {}
        foreach header $headers {
            if {![matching_header [lindex $header 0] $name]} {
                lappend updated $header
            }
        }
        lappend updated [list $name $value]
        set headers $updated
        ::tclwire::io::send_event http_header {} \
            [dict create action set name $name value $value]
        return $value
    }

    proc header_add {name value} {
        variable headers
        reset_if_needed
        validate_header $name $value

        lappend headers [list $name $value]
        ::tclwire::io::send_event http_header {} \
            [dict create action add name $name value $value]
        return $value
    }

    proc header_remove {name} {
        variable headers
        reset_if_needed
        validate_header $name

        set updated {}
        foreach header $headers {
            if {![matching_header [lindex $header 0] $name]} {
                lappend updated $header
            }
        }
        set headers $updated
        ::tclwire::io::send_event http_header {} \
            [dict create action remove name $name]
        return
    }

    proc header_get {name} {
        variable headers
        reset_if_needed
        validate_header $name

        set values {}
        foreach header $headers {
            if {[matching_header [lindex $header 0] $name]} {
                lappend values [lindex $header 1]
            }
        }
        return $values
    }

    proc header {operation args} {
        switch -exact -- $operation {
            set {
                if {[llength $args] != 2} {
                    error {wrong # args: should be "::tclwire::http::io header set name value"}
                }
                return [header_set {*}$args]
            }
            add {
                if {[llength $args] != 2} {
                    error {wrong # args: should be "::tclwire::http::io header add name value"}
                }
                return [header_add {*}$args]
            }
            remove {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::tclwire::http::io header remove name"}
                }
                return [header_remove {*}$args]
            }
            get {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::tclwire::http::io header get name"}
                }
                return [header_get {*}$args]
            }
            default {
                error "unknown HTTP header operation: $operation"
            }
        }
    }

    namespace export cookie header
    namespace ensemble create
}

package provide tclwire::http::application::io 0.1
