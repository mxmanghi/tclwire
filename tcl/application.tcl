# application.tcl --
#
# Default TclWire content application.

package require TclOO
package require tclwire::application::io 0.1
package require tclwire::http::errors 0.1
package require fileutil

namespace eval ::tclwire {}

oo::class create ::tclwire::CApplication {
    variable configuration document_root content_encoding

    constructor {application_descriptor} {
        if {[catch {dict size $application_descriptor}]} {
            error "application descriptor must be a dictionary"
        }
        if {![dict exists $application_descriptor docroot]} {
            error "application descriptor is missing docroot"
        }
        if {![dict exists $application_descriptor encoding]} {
            error "application descriptor is missing encoding"
        }
        set configuration $application_descriptor
        set document_root [file normalize [dict get $application_descriptor docroot]]
        set content_encoding [dict get $application_descriptor encoding]
    }

    method configuration {} {
        return $configuration
    }

    method document_root {} {
        return $document_root
    }

    method encoding {} {
        return $content_encoding
    }

    method decode_path {path} {
        if {[string first "\x00" $path] >= 0} {
            error "URL path contains a null byte"
        }

        set bytes [binary format a* {}]
        for {set i 0} {$i < [string length $path]} {incr i} {
            set character [string index $path $i]
            if {$character eq "%"} {
                if {$i + 2 >= [string length $path]} {
                    error "incomplete percent escape in URL path"
                }
                set hex [string range $path [expr {$i + 1}] [expr {$i + 2}]]
                if {![regexp {^[0-9A-Fa-f]{2}$} $hex]} {
                    error "invalid percent escape in URL path"
                }
                append bytes [binary format H2 $hex]
                incr i 2
            } else {
                append bytes [encoding convertto utf-8 $character]
            }
        }
        return [encoding convertfrom utf-8 $bytes]
    }

    method local_path {url_path} {
        set path [my decode_path $url_path]
        if {![string match "/*" $path] || [string first "\\" $path] >= 0} {
            return {}
        }

        set segments {}
        foreach segment [split [string trimleft $path /] /] {
            if {$segment eq {} || $segment eq "."} {
                continue
            }
            if {$segment eq ".."} {
                return {}
            }
            lappend segments $segment
        }
        if {[llength $segments] == 0} {
            set segments [list index.html]
        }

        set candidate [file normalize \
            [file join [my document_root] {*}$segments]]
        set root [my document_root]
        if {$candidate ne $root &&
                ![string match "${root}[file separator]*" $candidate]} {
            return {}
        }
        if {[file isdirectory $candidate]} {
            set candidate [file join $candidate index.html]
        }
        if {![file isfile $candidate] || ![file readable $candidate]} {
            return {}
        }
        return $candidate
    }

    method content_type {path} {
        set charset "; charset=[my encoding]"
        switch -exact -- [string tolower [file extension $path]] {
            .css  { return "text/css$charset" }
            .gif  { return "image/gif" }
            .htm -
            .html { return "text/html$charset" }
            .ico  { return "image/x-icon" }
            .jpg -
            .jpeg { return "image/jpeg" }
            .js   { return "text/javascript$charset" }
            .json { return "application/json$charset" }
            .md   { return "text/markdown$charset" }
            .pdf  { return "application/pdf" }
            .png  { return "image/png" }
            .svg  { return "image/svg+xml$charset" }
            .tcl  -
            .txt  { return "text/plain$charset" }
            .webp { return "image/webp" }
            .xml  { return "application/xml$charset" }
            default { return "application/octet-stream" }
        }
    }

    method send_error {status path} {
        set response [::tclwire::http::errors response \
            $status [dict create path $path]]

        dict with response {
            ::tclwire::io response $status $reason $headers text [my encoding] 
            ::tclwire::io out $body
        }
        return
    }

    method handle_request {request_descriptor} {
        set path [dict get $request_descriptor path]
        if {[catch {set local_path [my local_path $path]}]} {
            my send_error 400 $path
            return
        }
        if {$local_path eq {}} {
            my send_error 404 $path
            return
        }

        ::tclwire::io response 200 OK \
            [list "Content-Type: [my content_type $local_path]"] binary
        ::tclwire::io out \
            [::fileutil::cat -translation binary $local_path] binary
        return
    }

    unexport decode_path send_error
}

package provide tclwire::application 0.1
