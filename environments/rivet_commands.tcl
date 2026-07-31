# rivet_commands.tcl --
#
# Apache Rivet compatibility commands installed into ::rivet.

package require tclwire::content_generator_agent 0.1
package require tclwire::http::application::io 0.1
package require tclwire::http::query 0.1
package require fileutil

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::tclwire::envs::rivet {}

if {[info commands ::tclwire::app::current] eq {}} {
    error "Rivet commands require ::tclwire::app"
}

namespace eval ::tclwire::envs::rivet {
    variable aborting 0
    variable abort_code {}

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

    proc reset_abort_state {} {
        variable aborting
        variable abort_code

        set aborting 0
        set abort_code {}
        return
    }

    proc aborting {} {
        variable aborting
        return $aborting
    }

    proc abort_code {} {
        variable abort_code
        return $abort_code
    }

    proc request_environment {} {
        set application [::tclwire::app::current]
        set request     [::tclwire::app::request]
        set descriptor  [::tclwire::app::request_descriptor]

        set request_uri [$request path]
        if {[dict exists $descriptor target]} {
            set request_uri [dict get $descriptor target]
        }
        set server_protocol HTTP/1.1
        if {[dict exists $descriptor version]} {
            set server_protocol HTTP/[dict get $descriptor version]
        }

        set environment [dict create \
            DOCUMENT_ROOT   [$application document_root] \
            REQUEST_METHOD  [$request method] \
            REQUEST_URI     $request_uri \
            SCRIPT_NAME     [$request path] \
            SERVER_PROTOCOL $server_protocol \
            QUERY_STRING    [$request query] \
            REMOTE_ADDR     [$request remote_host] \
            REMOTE_PORT     [$request remote_port]]

        if {[$request scheme] eq "https"} {
            dict set environment HTTPS on
        } else {
            dict set environment HTTPS off
        }

        set local_path {}
        catch {set local_path [$application local_path [$request path]]}
        if {$local_path ne {}} {
            dict set environment SCRIPT_FILENAME $local_path
        }

        dict for {name value} [$request headers] {
            set variable [string toupper [string map {- _} $name]]
            switch -exact -- $variable {
                CONTENT_TYPE -
                CONTENT_LENGTH {
                    dict set environment $variable $value
                }
                default {
                    dict set environment HTTP_$variable $value
                }
            }
        }
        return $environment
    }

    proc env {name} {
        set environment [request_environment]
        if {[dict exists $environment $name]} {
            return [dict get $environment $name]
        }
        return {}
    }

    proc load_env {{array_name ::request::env}} {
        upvar #0 $array_name target
        unset -nocomplain target
        array set target [request_environment]
        return
    }

    proc load_headers {{array_name ::request::headers}} {
        set request [::tclwire::app::request]
        upvar #0 $array_name target
        unset -nocomplain target
        array set target [$request headers]
        return
    }

    proc cookie_pairs {} {
        set request [::tclwire::app::request]
        set cookies {}
        foreach field [split [$request header cookie] ";"] {
            set field [string trim $field]
            if {$field eq {}} {
                continue
            }

            set separator [string first = $field]
            if {$separator < 1} {
                continue
            }

            set name [string trim [string range $field 0 $separator-1]]
            set value [string trim [string range $field $separator+1 end]]
            if {[catch {
                ::tclwire::http::cookie::validate_name $name
                ::tclwire::http::cookie::validate_value $value
            }]} {
                continue
            }
            lappend cookies $name $value
        }
        return $cookies
    }

    proc urlencoded_pairs {urlencoded_data} {
        set pairs {}
        foreach field [split $urlencoded_data &] {
            if {$field eq {}} {
                continue
            }

            set separator [string first = $field]
            if {$separator < 0} {
                set name $field
                set value {}
            } else {
                set name [string range $field 0 $separator-1]
                set value [string range $field $separator+1 end]
            }

            lappend pairs \
                [::tclwire::http::query decode_component $name] \
                [::tclwire::http::query decode_component $value]
        }
        return $pairs
    }

    proc multipart_form_pairs {parts} {
        set pairs {}
        foreach part $parts {
            if {[dict exists $part name] && ![dict exists $part filename]} {
                lappend pairs [dict get $part name] [dict get $part body]
            }
        }
        return $pairs
    }

