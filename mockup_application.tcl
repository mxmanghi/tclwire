# http_server.tcl -- Implementation of the basic HTTP server application
#
# Implementation of a base application 
#
# Copyright (c) 2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.
namespace eval ::tclwire {}
if {[info commands ::tclwire::CApplication] eq {}} {
    source [file join [file dirname [file normalize [info script]]] http_application.tcl]
}

oo::class create ::tclwire::CMockUpApplication {
    superclass ::tclwire::CApplication

    variable logger

    constructor {l} {
        set logger $l
    }

    destructor {
        $logger destroy
    }

    method request_handling {args} {
        $logger "args: $args"
    }

    method wait_for_nsecs {n} {
        $logger log "[::thread::id] starts sleeping"
        after [expr 1000*$n]
        $logger log "[::thread::id] awakes"
    }

}
