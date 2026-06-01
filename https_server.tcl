# https_server.tcl -- Wrapping TLS around HTTP to have a simple HTTPS server 
#
# Implementation of the HTTP server support used by the TclCurl extension.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclcurl::testserver {}

package require tls

oo::class create ::tclcurl::testserver::https_service {
    superclass ::tclcurl::testserver::http_service

    method description {} {
        return "HTTPS origin test server"
    }

    method start {} {
        if {![::tclcurl::test::https_credentials_available]} {
            puts "https credentials not available, HTTPS tests will not run"
            return
        }

        set listener [::tls::socket -server [list [self] accept] \
            -myaddr [my host] \
            -certfile [::tclcurl::test::https_cert_file] \
            -keyfile [::tclcurl::test::https_key_file] \
            -ssl2 0 \
            -ssl3 0 \
            [my port]]
        my set_listener $listener
        my log [my listening_message]
        return $listener
    }
}

::tclcurl::testserver register_service_class https ::tclcurl::testserver::https_service
