# http_test_support.tcl --
#
# Support helpers for TclCurl-compatible HTTP test application routes.

namespace eval ::tclwire {}

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
