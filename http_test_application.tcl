# http_test_application.tcl --
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

namespace eval ::tclcurl::testserver {}

package require sha256
package require zlib
package require base64

if {[info commands ::tclcurl::testserver::CApplication] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_application.tcl]
}

if {[info commands ::tclcurl::testserver::CTestApplication] eq {}} {
    # Application that reproduces the current TclCurl test-suite routes. This
    # is the first concrete example of a general server application.
    oo::class create ::tclcurl::testserver::CTestApplication {
        superclass ::tclcurl::testserver::CApplication

        method route_request {service method path target version headers request} {
            if {[regexp {^/redir_([0-9]+)$} $path -> redirect_step]} {
                if {$redirect_step < 5} {
                    return [my redirect_response "/redir_[incr redirect_step]"]
                }

                set body "path=$path\nmethod=$method\n"
                return [dict create status 200 reason OK body $body headers {}]
            }

            if {[regexp {^/wait-([0-9]+)(ms|s)$} $path -> wait_amount wait_unit]} {
                set wait_time $wait_amount
                set close_only 0
                if {$wait_unit eq "s"} {
                    set wait_time [expr {$wait_time * 1000}]
                }
                set query_params [my parse_query $target]
                if {[dict exists $query_params reply] && [dict get $query_params reply] eq "none"} {
                    set close_only 1
                }

                return [dict create \
                    status 200 \
                    reason OK \
                    delay_ms $wait_time \
                    close_only $close_only \
                    body "waited=${wait_amount}${wait_unit}\n" \
                    headers {}]
            }

            if {[regexp {^/cookie-set/([^/]+)/([^/]+)$} $path -> cookie_name cookie_value]} {
                set body "set-cookie=$cookie_name=$cookie_value\n"
                return [dict create status     200     \
                                    reason     OK      \
                                    body       $body   \
                                    headers [list "Set-Cookie: $cookie_name=$cookie_value; Path=/"]]
            }

            switch -- $path {
                / {
                    set static_response [my static_file_response /]
                    if {$static_response ne {}} {
                        return $static_response
                    }
                    set index_path [file join [::tclcurl::test::repo_root] testservers index.html]
                    if {[file exists $index_path]} {
                        set fh [open $index_path rb]
                        try {
                            set body [read $fh]
                        } finally {
                            close $fh
                        }
                        return [dict create \
                            status 200 \
                            reason OK \
                            body $body \
                            headers [list "Content-Type: text/html; charset=utf-8"]]
                    }
                    set body "tclcurl test server\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /tclcurl-man {
                    set static_response [my static_file_response /tclcurl-man.html]
                    if {$static_response ne {}} {
                        return $static_response
                    }
                    set manual_path [::tclcurl::testserver::manual_html_source]
                    if {$manual_path ne {} && [file exists $manual_path]} {
                        set fh [open $manual_path rb]
                        try {
                            set body [read $fh]
                        } finally {
                            close $fh
                        }
                        return [dict create \
                            status 200 \
                            reason OK \
                            body $body \
                            headers [list "Content-Type: text/html; charset=utf-8"]]
                    }
                    set body "path=$path\n"
                    return [dict create status 404 reason "Not Found" body $body headers {}]
                }
                /tclcurl-http-root {
                    set body "tclcurl test server\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /tclcurl-http200alias {
                    set body "http200aliases=matched\n"
                    return [dict create status 200      \
                                        reason OK       \
                                        body $body      \
                                        headers {}      \
                                        status_line "yummy/4.5 200 OK"]
                }
                /tclcurl-missing-resource {
                    set body "not found\n"
                    return [dict create status 404 reason "Not Found" body $body headers {}]
                }
                /autoreferer-start {
                    return [my redirect_response "/autoreferer-target"]
                }
                /autoreferer-target {
                    set referer {}
                    if {[dict exists $headers referer]} {
                        set referer [dict get $headers referer]
                    }
                    set body "method=$method\nreferer=$referer\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /postredir-301 {
                    if {$method eq "POST"} {
                        return [dict create status 301                  \
                                            reason "Moved Permanently"  \
                                            body   "redirect=/postredir-target\n" \
                                            headers [list "Location: /postredir-target"]]
                    }
                    set body "method=$method\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /postredir-target {
                    set body "method=$method\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /cookie-echo {
                    set cookie_header {}
                    if {[dict exists $headers cookie]} {
                        set cookie_header [dict get $headers cookie]
                    }
                    set body "cookie=$cookie_header\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /proxy-target {
                    return [dict create status 200 reason OK body "proxy=ok\n" headers {}]
                }
                /proxy-auth-target {
                    return [dict create status 200 reason OK body "proxy-auth=ok\n" headers {}]
                }
                /auth-basic {
                    set expected_user "testuser"
                    set expected_password "testpass"
                    set authorization [$service header_value $headers authorization]
                    if {![regexp {^Basic\s+(.+)$} $authorization -> auth_blob]} {
                        return [dict create \
                            status 401 \
                            reason "Unauthorized" \
                            body "auth=missing\n" \
                            headers [list "WWW-Authenticate: Basic realm=\"TclCurl Test\""]]
                    }

                    if {[catch {set decoded [::base64::decode $auth_blob]}]} {
                        return [dict create \
                            status 401 \
                            reason "Unauthorized" \
                            body "auth=invalid\n" \
                            headers [list "WWW-Authenticate: Basic realm=\"TclCurl Test\""]]
                    }

                    if {![regexp {^([^:]+):(.*)$} $decoded -> username password]} {
                        return [dict create \
                            status 401 \
                            reason "Unauthorized" \
                            body "auth=invalid\n" \
                            headers [list "WWW-Authenticate: Basic realm=\"TclCurl Test\""]]
                    }

                    if {$username ne $expected_user || $password ne $expected_password} {
                        return [dict create \
                            status 401 \
                            reason "Unauthorized" \
                            body "auth=denied\n" \
                            headers [list "WWW-Authenticate: Basic realm=\"TclCurl Test\""]]
                    }

                    set body "auth=ok\nuser=$username\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /request-inspect {
                    set request_body [my request_body $service $request]
                    set body [join [list \
                                "method=[my escape_response_value $method]" \
                                "path=[my escape_response_value $path]" \
                                "target=[my escape_response_value $target]" \
                                "request-version=[my escape_response_value $version]" \
                                "content-type=[my escape_response_value [$service header_value $headers content-type]]" \
                                "content-length=[my escape_response_value [$service header_value $headers content-length]]" \
                                "accept-encoding=[my escape_response_value [$service header_value $headers accept-encoding]]" \
                                "te=[my escape_response_value [$service header_value $headers te]]" \
                                "connection=[my escape_response_value [$service header_value $headers connection]]" \
                                "user-agent=[my escape_response_value [$service header_value $headers user-agent]]" \
                                "referer=[my escape_response_value [$service header_value $headers referer]]" \
                                "x-tclcurl-test=[my escape_response_value [$service header_value $headers x-tclcurl-test]]" \
                                "body-length=[string length $request_body]" \
                                "body-hex=[binary encode hex $request_body]" \
                                "body-sha256=[::sha2::sha256 -hex $request_body]"] "\n"]
                    append body "\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
                /deflated-data {
                    set body [::tclcurl::test::negotiation_payload]
                    return [dict create \
                        status 200 \
                        reason OK \
                        body [zlib compress $body] \
                        headers [list "Content-Encoding: deflate"]]
                }
                /chunked-data {
                    set body [::tclcurl::test::negotiation_payload]
                    return [dict create \
                        status 200 \
                        reason OK \
                        body $body \
                        headers {} \
                        transfer_encoding chunked]
                }
                /slow-chunked-data {
                    set body [::tclcurl::test::negotiation_payload]
                    return [dict create \
                        status 200 \
                        reason OK \
                        body {} \
                        headers {} \
                        transfer_encoding chunked \
                        stream_chunks [list \
                            [list 0 [string range $body 0 9]] \
                            [list 50 [string range $body 10 end]]]]
                }
                /slow-body-1 {
                    set body [::tclcurl::test::negotiation_payload]
                    return [dict create \
                        status 200 \
                        reason OK \
                        body {} \
                        headers {} \
                        stream_chunks [list \
                            [list 0 [string range $body 0 9]] \
                            [list 6000 [string range $body 10 end]]]]
                }
                /slow-body-2 {
                    set body [string range [::tclcurl::test::range_fixture] 0 191]
                    set stream_chunks {}
                    for {set offset 0} {$offset < [string length $body]} {incr offset 32} {
                        lappend stream_chunks [list 1000 [string range $body $offset [expr {$offset + 31}]]]
                    }
                    return [dict create \
                        status 200 \
                        reason OK \
                        body {} \
                        headers {} \
                        stream_chunks $stream_chunks]
                }
                /range-data {
                    return [my byte_range_response $service $headers [::tclcurl::test::range_fixture]]
                }
                /shutdown {
                    set ::tclcurl::testserver::forever "no more"
                    return [dict create status 200 reason OK body "server orderly shutdown\n" headers {}]
                }
                default {
                    if {$method eq "GET" || $method eq "HEAD"} {
                        set static_response [my static_file_response $path]
                        if {$static_response ne {}} {
                            return $static_response
                        }
                    }
                    set body "path=$path\n"
                    return [dict create status 200 reason OK body $body headers {}]
                }
            }
        }
    }
}
