# http_error_messages.tcl --
#
# Repository-level HTTP error message catalog.

package require json

namespace eval ::tclwire {}

namespace eval ::tclwire::http::errors {
    variable catalog {}
    variable catalog_path [file normalize [file join \
        [file dirname [file dirname [info script]]] http_error_messages.json]]

    proc default_catalog {} {
        return [dict create \
            000 [dict create \
                reason "Internal Server Error" \
                body "TclWire could not complete the request.\n"] \
            400 [dict create \
                reason "Bad Request" \
                body "The request could not be understood by TclWire.\n"] \
            403 [dict create \
                reason "Forbidden" \
                body "The requested resource is not available for this service.\n"] \
            404 [dict create \
                reason "Not Found" \
                body "TclWire could not find {{path}}.\n"] \
            405 [dict create \
                reason "Method Not Allowed" \
                body "The requested method is not supported for this resource.\n"] \
            500 [dict create \
                reason "Internal Server Error" \
                body "TclWire could not complete the request because of an internal error.\n"] \
            503 [dict create \
                reason "Service Unavailable" \
                body "The service is temporarily unavailable. Try again later.\n"]]
    }

    proc validate {messages} {
        if {[catch {dict size $messages}]} {
            error "HTTP error message catalog must be a dictionary"
        }
        if {![dict exists $messages 000]} {
            error "HTTP error message catalog must define fallback status 000"
        }
        dict for {status message} $messages {
            if {![regexp {^[0-9]{3}$} $status]} {
                error "invalid HTTP error status key: $status"
            }
            foreach field {reason body} {
                if {![dict exists $message $field]} {
                    error "HTTP error status $status is missing $field"
                }
            }
        }
        return $messages
    }

    proc load {{path {}}} {
        variable catalog
        variable catalog_path

        if {$path eq {}} {
            set path $catalog_path
        }
        if {[catch {
            set channel [open $path r]
            try {
                set content [read $channel]
            } finally {
                close $channel
            }
            set messages [validate [::json::json2dict $content]]
        }]} {
            set messages [default_catalog]
        }
        set catalog $messages
        return $catalog
    }

    proc messages {} {
        variable catalog
        if {$catalog eq {}} {
            load
        }
        return $catalog
    }

    proc message {status} {
        set messages [messages]
        if {[dict exists $messages $status]} {
            return [dict get $messages $status]
        }
        return [dict get $messages 000]
    }

    proc html_escape {value} {
        return [string map [list \
            &  "&amp;" \
            <  "&lt;" \
            >  "&gt;" \
            \" "&quot;" \
            '  "&#39;"] $value]
    }

    proc expand {body context} {
        set replacements {}
        dict for {name value} $context {
            lappend replacements "{{$name}}" [html_escape $value]
        }
        return [string map $replacements $body]
    }

    proc response {status {context {}}} {
        if {[catch {dict size $context}]} {
            error "HTTP error context must be a dictionary"
        }
        set entry [message $status]
        if {![dict exists $context status]} {
            dict set context status $status
        }
        return [dict create \
            status $status \
            reason [dict get $entry reason] \
            body [expand [dict get $entry body] $context] \
            headers [list "Content-Type: text/html; charset=utf-8"]]
    }

    namespace export load messages message response
    namespace ensemble create
}

package provide tclwire::http::errors 0.1
