# tclcurl_test_server.tcl --
#
# TclCurl test-suite HTTP application routes.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclwire {}

set ::tclwire::test_application_root \
    [file dirname [file dirname [file normalize [info script]]]]
if {$::tclwire::test_application_root ni $::auto_path} {
    lappend ::auto_path $::tclwire::test_application_root
}

package require sha256
package require base64

if {[info commands ::tclwire::require_zlib] eq {}} {
    proc ::tclwire::require_zlib {} {
        if {![catch {package require zlib} version options]} {
            return $version
        }
        if {[info commands ::zlib] ne {}} {
            return
        }
        return -options $options $version
    }
}
::tclwire::require_zlib

if {[catch {package require tclwire::application 0.1}]} {
    source [file join $::tclwire::test_application_root tcl application.tcl]
}
if {[catch {package require tclwire::support 0.1}]} {
    source [file join $::tclwire::test_application_root tcl support.tcl]
}

if {[info commands ::tclwire::repo_root] eq {}} {
    proc ::tclwire::repo_root {} {
        return [::tclwire::support project_root]
    }
}

if {[info commands ::tclwire::manual_html_source] eq {}} {
    proc ::tclwire::manual_html_source {} {
        set repo_root [::tclwire::repo_root]
        foreach candidate [list \
                [file join $repo_root doc tclcurl.n.html] \
                [file join $repo_root doc tclcurl.html]] {
            if {[file exists $candidate]} {
                return $candidate
            }
        }
        return {}
    }
}

if {[info commands ::tclwire::range_fixture] eq {}} {
    proc ::tclwire::range_fixture {{ntimes 8192}} {
        return [string repeat "0123456789abcdef" $ntimes]
    }
}

if {[info commands ::tclwire::negotiation_payload] eq {}} {
    proc ::tclwire::negotiation_payload {} {
        return [string range [::tclwire::range_fixture] 0 255]
    }
}

