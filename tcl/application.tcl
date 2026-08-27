# application.tcl --
#
# Abstract TclWire application lifecycle and concrete static-file application.
#
# ::tclwire::Application owns generic configuration and request/response
# lifecycle hooks. Direct subclasses implement handle_request for non-file
# representation models. ::tclwire::CApplication retains the default static
# resource workflow and exposes these narrower extension points:
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

oo::class create ::tclwire::Application {
    variable configuration_object
    variable content_encoding
    variable cache_control_map

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
        set descriptor_defaults [dict create class             [info object class [self]] \
                                             hosts             {} \
                                             application_paths [list [dict get $application_descriptor docroot]] \
                                             aliases           {} \
                                             package           tclwire::application]

        set complete_descriptor  [dict merge $descriptor_defaults $application_descriptor]
        set configuration_object [::tclwire::ApplicationConfiguration new $application_id $complete_descriptor]
        set content_encoding     [dict get $application_descriptor encoding]
        set cache_control_map    [my configured_cache_control_map]
    }

    method configuration_object {} {
        return $configuration_object
    }

    destructor {
        if {[info exists configuration_object] && $configuration_object ne {}} {
            $configuration_object destroy
        }
    }

    method encoding {} {
        return $content_encoding
    }

    method rewrite_request {request} {
        return
    }

    # The default preparation stage preserves the established handler-only
    # application contract. Subclasses may return {action reply response ...}
    # to answer before generation, or attach a future response policy to pass.

    method prepare_request {request} {
        return [dict create action pass]
    }

    # configured_cache_control_map --
    #
    # Mapping the configuration defined map of file extensions and HTTP 
    # controlled browser cache lifetime values
    #
    # Keys are extensions without a leading dot and values are nonnegative cache
    # lifetimes in seconds. The application-owned cache_control_map
    # configuration changes and extends these defaults; an "unset" value removes a
    # default. Keeping the policy in Application makes it available to both
    # content generating applications and ordinary static file representations.

    method cache_control_defaults {} {
        return [dict create]
    }

    method configured_cache_control_map {} {
        set defaults [my cache_control_defaults]
        if {[catch {dict size $defaults}]} {
            error "Application cache_control_defaults must return a dictionary"
        }

        set cache_control_map {}
        dict for {extension lifetime} $defaults {
            set extension [string trimleft [string tolower $extension] .]
            if {$extension eq {}} {
                error "cache_control_defaults extension must not be empty"
            }
            if {![string is integer -strict $lifetime] || $lifetime < 0} {
                error "default cache lifetime for $extension must be a nonnegative integer"
            }
            dict set cache_control_map $extension $lifetime
        }

        if {[[my configuration_object] exists cache_control_map]} {
            set configured_map [[my configuration_object] get cache_control_map]
            if {[catch {dict size $configured_map}]} {
                error "application cache_control_map must be a dictionary"
            }
            dict for {extension lifetime} $configured_map {
                set extension [string trimleft [string tolower $extension] .]
                if {$extension eq {}} {
                    error "cache_control_map extension must not be empty"
                }
                if {$lifetime eq "unset"} {
                    if {[dict exists $cache_control_map $extension]} {
                        dict unset cache_control_map $extension
                    }
                    continue
                }
                if {![string is integer -strict $lifetime] || $lifetime < 0} {
                    error "cache lifetime for $extension must be a nonnegative integer"
                }
                dict set cache_control_map $extension $lifetime
            }
        }
        return $cache_control_map
    }

    # The output bridge invokes this once immediately before the response head
    # becomes immutable. It is deliberately a descriptor transformation, not
    # an output method: a hook may adjust metadata but cannot send body bytes.
    #
    # When cache_control_map names the request's extension, successful
    # responses receive its public max-age value. A handler-supplied
    # Cache-Control field is deliberately replaced, giving the configured
    # application policy one authoritative value while preserving every other
    # header and its relative order.

    method prepare_response {request response} {
        if {[dict get $response status] < 200 ||
            [dict get $response status] >= 300} {
            return $response
        }
        set extension [string trimleft [string tolower [file extension [$request path]]] .]
        if {$extension eq {} || ![dict exists $cache_control_map $extension]} {
            return $response
        }
        set headers {}
        foreach header [dict get $response headers] {
            if {![string equal -nocase [lindex $header 0] Cache-Control]} {
                lappend headers $header
            }
        }
        lappend headers \
            [list Cache-Control "public, max-age=[dict get $cache_control_map $extension]"]
        dict set response headers $headers
        return $response
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

    method handle_request {request} {
        error "Application subclasses must implement handle_request"
    }
}

oo::class create ::tclwire::CApplication {
    superclass ::tclwire::Application

    variable document_root
    variable directory_index
    variable aliases
    variable rewrite_hook

    constructor {application_descriptor} {
        next $application_descriptor
        set document_root [file normalize [dict get $application_descriptor docroot]]
        set directory_index [my configured_directory_index]
        set aliases [[my configuration_object] aliases]
        set rewrite_hook [my configured_rewrite_hook]
    }

    method document_root {} {
        return $document_root
    }

    method directory_index {} {
        return $directory_index
    }

    method configured_directory_index {} {
        set options [dict create directory_index [list index.html]]
        foreach class_name [list ::tclwire::CApplication [info object class [self]]] {
            set class_options [[my configuration_object] class_configuration $class_name]
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
        set hook [string trim [[my configuration_object] get rewrite_hook]]
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

    # Resolve successful static HEAD requests before normal generation.  This
    # avoids reading the representation while still allowing the common
    # prepare_response stage to inspect/finalize its metadata at commitment.
    # Errors deliberately pass through to handle_request so its established
    # error response and logging behavior remain authoritative.

    method prepare_request {request} {

        if {[$request method] ne "HEAD"} {
            return [next $request]
        }

        # everything that follows is meant to address a HEAD request

        if {[catch {set resolution [my resolve_request_path $request]}] ||
             $resolution eq {}} {
            return [next $request]
        }

        set local_path [$request local_path]
        my log_file_resolution $request 200 $local_path debug
        set resource [my file_resource $local_path]
        set header_pairs {}
        foreach header [concat [my resource_headers $resource] \
                [list "Content-Length: [dict get $resource length]"]] {
            regexp {^([^:]+):\s*(.*)$} $header -> name value
            lappend header_pairs [list $name $value]
        }
        return [dict create action reply response [dict create \
            status 200 reason OK headers $header_pairs body_mode binary]]
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

    # resolving %xx encoded characters in file paths

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
