# http_test_application.tcl --
#
# Compatibility loader for the TclCurl test server example.

source [file join \
    [file dirname [file dirname [file normalize [info script]]]] \
    examples tclcurl_test_server.tcl]
