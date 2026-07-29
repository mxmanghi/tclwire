# rivet_app.tcl --
#
# Default application class for the TclWire Apache Rivet compatibility
# environment.

package require tclwire::application 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::tclwire::envs::rivet {}

oo::class create ::tclwire::envs::rivet::Application {
    superclass ::tclwire::CApplication

    method rivet_script_path {request} {
        set path [$request path]
        if {[catch {set candidate [my url_file_candidate $path]}]} {
            return {}
        }
        if {$candidate eq {} || [file extension $candidate] ne ".tcl"} {
            return {}
        }
        return $candidate
    }

    method handle_request {request} {
        set script [my rivet_script_path $request]
        if {$script eq {}} {
            next $request
            return
        }
        source $script
        return
    }
}
