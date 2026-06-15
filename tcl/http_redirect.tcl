# http_redirect.tcl --
#
# Reusable HTTP redirect-response construction.

package require tclwire::application::io 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::http {}

namespace eval ::tclwire::http::redirect {
    variable reasons [dict create \
        301 "Moved Permanently" \
        302 "Found" \
        303 "See Other" \
        307 "Temporary Redirect" \
        308 "Permanent Redirect"]

    proc validate_location {location} {
        if {$location eq {}} {
            error "HTTP redirect location must not be empty"
        }
        if {[string first "\r" $location] >= 0 ||
                [string first "\n" $location] >= 0} {
            error "invalid HTTP redirect location"
        }
        return $location
    }

    proc reason {status} {
        variable reasons

        if {![dict exists $reasons $status]} {
            error "unsupported HTTP redirect status: $status"
        }
        return [dict get $reasons $status]
    }

    proc validate_headers {headers} {
        foreach header $headers {
            if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+:[ \t]*[^\r\n]*$} \
                    $header]} {
                error "invalid HTTP redirect response header"
            }
            if {[regexp -nocase {^Location:} $header]} {
                error "HTTP redirect response headers must not contain Location"
            }
        }
        return $headers
    }

    proc response {location args} {
        set location [validate_location $location]
        set status 302
        set body {}
        set headers {}

        if {[llength $args] % 2 != 0} {
            error {wrong # args: should be "::tclwire::http::redirect response location ?-status status? ?-body body? ?-headers headers?"}
        }
        foreach {option option_value} $args {
            switch -exact -- $option {
                -status {
                    set status $option_value
                }
                -body {
                    set body $option_value
                }
                -headers {
                    set headers [validate_headers $option_value]
                }
                default {
                    error "unknown HTTP redirect option: $option"
                }
            }
        }

        set reason [reason $status]
        set response_headers [linsert $headers 0 "Location: $location"]
        return [dict create \
            status $status \
            reason $reason \
            body $body \
            headers $response_headers \
            body_mode text]
    }

    proc send {location args} {
        set redirect_response [response $location {*}$args]
        ::tclwire::io response \
            [dict get $redirect_response status] \
            [dict get $redirect_response reason] \
            [dict get $redirect_response headers] \
            [dict get $redirect_response body_mode]
        if {[dict get $redirect_response body] ne {}} {
            ::tclwire::io out \
                [dict get $redirect_response body] \
                [dict get $redirect_response body_mode]
        }
        return $redirect_response
    }

    namespace export response send
    namespace ensemble create
}

package provide tclwire::http::redirect 0.1
