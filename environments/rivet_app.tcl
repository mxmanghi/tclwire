# rivet_app.tcl --
#
# Default application class for the TclWire Apache Rivet compatibility
# environment.

package require tclwire::application 0.1

source [file join [file dirname [info script]] rivet_commands.tcl]

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::tclwire::envs::app {}

if {[info commands ::tclwire::envs::app::Rivet] ne {}} {
    if {![info object isa class ::tclwire::envs::app::Rivet]} {
        error "application command is not a TclOO class: ::tclwire::envs::app::Rivet"
    }
    ::tclwire::envs::app::Rivet destroy
}

oo::class create ::tclwire::envs::app::Rivet {
    superclass ::tclwire::CApplication

    method initialize {} {
        set script [::rivet::inspect ChildInitScript]
        if {[::tclwire::envs::rivet::configured_script $script]} {
            namespace eval :: $script
        }

        # A CGA worker is reused across requests and applications. Do not
        # change its process-wide working directory during initialization;
        # request handlers that require a particular directory establish and
        # restore it within their request scope.
        return
    }

    method shutdown {} {
        set script [::rivet::inspect ChildExitScript]
        if {[::tclwire::envs::rivet::configured_script $script]} {
            namespace eval :: $script
        }
        return
    }

    method content_type {path} {
        if {[string tolower [file extension $path]] in {".tcl" ".rvt"}} {
            return "text/html; charset=[my encoding]"
        }
        return [next $path]
    }

    method handle_request {request} {
        set script {}
        set script_path {}
        set previous_directory {}
        set changed_directory 0
        ::try {
            ::Rivet::initialize_request
        } on error {err} {
            ::rivet::apache_log_error crit "Rivet request initialization failed: $::errorInfo"
        }

        ::try {
            if {[catch {set resolution [my resolve_request_path $request]}]} {
                my log_file_resolution $request 400 {} error
                my send_error 400 [$request url_path]
                return
            }
            if {$resolution eq {}} {
                next $request
                return
            }

            set script_path [$request local_path]
            if {$script_path eq {}} {
                next $request
                return
            }

            set file_extension [file extension $script_path]
            if {$file_extension eq ".rvt"} {
                set ns "::request"
            } elseif {$file_extension eq ".tcl"} {
                set ns "::"
            } else {
                next $request
                return
            }

            set previous_directory [pwd]
            cd [file dirname $script_path]
            set changed_directory 1

            set script [::rivet::url_script]
            if {$script eq {}} {
                next $request
                return
            }

            ::tclwire::http::io header set Content-Type [my content_type $script_path]

            set before_script [::rivet::inspect BeforeScript]
            if {[::tclwire::envs::rivet::configured_script $before_script]} {
                set ::Rivet::script $before_script
                eval $before_script
            }

            set ::Rivet::script $script
            namespace eval $ns $script
        } trap {RIVET ABORTPAGE} {err opts} {
            ::Rivet::finish_request $script $err $opts AbortScript
        } trap {RIVET THREAD_EXIT} {err opts} {
            ::Rivet::finish_request $script $err $opts AbortScript
        } on error {err opts} {
            ::Rivet::finish_request $script $err $opts
        } finally {
            ::try {
                ::Rivet::finish_request $script "" "" AfterEveryScript
            } finally {
                if {$changed_directory} {
                    cd $previous_directory
                }
                ::Rivet::cleanup_request
            }
        }

        return
    }
}
