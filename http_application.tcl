# http_application.tcl --
#
# Application layer for the TclCurl HTTP test server.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclcurl::testserver {}

package require uri

if {[info commands ::tclcurl::testserver::CApplication] eq {}} {

    # Abstract application model for HTTP origin services. The service keeps
    # ownership of connection acceptance and low-level socket operations,
    # while application objects decide how a fully buffered request should be
    # interpreted and what response should be generated.
    # The current `service_request` entry point is synchronous, but it already
    # matches the future worker-thread handoff boundary.

    oo::class create ::tclcurl::testserver::CApplication {
        method header_lines {header_block} {
            return [regexp -all -inline {[^\r\n]+} $header_block]
        }

        # Parse the header block into a lower-cased dictionary so request
        # handlers can reason about headers without repeating parsing logic.
        method parse_headers {request} {
            set header_end [string first "\r\n\r\n" $request]
            if {$header_end < 0} {
                return [dict create]
            }

            set header_block [string range $request 0 [expr {$header_end - 1}]]
            set header_lines [my header_lines $header_block]
            set headers [dict create]

            foreach header_line [lrange $header_lines 1 end] {
                # Example match: "Content-Type: text/plain"
                if {![regexp {^([^:]+):\s*(.*)$} $header_line -> name value]} {
                    continue
                }
                dict set headers [string tolower $name] $value
            }

            return $headers
        }

        # Parse the request line and return the method, target and HTTP version
        # in a dictionary that both origin and proxy handlers can consume.
        method parse_request_line {request} {
            set request_line [lindex [split $request "\r\n"] 0]
            # Example matches:
            #   "GET /request-inspect HTTP/1.1"
            #   "GET http://127.0.0.1:8990/proxy-target HTTP/1.1"
            if {![regexp {^([A-Z]+) ([^ ]+) HTTP/([0-9.]+)$} $request_line -> method target version]} {
                return {}
            }

            return [dict create method $method target $target version $version]
        }

        method escape_response_value {value} {
            return [string map [list "\\" "\\\\" "\n" "\\n" "\r" "\\r"] $value]
        }

        method decode_query_component {value} {
            set decoded [string map [list + " "] $value]
            while {[regexp -indices {%[0-9A-Fa-f][0-9A-Fa-f]} $decoded match]} {
                lassign $match first last
                set replacement [format %c 0x[string range $decoded [expr {$first + 1}] $last]]
                set decoded     [string replace $decoded $first $last $replacement]
            }
            return $decoded
        }

        method parse_query {target} {
            set uri_parts [::uri::split "http://localhost$target"]
            if {![dict exists $uri_parts query]} {
                return [dict create]
            }

            set query [dict get $uri_parts query]
            if {$query eq {}} {
                return [dict create]
            }

            set params [dict create]
            foreach pair [split $query &] {
                if {$pair eq {}} {
                    continue
                }
                set separator [string first = $pair]
                if {$separator < 0} {
                    dict set params [my decode_query_component $pair] {}
                    continue
                }
                dict set params \
                    [my decode_query_component [string range $pair 0 [expr {$separator - 1}]]] \
                    [my decode_query_component [string range $pair   [expr {$separator + 1}] end]]
            }

            return $params
        }

        method guess_content_type {path} {
            switch -exact -- [string tolower [file extension $path]] {
                .css  { return "text/css; charset=utf-8" }
                .gif  { return "image/gif" }
                .htm -
                .html { return "text/html; charset=utf-8" }
                .jpg -
                .jpeg { return "image/jpeg" }
                .js   { return "application/javascript; charset=utf-8" }
                .json { return "application/json; charset=utf-8" }
                .md   { return "text/markdown; charset=utf-8" }
                .png  { return "image/png" }
                .svg  { return "image/svg+xml; charset=utf-8" }
                .tcl  { return "text/plain; charset=utf-8" }
                .txt  { return "text/plain; charset=utf-8" }
                .xml  { return "application/xml; charset=utf-8" }
                default {
                    return "application/octet-stream"
                }
            }
        }

        # Mock worker entry point. The service passes the channel and the full
        # request here today; later the same method can move the channel and
        # buffered bytes to a worker thread.
        method service_request {service chan request} {

            # parsing the main HTTP request line. In case of
            # well formed request returns a dictionary
            # with the keys 'method','target' and 'version'

            set request_info_d [my parse_request_line $request]
            if {[dict size $request_info_d] == 0} {
                $service log_request "method=? status=400 path=?"
                $service send_response $chan [$service bad_request_response]
                return
            }

            dict with request_info_d {
                set path [lindex [split $target ?] 0]
                ::tclcurl::test::msgoutput "route request method=$method path=$path"
                set headers [my parse_headers $request]
                set response [my route_request $service $method $path $target $version $headers $request]
                dict set response head_only [expr {$method eq "HEAD"}]
                set response [$service build_response_dict $response]
                $service log_request \
                    "method=$method status=[dict get $response status] path=[::tclcurl::testserver::log_value $path]"
                if {[dict exists $response delay_ms]} {
                    set callback [list $service send_response $chan $response]
                    if {[dict exists $response close_only] && [dict get $response close_only]} {
                        set callback [list $service close_client $chan]
                    }
                    after [dict get $response delay_ms] $callback
                    return
                }
                $service send_response $chan $response
            }
        }

        method request_body {service request} {
            set header_end [string first "\r\n\r\n" $request]
            if {$header_end < 0} {
                return {}
            }

            set headers [my parse_headers $request]
            if {[string tolower [$service header_value $headers transfer-encoding]] eq "chunked"} {
                return [$service decode_chunked_body [string range $request [expr {$header_end + 4}] end]]
            }

            return [string range $request [expr {$header_end + 4}] end]
        }

        method redirect_response {location {reason "Found"}} {
            set body "redirect=$location\n"
            return [dict create status 302      \
                                reason $reason  \
                                body $body      \
                                headers [list "Location: $location"]]
        }

        method static_file_response {path} {
            if {$path eq {}} {
                return {}
            }

            if {$path eq "/"} {
                set relative_segments [list index.html]
            } else {
                set relative_segments {}
                foreach segment [split [string trimleft $path /] /] {
                    if {$segment eq {} || $segment eq "." || $segment eq ".."} {
                        return {}
                    }
                    lappend relative_segments $segment
                }
            }

            set doc_root [::tclcurl::test::doc_root]
            set fs_path [file join $doc_root {*}$relative_segments]
            if {[file isdirectory $fs_path]} {
                set fs_path [file join $fs_path index.html]
            }
            if {![file exists $fs_path] || [file isdirectory $fs_path]} {
                return {}
            }

            set fh [open $fs_path rb]
            try {
                set body [read $fh]
            } finally {
                close $fh
            }

            return [dict create status  200     \
                                reason  OK      \
                                body    $body   \
                                headers [list "Content-Type: [my guess_content_type $fs_path]"]]
        }

        method byte_range_response {service headers full_body} {
            set total_length [string length $full_body]
            set range_header [$service header_value $headers range]
            if {$range_header eq {}} {
                return [dict create status  200         \
                                    reason  OK          \
                                    body    $full_body  \
                                    headers [list "Accept-Ranges: bytes"]]
            }

            if {![regexp {^bytes=\s*([0-9]+-[0-9]+)(\s*,\s*([0-9]+-[0-9]+))*$} $range_header]} {
                return [dict create status 416                      \
                                    reason "Range Not Satisfiable"  \
                                    body {}                         \
                                    headers [list "Content-Range: bytes */$total_length"]]
            }

            set ranges {}
            foreach range_spec [split [string range $range_header 6 end] ,] {
                set range_spec [string trim $range_spec]
                lassign [split $range_spec -] start end
                if {$start > $end || $end >= $total_length} {
                    return [dict create status 416 \
                                        reason "Range Not Satisfiable" \
                                        body {} \
                                        headers [list "Content-Range: bytes */$total_length"]]
                }
                lappend ranges [list $start $end]
            }

            if {[llength $ranges] == 1} {
                lassign [lindex $ranges 0] start end
                set range_body [string range $full_body $start $end]
                return [dict create status 206 \
                                    reason "Partial Content" \
                                    body $range_body \
                                    headers [list "Accept-Ranges: bytes" \
                                                  "Content-Range: bytes $start-$end/$total_length"]]
            }

            set boundary "tclcurl-boundary"
            set range_body {}
            foreach range $ranges {
                lassign $range start end
                append range_body "--$boundary\r\n"
                append range_body "Content-Type: text/plain\r\n"
                append range_body "Content-Range: bytes $start-$end/$total_length\r\n\r\n"
                append range_body [string range $full_body $start $end]
                append range_body "\r\n"
            }
            append range_body "--$boundary--\r\n"
            return [dict create status  206 \
                                reason  "Partial Content" \
                                body    $range_body \
                                headers [list "Accept-Ranges: bytes" \
                                              "Content-Type: multipart/byteranges; boundary=$boundary"]]
        }

        method route_request {service method path target version headers request} {
            error "route_request must be implemented by subclasses"
        }
    }
}
