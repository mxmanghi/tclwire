# rivet_commands.tcl --
#
# Apache Rivet compatibility commands installed into ::rivet.

package require tclwire::content_generator_agent 0.1
package require fileutil

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::tclwire::envs::rivet {}

if {[info commands ::tclwire::app::current] eq {}} {
    error "Rivet commands require ::tclwire::app"
}

namespace eval ::tclwire::envs::rivet {
    variable inspect_options {
        ServerInitScript
        GlobalInitScript
        ChildInitScript
        ChildExitScript
        BeforeScript
        AfterScript
        AfterEveryScript
        AbortScript
        ErrorScript
        UploadMaxSize
        UploadDirectory
        UploadFilesToVar
        SeparateVirtualInterps
        HonorHeadRequests
    }

    proc inspect_key {option} {
        variable inspect_options
        if {$option ni $inspect_options} {
            error "bad inspect option \"$option\": must be [join $inspect_options {, }]"
        }
        set key [regsub -all {([a-z0-9])([A-Z])} $option {\1_\2}]
        return [string tolower $key]
    }

    proc inspect_value {option} {
        set key [inspect_key $option]
        set application [::tclwire::app::current]
        set configuration [::tclwire::app::configuration]
        set options [$configuration class_configuration [info object class $application]]
        if {![dict exists $options $key]} {
            return {}
        }
        return [dict get $options $key]
    }

    proc install_commands {} {

        # Init the ::Rivet namespace

        namespace eval ::Rivet {}
        proc ::Rivet::initialize_request {} {
            catch { namespace delete ::request }
            namespace eval ::request {}
            set application [::tclwire::app::current]
            set application_namespace [info object namespace $application]
            namespace eval ::request [list namespace path \
                [namespace eval $application_namespace {namespace path}]]

            proc ::request::global {args} {
                foreach arg $args {
                    uplevel "::global ::request::$arg"
                }
            }
            return
        }

        proc ::Rivet::print_error_message {error_header} {
            puts "<strong>$error_header</strong><br/><pre>$::errorInfo</pre>"
        }

        proc ::Rivet::handle_error {} {
            puts "<pre>$::errorInfo<hr/><p>OUTPUT BUFFER:</p>$::Rivet::script</pre>"
        }

        proc ::Rivet::finish_request {script errorCode errorOpts {scriptName ""}} {
            set ::Rivet::errorCode $errorCode
            set ::Rivet::errorOpts $errorOpts

            if {$scriptName ne ""} {
                set scriptBody [::rivet::inspect $scriptName]
                ::try {
                    uplevel #0 $scriptBody
                } on ok {} {
                    return
                } on error {} {
                    ::rivet::apache_log_error err "Rivet $scriptName failed: $::errorInfo"
                    print_error_message "Rivet $scriptName failed"
                }
            }

            set error_script [::rivet::inspect ErrorScript]
            if {$error_script eq ""} {
                set ::errorOutbuf $script ; ## legacy variable
                set error_script ::Rivet::handle_error
            }

            ::try {
                set ::Rivet::script $script
                uplevel #0 $error_script
            } on error {err} {
                ::rivet::apache_log_error err "Rivet ErrorScript failed: $::errorInfo"
                print_error_message "Rivet ErrorScript failed"
            }
        }

        # Init the ::Rivet namespace

        namespace eval ::rivet {}

        proc ::rivet::apache_log_error {args} {
            switch -exact -- [llength $args] {
                1 {
                    set level error
                    set message [lindex $args 0]
                }
                2 {
                    set level [lindex $args 0]
                    set message [lindex $args 1]
                }
                default {
                    error {wrong # args: should be "::rivet::apache_log_error ?level? message"}
                }
            }

            catch {
                ::tclwire::logger log_error rivet \
                    [::tclwire::logger::log_value $message] $level
            }
            return
        }

        proc ::rivet::inspect {args} {
            switch -exact -- [llength $args] {
                1 {
                    return [::tclwire::envs::rivet::inspect_value [lindex $args 0]]
                }
                0 -
                2 {
                    error "::rivet::inspect form is not implemented yet"
                }
                default {
                    error {wrong # args: should be "::rivet::inspect ?option ?value??"}
                }
            }
        }

        proc ::rivet::url_script {} {
            set application [::tclwire::app::current]
            set request     [::tclwire::app::request]

            set path [$request path]
            if {[catch {set candidate [$application local_path $path]}]} {
                return {}
            }
            if {$candidate eq {} || [file extension $candidate] ni {".rvt" ".tcl"}} {
                return {}
            }
            return [fileutil::cat $candidate]
        }

        namespace eval ::rivet {
            namespace export apache_log_error inspect url_script
        }
        return
    }
}
