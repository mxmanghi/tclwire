# rivet_commands.tcl --
#
# Apache Rivet compatibility commands installed into ::rivet.

package require tclwire::content_generator_agent 0.1
package require tclwire::http::codes 0.1
package require tclwire::http::application::io 0.1
package require tclwire::http::query 0.1
package require fileutil

if {[info commands ::tclwire::envs::rivet::parser::parse_template] eq {}} {
    source [file join [file dirname [info script]] rivet_parser.tcl]
}

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}
namespace eval ::tclwire::envs::rivet {}

if {[info commands ::tclwire::app::current] eq {}} {
    error "Rivet commands require ::tclwire::app"
}

namespace eval ::tclwire::envs::rivet {
    variable aborting 0
    variable abort_code {}
    variable abort_exiting 0
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
        if {$option eq "HonorHeadRequests"} {
            return true
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

    proc inspect_all {} {
        variable inspect_options

        set result [dict create]
        foreach option $inspect_options {
            set value [inspect_value $option]
            if {$value eq {}} {
                dict set result $option ""
                continue
            }
            dict set result $option $value
        }
        return $result
    }

    proc inspect_script {} {
        set application [::tclwire::app::current]
        set request [::tclwire::app::request]
        set path [$request local_path]
        if {$path eq {}} {
            set path [$application local_path [$request path]]
        }
        if {$path eq {}} {
            return {}
        }
        return [file normalize $path]
    }

    proc inspect_server {} {
        set configuration [::tclwire::app::configuration]
        return [dict create \
            hostname    [$configuration get hostname] \
            admin       [$configuration get admin] \
            errorlog    [$configuration get logerr] \
            server_path [$configuration get server_path]]
    }

    proc configured_script {script} {
        return [expr {$script ne {} && $script ne "undefined"}]
    }

    proc apache_log_level {level} {
        switch -exact -- [string tolower [string trim $level]] {
            error -
            err {
                return error
            }
            warn -
            warning {
                return warn
            }
            emerg -
            alert -
            crit -
            notice -
            info -
            debug {
                return [string tolower [string trim $level]]
            }
            default {
                return error
            }
        }
    }

    proc reset_abort_state {} {
        variable aborting
        variable abort_code
        variable abort_exiting

        set aborting 0
        set abort_code {}
        set abort_exiting 0
        return
    }

    proc aborting {} {
        variable aborting
        return $aborting
    }

    proc abort_code {{option {}}} {
        variable abort_code
        variable abort_exiting

        if {$option eq "-exiting"} {
            return $abort_exiting
        }
        if {$option ne {}} {
            error {wrong # args: should be "::rivet::abort_code ?-exiting?"}
        }
        return $abort_code
    }

    proc exit_request {code} {
        variable aborting
        variable abort_code
        variable abort_exiting

        if {[catch {::Rivet::exit_cleanup $code} message options]} {
            return -options $options $message
        }
        set aborting 1
        set abort_code $code
        set abort_exiting 1
        ::tclwire::cga::request_thread_exit
        return -code error -errorcode {RIVET THREAD_EXIT} $code
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

        set environment [dict create SERVER_SOFTWARE "Tclwire/Rivet" \
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
        upvar 1 $array_name target
        unset -nocomplain target
        array set target [request_environment]
        return
    }

    proc header_array_name {name} {
        set parts {}
        foreach part [split $name -] {
            if {$part eq {}} {
                lappend parts $part
                continue
            }
            lappend parts [string toupper [string index $part 0]][string tolower [string range $part 1 end]]
        }
        return [join $parts -]
    }

    proc load_headers {{array_name ::request::headers}} {
        set request [::tclwire::app::request]
        upvar 1 $array_name target
        unset -nocomplain target
        dict for {name value} [$request headers] {
            set target([header_array_name $name]) $value
        }
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

    proc upload_files {} {
        return [[::tclwire::app::request] uploaded_files]
    }

    proc upload_names {} {
        set names {}
        foreach file [upload_files] {
            if {[dict exists $file name]} {
                set name [dict get $file name]
                if {$name ni $names} {
                    lappend names $name
                }
            }
        }
        return $names
    }

    proc upload_file {name} {
        set file [[::tclwire::app::request] uploaded_file $name]
        if {$file eq {}} {
            error "Unable to find the upload named '$name'"
        }
        return $file
    }

    proc upload_file_data {file} {
        if {[dict exists $file body_storage] &&
                [dict get $file body_storage] eq "spooled_file"} {
            set channel [open [dict get $file body_path] rb]
            try {
                return [read $channel]
            } finally {
                close $channel
            }
        }
        return [dict get $file body]
    }

    proc upload_file_size {file} {
        if {[dict exists $file body_size]} {
            return [dict get $file body_size]
        }
        if {[dict exists $file body_storage] &&
                [dict get $file body_storage] eq "spooled_file"} {
            return [file size [dict get $file body_path]]
        }
        return [string length [dict get $file body]]
    }

    proc upload_tempname {file} {
        foreach key {body_path path} {
            if {[dict exists $file $key]} {
                return [dict get $file $key]
            }
        }
        return {}
    }

    proc upload_channel {file} {
        if {[dict exists $file body_storage] &&
                [dict get $file body_storage] eq "spooled_file"} {
            return [open [dict get $file body_path] rb]
        }

        set channel [file tempfile path]
        chan configure $channel -translation binary
        puts -nonewline $channel [dict get $file body]
        seek $channel 0
        catch {file delete $path}
        return $channel
    }

    proc upload_save {file filename} {
        set source [upload_channel $file]
        try {
            set target [open $filename wb]
            try {
                fcopy $source $target
            } finally {
                close $target
            }
        } finally {
            close $source
        }
        return $filename
    }

    proc upload {subcommand args} {
        switch -exact -- $subcommand {
            names {
                if {[llength $args] != 0} {
                    error {wrong # args: should be "::rivet::upload names"}
                }
                return [upload_names]
            }
            channel -
            data -
            exists -
            size -
            type -
            filename -
            tempname {
                if {[llength $args] != 1} {
                    error "wrong # args: should be \"::rivet::upload $subcommand uploadname\""
                }
                set name [lindex $args 0]
                if {$subcommand eq "exists"} {
                    return [expr {[[::tclwire::app::request] uploaded_file $name] ne {}}]
                }
                set file [upload_file $name]
            }
            save {
                if {[llength $args] != 2} {
                    error {wrong # args: should be "::rivet::upload save uploadname filename"}
                }
                set file [upload_file [lindex $args 0]]
            }
            default {
                error "bad upload subcommand \"$subcommand\": must be channel, save, data, exists, size, type, filename, tempname, or names"
            }
        }

        switch -exact -- $subcommand {
            channel {
                return [upload_channel $file]
            }
            save {
                return [upload_save $file [lindex $args 1]]
            }
            data {
                return [upload_file_data $file]
            }
            size {
                return [upload_file_size $file]
            }
            type {
                if {[dict exists $file content_type]} {
                    return [dict get $file content_type]
                }
                return {}
            }
            filename {
                return [dict get $file filename]
            }
            tempname {
                return [upload_tempname $file]
            }
        }
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
        set application [::tclwire::app::current]
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
        ::tclwire::io out [::fileutil::cat -encoding [$application encoding] $path]
        ::tclwire::io flush
        return
    }

    proc write_binary {binary_data} {
        ::tclwire::io flush
        ::tclwire::io out $binary_data binary
        ::tclwire::io flush
        return
    }

    proc with_binary_output {script} {
        ::tclwire::io flush
        set previous_mode [::tclwire::envs::stdchans::set_stdout_body_mode binary]
        try {
            uplevel 1 $script
        } finally {
            ::tclwire::envs::stdchans::set_stdout_body_mode $previous_mode
            ::tclwire::io flush
        }
    }

    proc response_reason {status} {
        tailcall ::tclwire::http::codes::reason $status
    }

    proc headers {operation args} {
        switch -exact -- $operation {
            get -
            set -
            add {
                tailcall ::tclwire::http::io header $operation {*}$args
            }
            type {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::rivet::headers type content-type"}
                }
                tailcall ::tclwire::http::io header set Content-Type [lindex $args 0]
            }
            redirect {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::rivet::headers redirect uri"}
                }
                set uri [lindex $args 0]
                ::tclwire::io response 302 [response_reason 302] \
                    [list "Location: $uri"] text
                return $uri
            }
            numeric {
                if {[llength $args] != 1} {
                    error {wrong # args: should be "::rivet::headers numeric response-code"}
                }
                set status [lindex $args 0]
                if {![string is integer -strict $status] ||
                        $status < 100 || $status > 999} {
                    error "invalid HTTP response status: $status"
                }
                ::tclwire::io response $status [response_reason $status] {} text
                return $status
            }
            sent {
                if {[llength $args] != 0} {
                    error {wrong # args: should be "::rivet::headers sent"}
                }
                return [expr {![::tclwire::io::accepting_output]}]
            }
            default {
                error "bad headers operation \"$operation\": must be get, set, redirect, add, type, numeric, or sent"
            }
        }
    }

    proc no_body {} {
        tailcall ::tclwire::http::no_body
    }

    proc redirect {location {permanent 0}} {
        if {[string is boolean -strict $permanent]} {
            set status [expr {$permanent ? 301 : 302}]
        } elseif {[string is integer -strict $permanent] &&
                $permanent >= 300 && $permanent <= 399} {
            set status $permanent
        } else {
            error "invalid HTTP redirect status: $permanent"
        }

        ::tclwire::io discard_buffer
        if {$status == 302} {
            headers redirect $location
        } else {
            headers numeric $status
            headers set Location $location
        }
        abort_page [dict create error_code redirect location $location]
    }

    proc makeurl {args} {
        if {[llength $args] == 0} {
            return [[::tclwire::app::request] absolute_url]
        }
        if {[llength $args] % 2 != 1} {
            error {wrong # args: should be "::rivet::makeurl ?path? ?name value ...?"}
        }

        set path [lindex $args 0]
        set query_pairs [lrange $args 1 end]
        if {[regexp -nocase {^[a-z][a-z0-9+.-]*://} $path]} {
            set url $path
        } else {
            set url [[::tclwire::app::request] absolute_url $path]
        }

        if {[llength $query_pairs] > 0} {
            if {[regexp {[?&]$} $url]} {
                append url {}
            } elseif {[string first ? $url] < 0} {
                append url ?
            } else {
                append url &
            }
            append url [::tclwire::http::query encode $query_pairs]
        }

        return $url
    }

    proc abort_page {{code {}}} {
        variable aborting
        variable abort_code
        variable abort_exiting

        if {$code eq "-aborting"} {
            return $aborting
        }

        set aborting 1
        set abort_code $code
        set abort_exiting 0
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
        tailcall ::tclwire::envs::rivet::parser::parse_template $template
    }

    proc read_template_file {path {encoding {}}} {
        tailcall ::tclwire::envs::rivet::parser::read_template_file \
            $path $encoding
    }

    proc file_script {application path} {
        if {[catch {set candidate [$application local_path $path]}]} {
            return {}
        }
        return [local_file_script $candidate $application]
    }

    proc local_file_script {candidate {application {}}} {
        set extension [string tolower [file extension $candidate]]
        if {$candidate eq {} || $extension ni {".rvt" ".tcl"}} {
            return {}
        }
        if {$extension eq ".rvt"} {
            if {$application ne {}} {
                return [[$application template_cache] get $candidate]
            }
            return [::tclwire::envs::rivet::parser::parse_template_file $candidate]
        }
        return [read_template_file $candidate]
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

        set cached 0
        if {$string_mode} {
            set template $source_value
        } else {
            set path [parse_file_path $source_value $virtual]
            if {$path eq {} || ![file isfile $path] || ![file readable $path]} {
                error "could not read Rivet template file"
            }
            if {[string tolower [file extension $path]] eq ".rvt" &&
               ![catch {set application [::tclwire::app::current]}]} {
                if {$encoding eq {}} {
                    set script [[$application template_cache] get $path]
                } else {
                    set script [[$application template_cache] get $path \
                        [string tolower $encoding]]
                }
                set cached 1
            } else {
                set template [read_template_file $path $encoding]
            }
        }

        if {!$cached} {
            set script [parse_template $template]
        }
        uplevel 1 $script
    }

    proc parse_wrong_args {} {
        error {wrong # args: should be "::rivet::parse ?-encoding encoding? ?-virtual? filename | -string template_string"}
    }

    proc lempty {a_list} {
        if {[catch {llength $a_list} len]} {
            return 0
        }
        return [expr {$len == 0}]
    }

    proc import_keyvalue_pairs {arrayName argsList} {
        upvar 1 $arrayName data

        if {[string index $argsList 0] ne "-"} {
            set data(args) $argsList
            return
        }

        set index 0
        set looking 0
        set data(args) ""

        foreach arg $argsList {
            if {$looking} {
                set data($varName) $arg
                set looking 0
            } elseif {[string index $arg 0] eq "-"} {
                if {$arg eq "--"} {
                    set data(args) [lrange $argsList [expr {$index + 1}] end]
                    break
                }

                if {$arg eq "-args"} {
                    return -code error "-args is a reserved value."
                }
                set varName [string range $arg 1 end]
                set looking 1
            } else {
                set data(args) [lrange $argsList $index end]
                break
            }
            incr index
        }
        return
    }

    proc lmatch {args} {
        set modes(-exact)  0
        set modes(-glob)   1
        set modes(-regexp) 2

        if {[llength $args] == 3} {
            lassign $args mode list pattern
        } elseif {[llength $args] == 2} {
            set mode -glob
            lassign $args list pattern
        } else {
            return -code error \
                {wrong # args: should be "lmatch ?mode? list pattern"}
        }

        if {![info exists modes($mode)]} {
            return -code error \
                "bad search mode \"$mode\": must be -exact, -glob, or -regexp"
        }
        set mode $modes($mode)

        set result {}
        foreach elem $list {
            if {$mode == 0} {
                if {[string compare $elem $pattern] == 0} {
                    lappend result $elem
                }
            }
            if {$mode == 1} {
                if {[string match $pattern $elem]} {
                    lappend result $elem
                }
            }
            if {$mode == 2} {
                if {[regexp $pattern $elem]} {
                    lappend result $elem
                }
            }
        }
        return $result
    }

    proc lremove {args} {
        if {[llength $args] < 2} {
            error {wrong # args: should be "::rivet::lremove ?mode? ?-all? list ?pattern?.. ?pattern?.."}
        }

        set list_index 0
        set all 0
        set mode glob
        foreach argument $args {
            if {![string match -* $argument]} {
                break
            }

            switch -exact -- $argument {
                -exact -
                -glob -
                -regexp {
                    set mode [string range $argument 1 end]
                    incr list_index
                }
                -all {
                    set all 1
                    incr list_index
                }
                -- {
                    incr list_index
                    break
                }
                default {
                    error "bad switch \"$argument\": must be -exact, -glob, -regexp or -all"
                }
            }
        }

        if {$list_index >= [llength $args] - 1} {
            error {wrong # args: should be "::rivet::lremove ?mod? ?-all? list pattern"}
        }

        set source_list [lindex $args $list_index]
        llength $source_list
        set patterns [lrange $args $list_index+1 end]
        set result {}
        set removed 0

        foreach value $source_list {
            if {$removed && !$all} {
                lappend result $value
                continue
            }

            set matched 0
            foreach pattern $patterns {
                if {$mode ne "exact" && [string first \x00 $pattern] >= 0} {
                    error {Binary data is not supported in this mode.}
                }

                switch -exact -- $mode {
                    exact {
                        set matched [expr {$value eq $pattern}]
                    }
                    glob {
                        if {[string first \x00 $value] >= 0} {
                            error {Binary data is not supported in this mode.}
                        }
                        set matched [string match $pattern $value]
                    }
                    regexp {
                        if {[string first \x00 $value] >= 0} {
                            error {Binary data is not supported in this mode.}
                        }
                        set matched [regexp -- $pattern $value]
                    }
                }

                if {$matched} {
                    if {!$all} {
                        set removed 1
                    }
                    break
                }
            }

            if {!$matched} {
                lappend result $value
            }
        }

        return $result
    }

    proc lassign_array {args} {
        if {[llength $args] < 3} {
            error {wrong # args: should be "::rivet::lassign_array list arrayName elementName ?elementName..?"}
        }

        set list [lindex $args 0]
        set arrayName [lindex $args 1]
        set elementNames [lrange $args 2 end]
        llength $list
        set list_index 0
        set list_length [llength $list]
        foreach elementName $elementNames {
            if {$list_index < $list_length} {
                set value [lindex $list $list_index]
            } else {
                set value {}
            }
            uplevel 1 [list set ${arrayName}($elementName) $value]
            incr list_index
        }

        if {$list_index < $list_length} {
            return [lrange $list $list_index end]
        }
        return
    }

    proc http_accept {args} {
        set lqValues {}
        set lItems {}

        while {[llength $args] > 1} {
            set args [lassign $args argCur]
            switch -exact -- $argCur {
                -zeroweight { set fZeroWeight 1 }
                -list { set oList 1 }
                -default { set fDefault 1 }
                -- {}
                default { return -code error "Unknown argument '$argCur'" }
            }
        }

        foreach itemCur [split [lindex $args 0] ,] {
            set qCur 1
            if {[regexp {^(.*); *q=([^;]*)$} $itemCur match itemCur qString]} {
                if {1 == [scan $qString %f qVal] && $qVal >= 0 && $qVal <= 1} {
                    set qCur $qVal
                }
            }
            set itemCur [string trim $itemCur]
            if {$itemCur in {"*" "*/*" "*-*"}} {
                unset -nocomplain fDefault
            }
            if {[info exists fZeroWeight] || $qCur > 0} {
                lappend lqValues $qCur
                lappend lItems $itemCur
            }
        }

        set dOut {}
        if {[info exists oList]} {
            set sorted_keys {}
            foreach indexCur [lsort -real -decreasing -indices $lqValues] {
                lappend sorted_keys [lindex $lItems $indexCur]
            }
            return $sorted_keys
        } else {
            foreach indexCur [lsort -real -decreasing -indices $lqValues] {
                set qCur [lindex $lqValues $indexCur]
                if {$qCur == 0 && [info exists fDefault]} {
                    dict set dOut * 0.01
                    unset fDefault
                }
                set item_key [lindex $lItems $indexCur]
                dict set dOut $item_key $qCur
            }

            if {[info exists fDefault]} {
                dict set dOut * 0.01
            }
            return $dOut
        }
    }

    proc read_file {file args} {
        tailcall ::fileutil::cat {*}$args $file
    }

    proc string_before_nul {string} {
        set nul [string first \x00 $string]
        if {$nul >= 0} {
            return [string range $string 0 $nul-1]
        }
        return $string
    }

    proc unescape_string {string} {
        set string [string_before_nul $string]
        set result {}
        set length [string length $string]
        for {set index 0} {$index < $length} {incr index} {
            set char [string index $string $index]
            if {$char eq "+"} {
                append result " "
            } elseif {$char eq "%"} {
                incr index
                set first [string index $string $index]
                incr index
                set second [string index $string $index]
                if {![regexp {^[0-9A-Fa-f]{2}$} $first$second]} {
                    error "::rivet::unescape_string: bad char in hex sequence %$first$second"
                }
                append result [binary format c [scan $first$second %x]]
            } else {
                append result $char
            }
        }
        return $result
    }

    proc escape_string {string} {
        set string [string_before_nul $string]
        set result {}
        binary scan [encoding convertto utf-8 $string] cu* bytes
        foreach byte $bytes {
            set char [format %c $byte]
            if {($byte >= 0x30 && $byte <= 0x39) ||
                    ($byte >= 0x41 && $byte <= 0x5a) ||
                    ($byte >= 0x61 && $byte <= 0x7a)} {
                append result $char
            } elseif {$byte == 0x20} {
                append result +
            } else {
                append result %[format %02x $byte]
            }
        }
        return $result
    }

    proc escape_sgml_chars {string} {
        set string [string_before_nul $string]
        return [string map [list \
            &  &amp\; \
            <  &lt\; \
            >  &gt\; \
            '  &#39\; \
            \" &quot\;] $string]
    }

    proc escape_shell_command {string} {
        set string [string_before_nul $string]
        set result {}
        foreach char [split $string {}] {
            if {$char in {& {;} ` ' | * ? - ~ < > ^ ( ) {[} {]} \{ \} {$} \\}} {
                append result \\
            }
            append result $char
        }
        return $result
    }

    proc parray {arrayName {pattern *} {outputcmd "puts stdout"}} {
        upvar 1 $arrayName array
        if {![array exists array]} {
            return -code error "\"$arrayName\" isn't an array"
        }
        set maxl 0
        foreach name [lsort [array names array $pattern]] {
            if {[string length $name] > $maxl} {
                set maxl [string length $name]
            }
        }
        set html_text [list "<b>$arrayName</b>"]
        set maxl [expr {$maxl + [string length $arrayName] + 2}]
        foreach name [lsort [array names array $pattern]] {
            set nameString [format "%s(%s)" $arrayName [escape_sgml_chars $name]]
            lappend html_text [format "%-*s = %s" \
                $maxl $nameString [escape_sgml_chars $array($name)]]
        }
        uplevel 1 [list {*}$outputcmd \
            [join [list <pre> [join $html_text "\n"] </pre>] "\n"]]
        return
    }

    proc parray_table {arrayName {pattern "*"} {htmlAttributes ""}} {
        upvar 1 $arrayName array
        if {![array exists array]} {
            return -code error "\"$arrayName\" isn't an array"
        }
        puts -nonewline stdout "<table"
        foreach {attr attrval} $htmlAttributes {
            puts -nonewline " $attr=\"$attrval\""
        }

        puts "><thead><tr><th colspan=\"2\">$arrayName</th></tr></thead>"
        puts stdout "<tbody>"
        foreach name [lsort [array names array $pattern]] {
            puts stdout [format "<tr><td>%s</td><td>%s</td></tr>" \
                [escape_sgml_chars $name] [escape_sgml_chars $array($name)]]
        }
        puts stdout "</tbody></table>"
        return
    }

    proc wrap {string maxlen {html ""}} {
        set splitstring {}
        foreach line [split $string "\n"] {
            lappend splitstring [wrapline $line $maxlen $html]
        }
        if {$html == "-html"} {
            return [join $splitstring "<br>"]
        } else {
            return [join $splitstring "\n"]
        }
    }

    proc wrapline {line maxlen {html ""}} {
        set string [split $line " "]
        set newline [list [lindex $string 0]]
        foreach word [lrange $string 1 end] {
            if {[string length $newline]+[string length $word] > $maxlen} {
                lappend lines [join $newline " "]
                set newline {}
            }
            lappend newline $word
        }
        lappend lines [join $newline " "]
        if {$html == "-html"} {
            return [join $lines <br>]
        } else {
            return [join $lines "\n"]
        }
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
            set ::Rivet::global_namespace_path [namespace eval :: {namespace path}]
            if {"::rivet" ni $::Rivet::global_namespace_path} {
                namespace eval :: \
                    [list namespace path [linsert $::Rivet::global_namespace_path end ::rivet]]
            }

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

        if {[info commands ::Rivet::exit_cleanup] eq {}} {
            proc ::Rivet::exit_cleanup {{code 0}} {
                return
            }
        }

        proc ::Rivet::cleanup_request {} {
            if {[info exists ::Rivet::global_namespace_path]} {
                namespace eval :: \
                    [list namespace path $::Rivet::global_namespace_path]
                unset ::Rivet::global_namespace_path
            }
            unset -nocomplain ::cookies ::response
            return
        }

        proc ::Rivet::finish_request {script errorCode errorOpts {scriptName ""}} {
            set ::Rivet::errorCode $errorCode
            set ::Rivet::errorOpts $errorOpts

            if {[::tclwire::envs::rivet::configured_script $scriptName]} {
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
            if {![::tclwire::envs::rivet::configured_script $error_script]} {
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
        ::tclwire::envs::rivet::parser::install_commands

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

            set level [::tclwire::envs::rivet::apache_log_level $level]
            set saved_error_info {}
            set had_error_info [info exists ::errorInfo]
            if {$had_error_info} {
                set saved_error_info $::errorInfo
            }
            set saved_error_code {}
            set had_error_code [info exists ::errorCode]
            if {$had_error_code} {
                set saved_error_code $::errorCode
            }
            catch {
                set logger [::tclwire::logger::getlogger]
                $logger log_error rivet \
                    [::tclwire::logger::log_value $message] $level
            }
            if {$had_error_info} {
                set ::errorInfo $saved_error_info
            } else {
                unset -nocomplain ::errorInfo
            }
            if {$had_error_code} {
                set ::errorCode $saved_error_code
            } else {
                unset -nocomplain ::errorCode
            }
            return
        }

        proc ::rivet::apache_table {args} {
            return {}
        }

        proc ::rivet::debug {args} {
            return {}
        }

        proc ::rivet::catch {script args} {
            set catch_result [uplevel 1 [list ::catch $script {*}$args]]

            if {$catch_result && [::rivet::abort_code -exiting]} {
                return -code error -errorcode {RIVET THREAD_EXIT} \
                    [::rivet::abort_code]
            }
            if {$catch_result && [::rivet::abort_page -aborting]} {
                return -code error -errorcode {RIVET ABORTPAGE} \
                    [::rivet::abort_code]
            }
            return $catch_result
        }

        proc ::rivet::try {script args} {
            uplevel 1 [list ::try $script \
                trap {RIVET THREAD_EXIT} {} {
                    return -code error -errorcode {RIVET THREAD_EXIT}
                } \
                trap {RIVET ABORTPAGE} {} {
                    return -code error -errorcode {RIVET ABORTPAGE}
                } \
                {*}$args]
        }

        proc ::rivet::inspect {args} {
            switch -exact -- [llength $args] {
                1 {
                    set option [lindex $args 0]
                    if {$option eq "-all"} {
                        return [::tclwire::envs::rivet::inspect_all]
                    }
                    if {$option eq "script"} {
                        return [::tclwire::envs::rivet::inspect_script]
                    }
                    if {$option eq "server"} {
                        return [::tclwire::envs::rivet::inspect_server]
                    }
                    return [::tclwire::envs::rivet::inspect_value $option]
                }
                0 {
                    return [dict create \
                        user   {} \
                        server [concat {*}[lmap {k v} [::tclwire::envs::rivet::inspect_all] {
                            if {$v ne ""} { list $k $v } else { continue }
                        }]] \
                        dir    {}]
                }
                2 {
                    error "::rivet::inspect form is not implemented yet"
                }
                default {
                    error {wrong # args: should be "::rivet::inspect ?option ?value??"}
                }
            }
        }

        proc ::rivet::headers {operation args} {
            tailcall ::tclwire::envs::rivet::headers $operation {*}$args
        }

        proc ::rivet::no_body {} {
            tailcall ::tclwire::envs::rivet::no_body
        }

        proc ::rivet::redirect {args} {
            if {[llength $args] < 1 || [llength $args] > 2} {
                error {wrong # args: should be "::rivet::redirect URL ?permanent?"}
            }
            tailcall ::tclwire::envs::rivet::redirect {*}$args
        }

        proc ::rivet::thread_id {} {
            tailcall ::thread::id
        }

        proc ::rivet::env {args} {
            if {[llength $args] != 1} {
                error {wrong # args: should be "::rivet::env environment_variable_name"}
            }
            tailcall ::tclwire::envs::rivet::env [lindex $args 0]
        }

        proc ::rivet::exit {{code 0}} {
            tailcall ::tclwire::envs::rivet::exit_request $code
        }

        proc ::rivet::include {args} {
            tailcall ::tclwire::envs::rivet::include {*}$args
        }

        proc ::rivet::write_binary {binary_data} {
            tailcall ::tclwire::envs::rivet::write_binary $binary_data
        }

        proc ::rivet::with_binary_output {script} {
            uplevel 1 [list ::tclwire::envs::rivet::with_binary_output $script]
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

        proc ::rivet::upload {subcommand args} {
            tailcall ::tclwire::envs::rivet::upload $subcommand {*}$args
        }

        proc ::rivet::lempty {list} {
            tailcall ::tclwire::envs::rivet::lempty $list
        }

        proc ::rivet::import_keyvalue_pairs {arrayName argsList} {
            uplevel 1 [list ::tclwire::envs::rivet::import_keyvalue_pairs \
                $arrayName $argsList]
        }

        proc ::rivet::lmatch {args} {
            tailcall ::tclwire::envs::rivet::lmatch {*}$args
        }

        proc ::rivet::lremove {args} {
            tailcall ::tclwire::envs::rivet::lremove {*}$args
        }

        proc ::rivet::lassign_array {args} {
            tailcall ::tclwire::envs::rivet::lassign_array {*}$args
        }

        proc ::rivet::http_accept {args} {
            tailcall ::tclwire::envs::rivet::http_accept {*}$args
        }

        proc ::rivet::read_file {file args} {
            tailcall ::tclwire::envs::rivet::read_file $file {*}$args
        }

        proc ::rivet::unescape_string {string} {
            tailcall ::tclwire::envs::rivet::unescape_string $string
        }

        proc ::rivet::escape_string {string} {
            tailcall ::tclwire::envs::rivet::escape_string $string
        }

        proc ::rivet::escape_sgml_chars {string} {
            tailcall ::tclwire::envs::rivet::escape_sgml_chars $string
        }

        proc ::rivet::escape_shell_command {string} {
            tailcall ::tclwire::envs::rivet::escape_shell_command $string
        }

        proc ::rivet::parray {arrayName {pattern *} {outputcmd "puts stdout"}} {
            tailcall ::tclwire::envs::rivet::parray $arrayName $pattern $outputcmd
        }

        proc ::rivet::parray_table {arrayName {pattern "*"} {htmlAttributes ""}} {
            tailcall ::tclwire::envs::rivet::parray_table \
                $arrayName $pattern $htmlAttributes
        }

        proc ::rivet::wrap {string maxlen {html ""}} {
            tailcall ::tclwire::envs::rivet::wrap $string $maxlen $html
        }

        proc ::rivet::wrapline {line maxlen {html ""}} {
            tailcall ::tclwire::envs::rivet::wrapline $line $maxlen $html
        }

        proc ::rivet::html {string args} {
            tailcall ::tclwire::envs::rivet::html $string {*}$args
        }

        proc ::rivet::xml {textstring args} {
            tailcall ::tclwire::envs::rivet::xml $textstring {*}$args
        }

        proc ::rivet::makeurl {args} {
            tailcall ::tclwire::envs::rivet::makeurl {*}$args
        }

        proc ::rivet::url_script {} {
            set application [::tclwire::app::current]
            set request     [::tclwire::app::request]

            set local_path [$request local_path]
            if {$local_path ne {}} {
                return [::tclwire::envs::rivet::local_file_script \
                    $local_path $application]
            }
            return [::tclwire::envs::rivet::file_script $application \
                [$request path]]
        }

        proc ::rivet::abort_page {{code {}}} {
            tailcall ::tclwire::envs::rivet::abort_page $code
        }

        proc ::rivet::abort_code {args} {
            tailcall ::tclwire::envs::rivet::abort_code {*}$args
        }

        proc ::rivet::clock_to_rfc850_gmt {seconds} {
            tailcall ::tclwire::envs::rivet::clock_to_rfc850_gmt $seconds
        }

        proc ::rivet::cookie {cmd name args} {
            tailcall ::tclwire::envs::rivet::cookie $cmd $name {*}$args
        }

        namespace eval ::rivet {
            namespace export abort_code abort_page apache_log_error apache_table \
                             catch debug env headers include \
                             inspect load_cookies load_env load_headers load_response \
                             parse html import_keyvalue_pairs lempty lmatch \
                             lremove lassign_array http_accept read_file \
                             unescape_string escape_string escape_sgml_chars \
                             escape_shell_command parray \
                             parray_table wrap wrapline xml \
                             clock_to_rfc850_gmt cookie \
                             inspect makeurl no_body redirect thread_id try url_script \
                             upload var var_qs var_post exit
        }
        return
    }
}