if {[info commands ::tclwire::CTestApplication] eq {}} {
    oo::class create ::tclwire::CTestApplication {
        superclass ::tclwire::CApplication

        constructor {application_descriptor} {
            next $application_descriptor
            my seed_docroot_fixtures
        }

        method handle_request {request} {
            set response [my route_request $request]
            my emit_response $request $response
            return
        }

        method route_request {request} {
            set method  [$request method]
            set path    [$request path]
            set target  [$request target]
            set version [$request version]

            if {[regexp {^/redir_([0-9]+)$} $path -> redirect_step]} {
                if {$redirect_step < 5} {
                    return [my redirect_response "/redir_[incr redirect_step]"]
                }

                return [dict create \
                    status 200 reason OK headers {} \
                    body "path=$path\nmethod=$method\n"]
            }

            if {[regexp {^/wait-([0-9]+)(ms|s)$} $path -> wait_amount wait_unit]} {
                set wait_time $wait_amount
                if {$wait_unit eq "s"} {
                    set wait_time [expr {$wait_time * 1000}]
                }

                return [dict create \
                    status 200 \
                    reason OK \
                    delay_ms $wait_time \
                    close_only [expr {[$request query_parameter reply] eq "none"}] \
                    body "waited=${wait_amount}${wait_unit}\n" \
                    headers {}]
            }

            if {[regexp {^/cookie-set/([^/]+)/([^/]+)$} $path -> cookie_name cookie_value]} {
                return [dict create \
                    status 200 reason OK \
                    body "set-cookie=$cookie_name=$cookie_value\n" \
                    headers [list "Set-Cookie: $cookie_name=$cookie_value; Path=/"]]
            }

            switch -- $path {
                / {
                    set static_response [my static_response /]
                    if {$static_response ne {}} {
                        return $static_response
                    }
                    set index_path [file join [::tclwire::repo_root] index.html]
                    if {[file exists $index_path]} {
                        return [dict create \
                            status 200 reason OK \
                            body [my read_binary_file $index_path] \
                            headers [list "Content-Type: text/html; charset=utf-8"] \
                            body_mode binary]
                    }
                    return [dict create \
                        status 200 reason OK headers {} body "tclcurl test server\n"]
                }
                /tclcurl-man {
                    set static_response [my static_response /tclcurl-man.html]
                    if {$static_response ne {}} {
                        return $static_response
                    }
                    set manual_path [::tclwire::manual_html_source]
                    if {$manual_path ne {} && [file exists $manual_path]} {
                        return [dict create \
                            status 200 reason OK \
                            body [my read_binary_file $manual_path] \
                            headers [list "Content-Type: text/html; charset=utf-8"] \
                            body_mode binary]
                    }
                    return [dict create \
                        status 404 reason "Not Found" headers {} body "path=$path\n"]
                }
                /tclcurl-http-root {
                    return [dict create \
                        status 200 reason OK \
                        headers [list "Content-Type: text/plain; charset=utf-8"] \
                        body "tclcurl test server\n"]
                }
                /tclcurl-http200alias {
                    return [dict create \
                        status 200 reason OK headers {} \
                        body "http200aliases=matched\n"]
                }
                /tclcurl-missing-resource {
                    return [dict create \
                        status 404 reason "Not Found" headers {} body "not found\n"]
                }
                /autoreferer-start {
                    return [my redirect_response "/autoreferer-target"]
                }
                /autoreferer-target {
                    set body "method=$method\nreferer=[$request header referer]\n"
                    return [dict create status 200 reason OK headers {} body $body]
                }
                /postredir-301 {
                    if {$method eq "POST"} {
                        return [dict create \
                            status 301 \
                            reason "Moved Permanently" \
                            body "redirect=/postredir-target\n" \
                            headers [list "Location: /postredir-target"]]
                    }
                    return [dict create \
                        status 200 reason OK headers {} body "method=$method\n"]
                }
                /postredir-target {
                    return [dict create \
                        status 200 reason OK headers {} body "method=$method\n"]
                }
                /cookie-echo {
                    return [dict create \
                        status 200 reason OK headers {} body "cookie=[$request header cookie]\n"]
                }
                /proxy-target {
                    return [dict create status 200 reason OK headers {} body "proxy=ok\n"]
                }
                /proxy-auth-target {
                    return [dict create status 200 reason OK headers {} body "proxy-auth=ok\n"]
                }
                /auth-basic {
                    return [my basic_auth_response $request]
                }
                /request-inspect {
                    set request_body [my request_body $request]
                    set lines [list \
                        "method=[my escape_response_value $method]" \
                        "path=[my escape_response_value $path]" \
                        "target=[my escape_response_value $target]" \
                        "request-version=[my escape_response_value $version]" \
                        "content-type=[my escape_response_value [$request header content-type]]" \
                        "content-length=[my escape_response_value [$request header content-length]]" \
                        "accept-encoding=[my escape_response_value [$request header accept-encoding]]" \
                        "te=[my escape_response_value [$request header te]]" \
                        "connection=[my escape_response_value [$request header connection]]" \
                        "user-agent=[my escape_response_value [$request header user-agent]]" \
                        "referer=[my escape_response_value [$request header referer]]" \
                        "x-tclcurl-test=[my escape_response_value [$request header x-tclcurl-test]]" \
                        "body-length=[string length $request_body]" \
                        "body-hex=[binary encode hex $request_body]" \
                        "body-sha256=[::sha2::sha256 -hex $request_body]"]
                    set lines [concat $lines [my multipart_inspection_lines $request]]
                    set body [join $lines "\n"]
                    append body "\n"
                    return [dict create status 200 reason OK headers {} body $body]
                }
                /deflated-data {
                    set body [::tclwire::negotiation_payload]
                    return [dict create \
                        status 200 reason OK body [zlib compress $body] \
                        headers [list "Content-Encoding: deflate"] \
                        body_mode binary]
                }
                /chunked-data {
                    set body [::tclwire::negotiation_payload]
                    set stream_chunks {}
                    for {set offset 0} {$offset < [string length $body]} {incr offset 16} {
                        lappend stream_chunks \
                            [list 0 [string range $body $offset [expr {$offset + 15}]]]
                    }
                    return [dict create \
                        status 200 reason OK body {} headers {} \
                        transfer_encoding chunked \
                        stream_chunks $stream_chunks]
                }
                /slow-chunked-data {
                    set body [::tclwire::negotiation_payload]
                    return [dict create \
                        status 200 reason OK body {} headers {} \
                        transfer_encoding chunked \
                        stream_chunks [list \
                            [list 0 [string range $body 0 9]] \
                            [list 50 [string range $body 10 end]]]]
                }
                /slow-body-1 {
                    set body [::tclwire::negotiation_payload]
                    return [dict create \
                        status 200 reason OK body {} headers {} \
                        transfer_encoding chunked \
                        stream_chunks [list \
                            [list 0 [string range $body 0 9]] \
                            [list 6000 [string range $body 10 end]]]]
                }
                /slow-body-2 {
                    set body [string range [::tclwire::range_fixture] 0 191]
                    set stream_chunks {}
                    for {set offset 0} {$offset < [string length $body]} {incr offset 32} {
                        lappend stream_chunks \
                            [list 1000 [string range $body $offset [expr {$offset + 31}]]]
                    }
                    return [dict create \
                        status 200 reason OK body {} headers {} \
                        transfer_encoding chunked \
                        stream_chunks $stream_chunks]
                }
                /range-data {
                    return [my byte_range_response $request [::tclwire::range_fixture]]
                }
                /shutdown {
                    set ::tclwire::forever "no more"
                    return [dict create \
                        status 200 reason OK headers {} body "server orderly shutdown\n"]
                }
                default {
                    if {$method eq "GET" || $method eq "HEAD"} {
                        set static_response [my static_response $path]
                        if {$static_response ne {}} {
                            return $static_response
                        }
                    }
                    return [dict create \
                        status 200 reason OK headers {} body "path=$path\n"]
                }
            }
        }

        method emit_response {request response} {
            if {[dict exists $response delay_ms]} {
                after [dict get $response delay_ms]
            }
            if {[dict exists $response close_only] && [dict get $response close_only]} {
                ::tclwire::io close_connection
                return
            }

            set status [dict get $response status]
            set reason [dict get $response reason]
            set headers [dict get $response headers]
            set body_mode [my response_body_mode $response]
            set encoding {}
            if {$body_mode eq "text"} {
                set encoding [my encoding]
            }
            if {[dict exists $response transfer_encoding] &&
                    [dict get $response transfer_encoding] eq "chunked"} {
                lappend headers "Transfer-Encoding: chunked"
            }

            ::tclwire::io response $status $reason $headers $body_mode $encoding

            if {[$request method] eq "HEAD"} {
                ::tclwire::http::no_body
                return
            }

            if {[dict exists $response body] && [dict get $response body] ne {}} {
                ::tclwire::io out [dict get $response body] $body_mode
            }
            if {[dict exists $response stream_chunks]} {
                foreach chunk [dict get $response stream_chunks] {
                    lassign $chunk delay_ms data
                    if {$delay_ms > 0} {
                        after $delay_ms
                    }
                    ::tclwire::io out $data $body_mode
                    ::tclwire::io flush
                }
            }
            return
        }

        method response_body_mode {response} {
            if {[dict exists $response body_mode]} {
                return [dict get $response body_mode]
            }
            return text
        }

        method seed_docroot_fixtures {} {
            set docroot [my document_root]
            file mkdir $docroot

            my write_docroot_fixture index.html [join [list \
                {<!doctype html>} \
                {<html lang="en">} \
                {<head>} \
                {<meta charset="utf-8">} \
                {<title>Tclcurl tiny web server</title>} \
                {</head>} \
                {<body>} \
                {<h1>Tclcurl tiny web server</h1>} \
                {<p>Pseudo docroot index for the tclcurl-ng HTTP test server.</p>} \
                {</body>} \
                {</html>} \
                {}] "\n"]

            my write_docroot_fixture tclcurl-man.html [join [list \
                {<!doctype html>} \
                {<html lang="en">} \
                {<head>} \
                {<meta charset="utf-8">} \
                {<title>TclCurl</title>} \
                {</head>} \
                {<body>} \
                {<h1>TclCurl</h1>} \
                {<p>Pseudo manual page for the tclcurl-ng HTTP test server.</p>} \
                {</body>} \
                {</html>} \
                {}] "\n"]
        }

        method write_docroot_fixture {name content} {
            set path [file join [my document_root] $name]
            set channel [open $path wb]
            try {
                puts -nonewline $channel $content
            } finally {
                close $channel
            }
            return $path
        }

        method basic_auth_response {request} {
            set expected_user testuser
            set expected_password testpass
            set authorization [$request header authorization]

            if {![regexp {^Basic\s+(.+)$} $authorization -> auth_blob]} {
                return [my unauthorized_response auth=missing]
            }
            if {[catch {set decoded [::base64::decode $auth_blob]}]} {
                return [my unauthorized_response auth=invalid]
            }
            if {![regexp {^([^:]+):(.*)$} $decoded -> username password]} {
                return [my unauthorized_response auth=invalid]
            }
            if {$username ne $expected_user || $password ne $expected_password} {
                return [my unauthorized_response auth=denied]
            }

            return [dict create \
                status 200 reason OK \
                headers [list "Content-Type: text/plain; charset=utf-8"] \
                body "auth=ok\nuser=$username\n"]
        }

        method unauthorized_response {body_line} {
            return [dict create \
                status 401 \
                reason "Unauthorized" \
                body "$body_line\n" \
                headers [list "WWW-Authenticate: Basic realm=\"TclCurl Test\""]]
        }

        method redirect_response {location {reason "Found"}} {
            return [dict create \
                status 302 \
                reason $reason \
                body "redirect=$location\n" \
                headers [list "Location: $location"]]
        }

        method static_response {path} {
            set local_path [my local_path $path]
            if {$local_path eq {}} {
                return {}
            }
            return [dict create \
                status 200 \
                reason OK \
                body [my read_file $local_path] \
                headers [list "Content-Type: [my content_type $local_path]"] \
                body_mode binary]
        }

        method read_binary_file {path} {
            return [my read_file $path]
        }

        method request_body {request} {
            switch -exact -- [$request body_storage] {
                in_memory {
                    return [$request body]
                }
                spooled_file {
                    return [my read_file [$request body_path]]
                }
                decomposed {
                    return {}
                }
                none {
                    return {}
                }
                default {
                    error "unknown HTTP request body storage: [$request body_storage]"
                }
            }
        }

        method multipart_inspection_lines {request} {
            if {![$request is_multipart]} {
                return {}
            }

            set lines [list "multipart=1"]
            set index 0
            foreach part [$request multipart_parts] {
                incr index
                set prefix "part.$index"
                lappend lines "$prefix.body-storage=[my escape_response_value \
                    [my multipart_part_storage $part]]"
                set part_body [my multipart_part_body $part]
                lappend lines "$prefix.body-length=[string length $part_body]"
                lappend lines "$prefix.body-hex=[binary encode hex $part_body]"
                lappend lines "$prefix.body-sha256=[::sha2::sha256 -hex $part_body]"

                foreach field {name filename content_type disposition} {
                    if {[dict exists $part $field]} {
                        lappend lines "$prefix.[string map {_ -} $field]=[my escape_response_value \
                            [dict get $part $field]]"
                    }
                }

                if {[dict exists $part headers]} {
                    dict for {name value} [dict get $part headers] {
                        set key "$prefix.header.[string tolower $name]"
                        lappend lines "$key=[my escape_response_value $value]"
                    }
                }

                if {[dict exists $part name]} {
                    set part_name [dict get $part name]
                    set safe_name [my safe_response_key $part_name]
                    lappend lines "part-name.$index=[my escape_response_value $part_name]"
                    if {[dict exists $part filename]} {
                        lappend lines "file.$safe_name.filename=[my escape_response_value \
                            [dict get $part filename]]"
                        if {[dict exists $part content_type]} {
                            lappend lines "file.$safe_name.content-type=[my escape_response_value \
                                [dict get $part content_type]]"
                        }
                        lappend lines "file.$safe_name.body-length=[string length $part_body]"
                        lappend lines "file.$safe_name.body-hex=[binary encode hex $part_body]"
                        lappend lines "file.$safe_name.body-sha256=[::sha2::sha256 -hex $part_body]"
                    } else {
                        lappend lines "form.$safe_name=[my escape_response_value $part_body]"
                    }
                }
            }
            return $lines
        }

        method multipart_part_body {part} {
            if {[dict exists $part body]} {
                return [dict get $part body]
            }
            if {[dict exists $part body_storage] &&
                    [dict get $part body_storage] eq "spooled_file" &&
                    [dict exists $part body_path]} {
                return [my read_file [dict get $part body_path]]
            }
            return {}
        }

        method multipart_part_storage {part} {
            if {[dict exists $part body_storage]} {
                return [dict get $part body_storage]
            }
            if {[dict exists $part body]} {
                return in_memory
            }
            return none
        }

        method safe_response_key {value} {
            set key {}
            foreach character [split $value {}] {
                if {[string is alnum -strict $character] || $character in {_ -}} {
                    append key $character
                } else {
                    append key _[binary encode hex [encoding convertto utf-8 $character]]
                }
            }
            return $key
        }

        method escape_response_value {value} {
            return [string map [list "\\" "\\\\" "\n" "\\n" "\r" "\\r"] $value]
        }

        method byte_range_response {request full_body} {
            set total_length [string length $full_body]
            set range_header [$request header range]
            if {$range_header eq {}} {
                return [dict create \
                    status 200 reason OK body $full_body \
                    headers [list "Accept-Ranges: bytes"]]
            }

            if {![regexp {^bytes=\s*([0-9]+-[0-9]+)(\s*,\s*([0-9]+-[0-9]+))*$} $range_header]} {
                return [dict create \
                    status 416 reason "Range Not Satisfiable" body {} \
                    headers [list "Content-Range: bytes */$total_length"]]
            }

            set ranges {}
            foreach range_spec [split [string range $range_header 6 end] ,] {
                set range_spec [string trim $range_spec]
                lassign [split $range_spec -] start end
                if {$start > $end || $end >= $total_length} {
                    return [dict create \
                        status 416 reason "Range Not Satisfiable" body {} \
                        headers [list "Content-Range: bytes */$total_length"]]
                }
                lappend ranges [list $start $end]
            }

            if {[llength $ranges] == 1} {
                lassign [lindex $ranges 0] start end
                return [dict create \
                    status 206 \
                    reason "Partial Content" \
                    body [string range $full_body $start $end] \
                    headers [list \
                        "Accept-Ranges: bytes" \
                        "Content-Range: bytes $start-$end/$total_length"]]
            }

            set boundary tclcurl-boundary
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
            return [dict create \
                status 206 \
                reason "Partial Content" \
                body $range_body \
                headers [list \
                    "Accept-Ranges: bytes" \
                    "Content-Type: multipart/byteranges; boundary=$boundary"]]
        }

        unexport basic_auth_response byte_range_response emit_response \
            escape_response_value multipart_inspection_lines multipart_part_body \
            multipart_part_storage read_binary_file redirect_response request_body \
            response_body_mode safe_response_key \
            seed_docroot_fixtures static_response write_docroot_fixture \
            unauthorized_response
    }
}