    proc response_pairs {} {
        set request    [::tclwire::app::request]
        set descriptor [::tclwire::app::request_descriptor]
        set pairs [urlencoded_pairs [$request query]]

        if {[dict exists $descriptor multipart_parts]} {
            lappend pairs {*}[multipart_form_pairs \
                [dict get $descriptor multipart_parts]]
            return $pairs
        }

        if {[$request media_type] eq "application/x-www-form-urlencoded" &&
                [$request body_storage] eq "in_memory"} {
            lappend pairs {*}[urlencoded_pairs [$request body]]
        }
        return $pairs
    }

    proc virtual_include_path {path} {
        set application [::tclwire::app::current]
        set request     [::tclwire::app::request]

        if {![string match "/*" $path]} {
            set request_directory [file dirname [$request path]]
            if {$request_directory eq "."} {
                set request_directory /
            }
            set path [string trimright $request_directory /]/$path
        }
        return [$application local_path $path]
    }

    proc filesystem_include_path {path} {
        set application [::tclwire::app::current]
        if {[file pathtype $path] eq "absolute"} {
            return [file normalize $path]
        }
        return [file normalize [file join [$application document_root] $path]]
    }

    proc include {args} {
        switch -exact -- [llength $args] {
            1 {
                set path [filesystem_include_path [lindex $args 0]]
            }
            2 {
                if {[lindex $args 0] ne "-virtual"} {
                    error {wrong # args: should be "::rivet::include ?-virtual? filename"}
                }
                set path [virtual_include_path [lindex $args 1]]
            }
            default {
                error {wrong # args: should be "::rivet::include ?-virtual? filename"}
            }
        }

        if {$path eq {} || ![file isfile $path] || ![file readable $path]} {
            error "could not read included file"
        }

        ::tclwire::io flush
        ::tclwire::io out [::fileutil::cat -translation binary $path] binary
        ::tclwire::io flush
        return
    }

    proc abort_page {{code {}}} {
        variable aborting
        variable abort_code

        if {$code eq "-aborting"} {
            return $aborting
        }

        set aborting 1
        set abort_code $code
        return -code error -errorcode {RIVET ABORTPAGE}
    }

    proc install_commands {} {

        # Init the ::Rivet namespace

        namespace eval ::Rivet {}
        proc ::Rivet::initialize_request {} {
            ::tclwire::envs::rivet::reset_abort_state
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

        proc ::rivet::header {args} {
            tailcall ::tclwire::http::io header {*}$args
        }

        proc ::rivet::env {args} {
            if {[llength $args] != 1} {
                error {wrong # args: should be "::rivet::env environment_variable_name"}
            }
            tailcall ::tclwire::envs::rivet::env [lindex $args 0]
        }

        proc ::rivet::include {args} {
            tailcall ::tclwire::envs::rivet::include {*}$args
        }

        proc ::rivet::load_env {args} {
            if {[llength $args] > 1} {
                error {wrong # args: should be "::rivet::load_env ?arrayName?"}
            }
            tailcall ::tclwire::envs::rivet::load_env {*}$args
        }

        proc ::rivet::load_headers {args} {
            if {[llength $args] > 1} {
                error {wrong # args: should be "::rivet::load_headers ?arrayName?"}
            }
            tailcall ::tclwire::envs::rivet::load_headers {*}$args
        }

        proc ::rivet::load_cookies {{arrayName cookies}} {
            upvar 1 $arrayName cookies
            foreach {key value} [::tclwire::envs::rivet::cookie_pairs] {
                set cookies($key) [list $value]
            }
            return
        }

        proc ::rivet::load_response {{arrayName response}} {
            upvar 1 $arrayName response

            foreach {var elem} [::tclwire::envs::rivet::response_pairs] {
                if {[info exists response(__$var)]} {
                    lappend response($var) $elem
                } elseif {[info exists response($var)]} {
                    set response($var) [list $response($var) $elem]
                    set response(__$var) ""
                } else {
                    set response($var) $elem
                }
            }
            return
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

        proc ::rivet::abort_page {{code {}}} {
            tailcall ::tclwire::envs::rivet::abort_page $code
        }

        proc ::rivet::abort_code {} {
            tailcall ::tclwire::envs::rivet::abort_code
        }

        namespace eval ::rivet {
            namespace export abort_code abort_page apache_log_error env header include \
                inspect load_cookies load_env load_headers load_response url_script
        }
        return
    }
}
