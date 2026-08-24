# application.tcl --
#
# Default TclWire content application and base HTTP application model.
#
# Derived applications normally override `handle_request` for routing and
# dynamic content generation. Applications retaining the default static
# resource workflow can override these narrower extension points:
#
#   local_path             map a URL path to an application resource
#   file_resource          describe the resolved resource
#   serve_complete_file    serve the complete representation
#   serve_file_metadata    serve representation metadata for HEAD
#   serve_content_ranges   serve a multipart set of normalized content ranges
#
# The default implementations use filesystem-backed resources. Overrides may
# use databases, generated representations, object stores, or other content
# providers while retaining the HTTP request and response machinery.

package require TclOO
package require tclwire::constants 0.1
package require tclwire::application_configuration 0.1
package require tclwire::application::io 0.1
package require tclwire::http::application::io 0.1
package require tclwire::http::errors 0.1
package require tclwire::http::range 0.1
package require tclwire::http::redirect 0.1
package require tclwire::http::request 0.1
package require tclwire::logger::client 0.1
package require fileutil

namespace eval ::tclwire {}

oo::class create ::tclwire::CApplication {
    variable configuration_object
    variable document_root
    variable content_encoding
    variable directory_index
    variable aliases
    variable rewrite_hook

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
        set application_id application
        if {[dict exists $application_descriptor application_id]} {
            set application_id [dict get $application_descriptor application_id]
        }
        set complete_descriptor $application_descriptor
        foreach {property value} [list class       [info object class [self]] \
                                       hosts       {} \
                                       application_paths [list [dict get $application_descriptor docroot]] \
                                       aliases     {} \
                                       package     tclwire::application] {
            if {![dict exists $complete_descriptor $property]} {
                dict set complete_descriptor $property $value
            }
        }
        set configuration_object \
            [::tclwire::ApplicationConfiguration new $application_id $complete_descriptor]
        set document_root    [file normalize [dict get $application_descriptor docroot]]
        set content_encoding [dict get $application_descriptor encoding]
        set directory_index  [my configured_directory_index]
        set aliases          [dict get $complete_descriptor aliases]
        set rewrite_hook     [my configured_rewrite_hook]
    }

    method configuration_object {} {
        return $configuration_object
    }

    destructor {
        if {[info exists configuration_object] && \
            $configuration_object ne {}} {
            $configuration_object destroy
        }
    }

    method document_root {} {
        return $document_root
    }

    method encoding {} {
        return $content_encoding
    }

    method directory_index {} {
        return $directory_index
    }

    method configured_directory_index {} {
        set options [dict create directory_index [list index.html]]
        foreach class_name [list ::tclwire::CApplication [info object class [self]]] {
            set class_options [$configuration_object class_configuration $class_name]
            if {$class_options ne {}} {
                set options [dict merge $options $class_options]
            }
        }

        set names [dict get $options directory_index]
        if {[catch {llength $names}]} {
            error "CApplication directory_index must be a list"
        }
        if {[llength $names] == 0} {
            error "CApplication directory_index must not be empty"
        }
        foreach name $names {
            if {$name eq {} || $name in {. ..} ||
                    [file tail $name] ne $name ||
                    [string first "\\" $name] >= 0} {
                error "CApplication directory_index entries must be file names"
            }
        }
        return $names
    }

    method configured_rewrite_hook {} {
        set hook [string trim [$configuration_object get rewrite_hook]]
        if {$hook eq {}} {
            return {}
        }
        if {[file pathtype $hook] ne "relative"} {
            error "application rewrite_hook must name a file relative to the document root"
        }

        set hook_file [file normalize [file join $document_root $hook]]
        if {($hook_file ne $document_root) &&
                ![string match "${document_root}[file separator]*" $hook_file]} {
            error "application rewrite_hook must be within the document root"
        }
        if {![file isfile $hook_file] || ![file readable $hook_file]} {
            error "application rewrite_hook file is not readable: $hook"
        }

        set hook_namespace [info object namespace [self]]::rewrite_hook
        namespace eval $hook_namespace [list source $hook_file]
        set command ${hook_namespace}::url_rewrite
        if {[info commands $command] eq {}} {
            error "application rewrite_hook file does not define url_rewrite: $hook"
        }
        return $command
    }

    method rewrite_request {request} {
        if {$rewrite_hook ne {}} {
            $rewrite_hook $request
        }
        return
    }

    method directory_index_candidate {directory {existing_only 0}} {
        foreach name [my directory_index] {
            set candidate [file normalize [file join $directory $name]]
            if {!$existing_only ||
                    ([file isfile $candidate] && [file readable $candidate])} {
                return $candidate
            }
        }
        return {}
    }

    method directory_index_resolution {url_path directory} {
        foreach name [my directory_index] {
            set local_path [file normalize [file join $directory $name]]
            if {![file isfile $local_path] || ![file readable $local_path]} {
                continue
            }
            set selected_url_path $url_path
            if {![string match */ $selected_url_path]} {
                append selected_url_path /
            }
            append selected_url_path $name
            return [dict create path $selected_url_path local_path $local_path]
        }
        return {}
    }

    method initialize {} {
        return
    }

    method shutdown {} {
        return
    }

    method signal {args} {
        return
    }

    method decode_path {path} {
        set bytes $::tclwire::constants::empty_bytearray
        for {set i 0} {$i < [string length $path]} {incr i} {
            set character [string index $path $i]
            if {$character eq "\x00"} {
                error "URL path contains a null byte"
            }
            if {$character eq "%"} {
                if {$i + 2 >= [string length $path]} {
                    error "incomplete percent escape in URL path"
                }
                set hex [string range $path $i+1 $i+2]
                if {![regexp {^[0-9A-Fa-f]{2}$} $hex]} {
                    error "invalid percent escape in URL path"
                }
                if {$hex eq "00"} {
                    error "URL path contains a null byte"
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
        set resolution [my resolve_path $url_path]
        if {$resolution eq {}} {
            return {}
        }
        return [dict get $resolution local_path]
    }

    method resolve_path {url_path} {
        set path [my decode_path $url_path]
        set candidate [my alias_file_candidate $path]
        if {$candidate eq {}} {
            set candidate [my path_file_candidate $path]
        }
        if {$candidate eq {}} {
            return {}
        }
        if {[file isdirectory $candidate]} {
            return [my directory_index_resolution $url_path $candidate]
        }
        if {![file isfile $candidate] || ![file readable $candidate]} {
            return {}
        }
        return [dict create path $url_path local_path $candidate]
    }

    method resolve_request_path {request} {
        set resolution [my resolve_path [$request url_path]]
        if {$resolution eq {}} {
            return {}
        }
        $request path [dict get $resolution path]
        $request local_path [dict get $resolution local_path]
        return $resolution
    }

    method url_file_candidate {url_path} {
        set path [my decode_path $url_path]
        return [my path_file_candidate $path]
    }

    method path_file_candidate {path} {
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
            return [my document_root]
        }

        set candidate [file normalize [file join [my document_root] {*}$segments]]
        set root [my document_root]
        if {($candidate ne $root) && \
             ![string match "${root}[file separator]*" $candidate]} {
            return {}
        }
        return [file normalize $candidate]
    }

    method alias_matches {prefix path} {
        if {[string match */ $prefix]} {
            return [string match "${prefix}*" $path]
        }
        return [expr {$path eq $prefix || [string match "${prefix}/*" $path]}]
    }

    method alias_file_candidate {path} {
        foreach alias $aliases {
            set prefix [dict get $alias url_path]
            if {![my alias_matches $prefix $path]} { continue }
            set suffix [string range $path [string length $prefix] end]
            set suffix [string trimleft $suffix /]
            set target [dict get $alias local_path]
            if {[file pathtype $target] eq "absolute"} {
                set candidate [file normalize [file join $target $suffix]]
            } else {
                set candidate [file normalize \
                    [file join [my document_root] $target $suffix]]
            }
            return $candidate
        }
        return {}
    }

    method log_file_resolution {request status resolved_path {level debug}} {
        set context [dict create]
        if {[$request header host] ne {}} {
            dict set context host [$request header host]
        }

        set fields [list "method=[::tclwire::logger::log_value [$request method]]" \
                         "path=[::tclwire::logger::log_value [$request path]]" \
                         "original_path=[::tclwire::logger::log_value [$request url_path]]" \
                         "status=$status" \
                         "resolved_path=[::tclwire::logger::log_value $resolved_path]"]

        catch {
            set logger [::tclwire::logger::getlogger]
            $logger log_error static_file [join $fields " "] $level $context
        }
        return
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
        set response [::tclwire::http::errors response $status [dict create path $path]]

        dict with response {
            ::tclwire::io response $status $reason $headers $body_mode $encoding
            ::tclwire::io out $body $body_mode
        }
        return
    }

    method file_resource {local_path} {
        return [dict create path         $local_path \
                            length       [file size $local_path] \
                            content_type [my content_type $local_path]]
    }

    method resource_headers {resource} {
        return [list "Accept-Ranges: bytes" \
                     "Content-Type: [dict get $resource content_type]"]
    }

    method read_file {path} {
        return [::fileutil::cat -translation binary $path]
    }

    method read_file_range {path start end} {
        set channel [open $path rb]
        try {
            seek $channel $start start
            return [read $channel [expr {$end - $start + 1}]]
        } finally {
            close $channel
        }
    }

    method serve_file_metadata {resource} {
        set headers [my resource_headers $resource]
        lappend headers "Content-Length: [dict get $resource length]"
        ::tclwire::io response 200 OK $headers binary
        return
    }

    method serve_complete_file {resource} {
        ::tclwire::io response 200 OK [my resource_headers $resource] binary
        ::tclwire::io out [my read_file [dict get $resource path]] binary
        return
    }

    method serve_unsatisfiable_range {resource} {
        set length [dict get $resource length]
        ::tclwire::io response 416 "Range Not Satisfiable" \
                  [list "Accept-Ranges: bytes" "Content-Range: bytes */$length"] binary
        return
    }

    method serve_single_range {resource range} {
        lassign $range start end
        set length [dict get $resource length]
        ::tclwire::io response 206 "Partial Content" \
                        [list "Accept-Ranges: bytes" \
                              "Content-Type: [dict get $resource content_type]" \
                              "Content-Range: bytes $start-$end/$length"] binary
        ::tclwire::io out [my read_file_range [dict get $resource path] $start $end] binary
        return
    }

    method serve_content_ranges {resource ranges} {
        set boundary [::tclwire::http::range boundary]
        set content_type [dict get $resource content_type]
        set length [dict get $resource length]
        set body $::tclwire::constants::empty_bytearray
        foreach range $ranges {
            lassign $range start end
            set data [my read_file_range [dict get $resource path] $start $end]
            append body [::tclwire::http::range multipart_part \
                $data $start $end $content_type $length $boundary]
        }
        append body [::tclwire::http::range multipart_end $boundary]
        ::tclwire::io response 206 "Partial Content" \
            [list "Accept-Ranges: bytes" \
                  "Content-Type: multipart/byteranges; boundary=$boundary"] binary
        ::tclwire::io out $body binary
        return
    }

    method serve_file_ranges {resource range_value} {
        set result [::tclwire::http::range classify $range_value [dict get $resource length]]
        switch -exact -- [dict get $result status] {
            unsupported -
            malformed {
                my serve_complete_file $resource
            }
            unsatisfiable {
                my serve_unsatisfiable_range $resource
            }
            satisfiable {
                set ranges [dict get $result ranges]
                if {[llength $ranges] == 1} {
                    my serve_single_range $resource [lindex $ranges 0]
                } else {
                    my serve_content_ranges $resource $ranges
                }
            }
            default {
                error "unknown byte-range classification"
            }
        }
        return
    }

    method handle_request {request} {
        set path [$request url_path]
        if {[catch {set resolution [my resolve_request_path $request]}]} {
            my log_file_resolution $request 400 {} error
            my send_error 400 $path
            return
        }
        if {$resolution eq {}} {
            set resolved_path {}
            catch {set resolved_path [my url_file_candidate $path]}
            my log_file_resolution $request 404 $resolved_path error
            my send_error 404 $path
            return
        }
        set local_path [$request local_path]

        my log_file_resolution $request 200 $local_path debug

        set resource [my file_resource $local_path]
        set method [$request method]
        if {$method eq "HEAD"} {
            my serve_file_metadata $resource
            return
        }

        set range_value [$request header range]
        if {$range_value eq {} || $method ne "GET"} {
            my serve_complete_file $resource
            return
        }

        my serve_file_ranges $resource $range_value
        return
    }

    unexport    alias_file_candidate alias_matches \
                configured_directory_index decode_path \
                directory_index_candidate \
                directory_index_resolution resolve_path \
                file_resource log_file_resolution read_file \
                read_file_range resource_headers send_error \
                path_file_candidate serve_complete_file \
                serve_content_ranges serve_file_metadata \
                serve_file_ranges serve_single_range \
                serve_unsatisfiable_range url_file_candidate
}

package provide tclwire::application 0.1
