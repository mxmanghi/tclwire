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
    variable rivet_version 3.3.0tw

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
        ImportRivetNS
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
        if {$option eq "ImportRivetNS"} {
            return false
        }
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

    proc load_server {{array_name ::server}} {
        variable rivet_version

        set configuration [::tclwire::app::configuration]
        upvar #0 $array_name target
        unset -nocomplain target
        array set target [list \
            RIVET_VERSION $rivet_version \
            SERVER_CONF   [$configuration file]]
        return
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

    proc query_var_pairs {} {
        set request [::tclwire::app::request]
        return [urlencoded_pairs [$request query]]
    }

    proc post_var_pairs {} {
        set request    [::tclwire::app::request]
        set descriptor [::tclwire::app::request_descriptor]

        if {[dict exists $descriptor multipart_parts]} {
            return [multipart_form_pairs [dict get $descriptor multipart_parts]]
        }

        if {[$request media_type] eq "application/x-www-form-urlencoded" &&
                [$request body_storage] eq "in_memory"} {
            return [urlencoded_pairs [$request body]]
        }
        return {}
    }

    proc var_pairs {source} {
        switch -exact -- $source {
            query {
                return [query_var_pairs]
            }
            post {
                return [post_var_pairs]
            }
            all {
                return [list {*}[query_var_pairs] {*}[post_var_pairs]]
            }
            default {
                error "unknown Rivet variable source: $source"
            }
        }
    }

    proc vars_by_name {source} {
        set variables [dict create]
        foreach {name value} [var_pairs $source] {
            if {[dict exists $variables $name]} {
                dict lappend variables $name $value
            } else {
                dict set variables $name [list $value]
            }
        }
        return $variables
    }

    proc var_value_string {values} {
        if {[llength $values] == 1} {
            return [lindex $values 0]
        }
        return $values
    }

    proc var {source args} {
        if {[llength $args] < 1 || [llength $args] > 3} {
            var_wrong_args
        }
        set command [lindex $args 0]
        set variables [vars_by_name $source]

        switch -exact -- $command {
            get {
                if {[llength $args] ni {2 3}} {
                    error {wrong # args: should be "::rivet::var get variablename ?defaultval?"}
                }
                set name [lindex $args 1]
                if {[dict exists $variables $name]} {
                    return [var_value_string [dict get $variables $name]]
                }
                if {[llength $args] == 3} {
                    return [lindex $args 2]
                }
                return {}
            }
            list {
                if {[llength $args] != 2} {
                    error {wrong # args: should be "::rivet::var list variablename"}
                }
                set name [lindex $args 1]
                if {[dict exists $variables $name]} {
                    return [dict get $variables $name]
                }
                return {}
            }
            exists {
                if {[llength $args] != 2} {
                    error {wrong # args: should be "::rivet::var exists variablename"}
                }
                return [dict exists $variables [lindex $args 1]]
            }
            names {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::rivet::var names"}
                }
                return [dict keys $variables]
            }
            number {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::rivet::var number"}
                }
                return [dict size $variables]
            }
            all {
                if {[llength $args] ni {1 2}} {
                    error {wrong # args: should be "::rivet::var all ?default_values?"}
                }
                set result [dict create]
                dict for {name values} $variables {
                    dict set result $name [var_value_string $values]
                }
                if {[llength $args] == 2} {
                    set defaults [lindex $args 1]
                    if {[catch {dict size $defaults}]} {
                        return -code error -errorcode invalid_dictionary_value \
                            {Impossible to interpret the default values argument as a dictionary value}
                    }
                    dict for {name value} $defaults {
                        if {![dict exists $result $name]} {
                            dict set result $name $value
                        }
                    }
                }
                return $result
            }
            default {
                error {bad option: must be one of 'get, list, exists, names, number, all'}
            }
        }
    }

    proc var_wrong_args {} {
        error {wrong # args: should be "::rivet::var (get varname ?default?|list varname|exists varname|names|number|all ?default_values?)"}
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

    proc clock_to_rfc850_gmt {seconds} {
        return [clock format $seconds -format "%a, %d-%b-%y %T GMT" -gmt 1 \
            -locale C]
    }

    proc cookie_jar {} {
        return [[::tclwire::app::request] cookie_jar]
    }

    proc cookie_option_error {} {
        error {wrong # args: should be "::rivet::cookie set name value ?-days expireInDays? ?-hours expireInHours? ?-minutes expireInMinutes? ?-expires expiration? ?-path uriPath? ?-domain domain? ?-secure 1/0? ?-HttpOnly 1/0?"}
    }

    proc cookie_attributes {option_values} {
        set attributes {}
        set expires_in 0
        set has_relative_expiration 0

        foreach {option value} $option_values {
            switch -exact -- $option {
                -expires {
                    dict set attributes expires $value
                }
                -days {
                    if {![string is integer -strict $value]} {
                        error "invalid cookie expiration interval"
                    }
                    incr expires_in [expr {$value * 86400}]
                    set has_relative_expiration 1
                }
                -hours {
                    if {![string is integer -strict $value]} {
                        error "invalid cookie expiration interval"
                    }
                    incr expires_in [expr {$value * 3600}]
                    set has_relative_expiration 1
                }
                -minutes {
                    if {![string is integer -strict $value]} {
                        error "invalid cookie expiration interval"
                    }
                    incr expires_in [expr {$value * 60}]
                    set has_relative_expiration 1
                }
                -path {
                    ::tclwire::http::cookie::validate_path $value
                    dict set attributes path $value
                }
                -domain {
                    ::tclwire::http::cookie::validate_domain $value
                    dict set attributes domain $value
                }
                -secure -
                -HttpOnly {
                    if {![string is boolean -strict $value]} {
                        error "invalid cookie attribute value: $option"
                    }
                    dict set attributes [string range $option 1 end] \
                        [expr {!!$value}]
                }
                default {
                    error "unknown cookie option: $option"
                }
            }
        }

        if {![dict exists $attributes expires] && $has_relative_expiration} {
            dict set attributes expires \
                [clock_to_rfc850_gmt [expr {[clock seconds] + $expires_in}]]
        }
        return $attributes
    }

    proc set_cookie_header {name value attributes} {
        ::tclwire::http::cookie::validate_name $name
        ::tclwire::http::cookie::validate_value $value

        set cookie "$name=$value"
        foreach key {expires path domain} {
            if {[dict exists $attributes $key]} {
                append cookie "; $key=[dict get $attributes $key]"
            }
        }
        if {[dict exists $attributes secure] && [dict get $attributes secure]} {
            append cookie "; secure"
        }
        if {[dict exists $attributes HttpOnly] && [dict get $attributes HttpOnly]} {
            append cookie "; HttpOnly"
        }

        ::tclwire::http::io header add Set-Cookie $cookie
        return $cookie
    }

    proc parse_template {template} {
        set script {}
        set offset 0
        set length [string length $template]

        while {$offset < $length} {
            set start [string first "<?" $template $offset]
            if {$start < 0} {
                append_literal script [string range $template $offset end]
                break
            }

            append_literal script [string range $template $offset $start-1]
            set code_start [expr {$start + 2}]
            set echo 0
            if {[string index $template $code_start] eq "="} {
                set echo 1
                incr code_start
            }

            set end [string first "?>" $template $code_start]
            if {$end < 0} {
                error "unterminated Rivet template Tcl block"
            }

            set code [string range $template $code_start $end-1]
            if {$echo} {
                append script [list puts -nonewline] " " $code "\n"
            } else {
                append script $code "\n"
            }
            set offset [expr {$end + 2}]
        }

        return $script
    }

    proc append_literal {script_variable literal} {
        upvar 1 $script_variable script
        if {$literal eq {}} {
            return
        }
        append script [list puts -nonewline $literal] "\n"
        return
    }

    proc read_template_file {path {encoding {}}} {
        if {$encoding eq {}} {
            return [fileutil::cat $path]
        }
        if {$encoding ni [encoding names]} {
            error "unknown encoding \"$encoding\""
        }
        set channel [open $path r]
        try {
            chan configure $channel -encoding $encoding -translation binary
            return [read $channel]
        } finally {
            close $channel
        }
    }

    proc file_script {application path} {
        if {[catch {set candidate [$application local_path $path]}]} {
            return {}
        }
        set extension [string tolower [file extension $candidate]]
        if {$candidate eq {} || $extension ni {".rvt" ".tcl"}} {
            return {}
        }
        set content [read_template_file $candidate]
        if {$extension eq ".rvt"} {
            return [parse_template $content]
        }
        return $content
    }

    proc parse_file_path {path virtual} {
        if {$virtual} {
            return [virtual_include_path $path]
        }
        return [filesystem_include_path $path]
    }

    proc parse {args} {
        set encoding {}
        set virtual 0
        set string_mode 0
        set source_value {}

        set index 0
        while {$index < [llength $args]} {
            set argument [lindex $args $index]
            switch -exact -- $argument {
                -encoding {
                    incr index
                    if {$index >= [llength $args] || $string_mode ||
                            $source_value ne {}} {
                        parse_wrong_args
                    }
                    set encoding [lindex $args $index]
                }
                -virtual {
                    if {$string_mode || $source_value ne {}} {
                        parse_wrong_args
                    }
                    set virtual 1
                }
                -string {
                    incr index
                    if {$index >= [llength $args] || $encoding ne {} ||
                            $virtual || $source_value ne {}} {
                        parse_wrong_args
                    }
                    set string_mode 1
                    set source_value [lindex $args $index]
                }
                default {
                    if {$source_value ne {}} {
                        parse_wrong_args
                    }
                    set source_value $argument
                }
            }
            incr index
        }

        if {$source_value eq {}} {
            parse_wrong_args
        }

        if {$string_mode} {
            set template $source_value
        } else {
            set path [parse_file_path $source_value $virtual]
            if {$path eq {} || ![file isfile $path] || ![file readable $path]} {
                error "could not read Rivet template file"
            }
            set template [read_template_file $path $encoding]
        }

        set script [parse_template $template]
        uplevel 1 $script
    }

    proc parse_wrong_args {} {
        error {wrong # args: should be "::rivet::parse ?-encoding encoding? ?-virtual? filename | -string template_string"}
    }

    proc lempty {list} {
        if {[catch {llength $list} len]} {
            return 0
        }
        return [expr {$len == 0}]
    }

    proc html {string args} {
        set output {}
        foreach arg $args {
            append output <$arg>
        }
        append output $string
        for {set i [expr {[llength $args] - 1}]} {$i >= 0} {incr i -1} {
            append output </[lindex [lindex $args $i] 0]>
        }
        puts $output
        return
    }

    proc xml {textstring args} {
        set single_element [lempty $args]
        if {$single_element} {
            set tags_list [list $textstring]
            if {[lempty $tags_list]} {
                return {}
            }
        } else {
            set tags_list $args
        }

        set tags_stack {}
        set el {}
        set xmlout {}
        foreach el $tags_list {
            set el [lassign $el tag]
            lappend tags_stack $tag
            append xmlout "<$tag"

            foreach {attrib attrib_v} $el {
                append xmlout " $attrib=\"$attrib_v\""
            }
            append xmlout ">"
        }

        if {[lempty $tags_stack]} {
            return $textstring
        } elseif {$single_element} {
            if {[lempty $el]} {
                set xmlout [string replace $xmlout end end " />"]
            } else {
                set xmlout [string replace $xmlout end end "/>"]
            }

            if {[llength $tags_stack] > 1} {
                append xmlout </[join [lreverse [lrange $tags_stack 0 end-1]] "></"]>
            }
            return $xmlout
        } else {
            return [append xmlout "$textstring</[join [lreverse $tags_stack] "></"]>"]
        }
    }

    proc cookie {cmd name args} {
        switch -exact -- $cmd {
            set {
                if {[llength $args] < 1 || [llength $args] % 2 != 1} {
                    cookie_option_error
                }
                set value [lindex $args 0]
                set option_values [lrange $args 1 end]
                set attributes [cookie_attributes $option_values]

                set jar_args {}
                if {[dict exists $attributes path]} {
                    lappend jar_args -path [dict get $attributes path]
                }
                if {[dict exists $attributes expires]} {
                    lappend jar_args -expires [dict get $attributes expires]
                }
                if {[dict exists $attributes domain]} {
                    lappend jar_args -domain [dict get $attributes domain]
                }
                foreach option {-secure -HttpOnly} key {secure HttpOnly} {
                    if {[dict exists $attributes $key]} {
                        lappend jar_args $option [dict get $attributes $key]
                    }
                }
                [cookie_jar] set $name $value {*}$jar_args
                return [set_cookie_header $name $value $attributes]
            }
            get {
                if {[llength $args] != 0} {
                    error {wrong # args: should be "::rivet::cookie get name"}
                }
                return [[cookie_jar] get $name]
            }
            delete {
                if {[llength $args] != 0} {
                    error {wrong # args: should be "::rivet::cookie delete name"}
                }
                [cookie_jar] unset $name
                return [cookie set $name {} -minutes -1]
            }
            unset {
                if {[llength $args] != 0} {
                    error {wrong # args: should be "::rivet::cookie unset name"}
                }
                [cookie_jar] unset $name
                return
            }
            default {
                error "bad cookie operation \"$cmd\": must be set, get, delete, or unset"
            }
        }
    }

    proc install_commands {} {

        # Init the ::Rivet namespace

        namespace eval ::Rivet {}
        proc ::Rivet::initialize_request {} {
            ::tclwire::envs::rivet::reset_abort_state
            ::tclwire::envs::rivet::load_server
            catch { namespace delete ::request }
            namespace eval ::request {}
            set application [::tclwire::app::current]
            set application_namespace [info object namespace $application]
            namespace eval ::request \
                [list namespace path [namespace eval $application_namespace {namespace path}]]

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

        proc ::rivet::parse {args} {
            uplevel 1 [list ::tclwire::envs::rivet::parse {*}$args]
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

        proc ::rivet::var {args} {
            tailcall ::tclwire::envs::rivet::var all {*}$args
        }

        proc ::rivet::var_qs {args} {
            tailcall ::tclwire::envs::rivet::var query {*}$args
        }

        proc ::rivet::var_post {args} {
            tailcall ::tclwire::envs::rivet::var post {*}$args
        }

        proc ::rivet::lempty {list} {
            tailcall ::tclwire::envs::rivet::lempty $list
        }

        proc ::rivet::html {string args} {
            tailcall ::tclwire::envs::rivet::html $string {*}$args
        }

        proc ::rivet::xml {textstring args} {
            tailcall ::tclwire::envs::rivet::xml $textstring {*}$args
        }

        proc ::rivet::url_script {} {
            set application [::tclwire::app::current]
            set request     [::tclwire::app::request]

            return [::tclwire::envs::rivet::file_script $application \
                [$request path]]
        }

        proc ::rivet::abort_page {{code {}}} {
            tailcall ::tclwire::envs::rivet::abort_page $code
        }

        proc ::rivet::abort_code {} {
            tailcall ::tclwire::envs::rivet::abort_code
        }

        proc ::rivet::clock_to_rfc850_gmt {seconds} {
            tailcall ::tclwire::envs::rivet::clock_to_rfc850_gmt $seconds
        }

        proc ::rivet::cookie {cmd name args} {
            tailcall ::tclwire::envs::rivet::cookie $cmd $name {*}$args
        }

        namespace eval ::rivet {
            namespace export abort_code abort_page apache_log_error env header include \
                             inspect load_cookies load_env load_headers load_response \
                             parse html lempty xml clock_to_rfc850_gmt cookie \
                             inspect url_script var var_qs var_post
        }
        return
    }
}
