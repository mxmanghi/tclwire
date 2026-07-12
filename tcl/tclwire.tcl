#!/usr/bin/env tclsh
#
# tclwire.tcl --
#
# TclWire runtime bootstrap and configured protocol Transport Reactors.

set ::tclwire_runtime_root [file dirname [file dirname [file normalize [info script]]]]
if {$::tclwire_runtime_root ni $::auto_path} {
    lappend ::auto_path $::tclwire_runtime_root
}

package require tclwire::support 0.1
package require tclwire::accounting 1.2
package require tclwire::tpba::control 0.1
package require tclwire::logger::control 0.1
package require tclwire::application_dispatcher 0.1
package require tclwire::transport_reactor 0.1
package require tclwire::console::reactor 0.1
package require tomlfile 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::runtime {
    variable active 0
    variable active_config {}
    variable shutdown_requested 0
    variable transport_reactors [dict create]
    variable console_reactor {}
    variable application_dispatcher {}
    variable protocol_descriptors [dict create \
        http [dict create   default_port 8990 \
                            secure 0 \
                            agent_class ::tclwire::HttpConnectionAgent \
                            agent_package tclwire::http::connection_agent \
                            setup_proc ::tclwire::runtime::http_service_agent_args] \
        https [dict create  default_port 9443 \
                            secure 1 \
                            agent_class ::tclwire::HttpConnectionAgent \
                            agent_package tclwire::http::connection_agent \
                            setup_proc ::tclwire::runtime::http_service_agent_args] \
        ftp [dict create    default_port 8991 \
                            secure 0 \
                            agent_class ::tclwire::FtpConnectionAgent \
                            agent_package tclwire::ftp::connection_agent \
                            setup_proc ::tclwire::runtime::ftp_service_agent_args] \
        ftps [dict create   default_port 990 \
                            secure 1 \
                            agent_class ::tclwire::FtpConnectionAgent \
                            agent_package tclwire::ftp::connection_agent \
                            setup_proc ::tclwire::runtime::ftp_service_agent_args] \
        proxy [dict create  default_port 8992 \
                            secure 0 \
                            agent_class ::tclwire::ProxyConnectionAgent \
                            agent_package tclwire::proxy::connection_agent \
                            setup_proc ::tclwire::runtime::proxy_service_agent_args]]

    proc implemented_protocols {} {
        variable protocol_descriptors
        return [dict keys $protocol_descriptors]
    }

    proc protocol_descriptor {protocol} {
        variable protocol_descriptors
        if {![dict exists $protocol_descriptors $protocol]} {
            error "configured protocol is not implemented: $protocol"
        }
        return [dict get $protocol_descriptors $protocol]
    }

    proc protocol_default_port {protocol} {
        return [dict get [protocol_descriptor $protocol] default_port]
    }

    proc protocol_defaults {} {
        set defaults [dict create]
        foreach protocol [implemented_protocols] {
            dict set defaults $protocol [protocol_default_port $protocol]
        }
        return $defaults
    }

    proc default_protocols {} {
        return {http}
    }

    proc usage {{channel stdout}} {
        puts $channel "Usage: tclsh tcl/tclwire.tcl ?options?"
        puts $channel ""
        puts $channel "Options:"
        puts $channel "  --help"
        puts $channel "      Show this help message."
        puts $channel "  --config <path>     Default: . (no configuration file)"
        puts $channel "  --host <address>"
        puts $channel "      Bind address prepared for future services. Default: 127.0.0.1"
        puts $channel "  --startservers <list>"
        puts $channel "      Comma-separated protocols to prepare, or 'all'."
        puts $channel "  --httpport <port>   Default: 8990"
        puts $channel "  --httpsport <port>  Default: 9443"
        puts $channel "  --ftpport <port>    Default: 8991"
        puts $channel "  --ftpsport <port>   Default: 990"
        puts $channel "  --proxyport <port>  Default: 8992"
        puts $channel "  --service <protocol:port>"
        puts $channel "      Add a service. TLS overrides may follow as"
        puts $channel "      ';certfile=<path>;keyfile=<path>;upload_area=<path>'."
        puts $channel "  --docroot <path>"
        puts $channel "  --upload-area <path>"
        puts $channel "      Store HTTP multipart file parts in this directory."
        puts $channel "  --max-request-bytes <count>"
        puts $channel "      Maximum buffered HTTP request size. Default: 16777216"
        puts $channel "  --max-header-bytes <count>"
        puts $channel "      Maximum buffered HTTP request header size. Default: 65536"
        puts $channel "  --request-memory-threshold <count>"
        puts $channel "      Spool larger HTTP request bodies to disk. Default: 1048576"
        puts $channel "  --dump-multipart-requests"
        puts $channel "      Dump complete multipart HTTP requests to stderr. Default: off"
        puts $channel "  --ftproot <path>"
        puts $channel "  --certfile <path>"
        puts $channel "  --keyfile <path>"
        puts $channel "  --noftp-user-check"
        puts $channel "  --logfile <path>    Access log. Default: /tmp/tclwire.log"
        puts $channel "  --logerr <path>     Error log. Default: /tmp/tclwire-err.log"
        puts $channel "  --log-level <level> Global logging threshold. Default: info"
        puts $channel "  --conn-max-wait <ms>"
        puts $channel "      Maximum accepted-socket wait for a connection worker. Default: 1000"
        puts $channel "  --conn-max-workers <count>"
        puts $channel "      Maximum connection-agent workers per service. Default: 100"
        puts $channel "  --conn-max-per-thread <count>"
        puts $channel "      Maximum connections per connection-agent worker. Default: 5"
        puts $channel "  --unix-socket <path> Console socket. Default: /tmp/tclwire.sock"
        puts $channel "  --quiet"
        puts $channel "  --debug"
        return
    }

    proc require_value {argv index option} {
        if {$index >= [llength $argv]} {
            error "missing value after $option"
        }
        return [lindex $argv $index]
    }

    proc parse_port_value {option value} {
        if {![string is integer -strict $value] || $value < 1 || $value > 65535} {
            error "invalid value for $option: $value"
        }
        return $value
    }

    proc parse_integer_min {option value minimum} {
        if {![string is integer -strict $value] || $value < $minimum} {
            error "invalid value for $option: $value"
        }
        return $value
    }

    proc parse_service_spec {spec} {
        set fields [split $spec \;]
        set endpoint [lindex $fields 0]
        if {![regexp {^([a-z0-9_+-]+):([0-9]+)$} \
                $endpoint -> protocol port]} {
            error "invalid service spec: $spec"
        }
        if {$protocol ni [implemented_protocols]} {
            error "unsupported protocol in service spec: $protocol"
        }
        set service [dict create protocol $protocol \
                                 port     [parse_port_value --service $port]]

        foreach field [lrange $fields 1 end] {
            if {![regexp {^(certfile|keyfile)=(.+)$|^(upload_area)=(.*)$} \
                    $field -> tls_name tls_value upload_name upload_value]} {
                error "invalid service option: $field"
            }
            if {$upload_name ne {}} {
                set name $upload_name
                set value $upload_value
            } else {
                set name $tls_name
                set value $tls_value
            }
            dict set service $name [expr {$value eq {} ? {} : [file normalize $value]}]
        }
        return $service
    }

    proc secure_protocol {protocol} {
        return [dict get [protocol_descriptor $protocol] secure]
    }

    proc normalize_service {service default_certfile default_keyfile} {
        set protocol [dict get $service protocol]
        set port [dict get $service port]
        dict set service id "$protocol:$port"
        dict set service secure [secure_protocol $protocol]
        if {[dict get $service secure]} {
            if {![dict exists $service certfile]} {
                dict set service certfile $default_certfile
            }
            if {![dict exists $service keyfile]} {
                dict set service keyfile $default_keyfile
            }
        }
        return $service
    }

    proc parse_protocol_list {value} {
        set value [string trim $value]
        if {$value eq {}} {
            error "invalid value for --startservers: empty list"
        }
        if {$value eq "all"} {
            return [implemented_protocols]
        }

        set protocols {}
        foreach protocol [split $value ,] {
            set protocol [string trim $protocol]
            if {$protocol eq {}} {
                error "invalid value for --startservers: empty protocol"
            }
            if {$protocol ni [implemented_protocols]} {
                error "unsupported server in --startservers: $protocol"
            }
            if {$protocol ni $protocols} {
                lappend protocols $protocol
            }
        }
        return $protocols
    }

    proc parse_boolean {name value} {
        switch -exact -- [string tolower [string trim $value]] {
            true - 1 - yes - on {
                return 1
            }
            false - 0 - no - off {
                return 0
            }
            default {
                error "invalid boolean for $name: $value"
            }
        }
    }

    proc normalize_log_level {name value} {
        return [::tclwire::logger normalize_level $value]
    }

    proc resolve_config_path {config_dir value} {
        if {$value eq {}} {
            return {}
        }
        if {[file pathtype $value] eq "absolute"} {
            return [file normalize $value]
        }
        return [file normalize [file join $config_dir $value]]
    }

    proc default_config {} {
        set host 127.0.0.1
        set quiet 0
        set debug 0
        set debug_connection 0
        set help 0
        set docroot [::tclwire::support default_doc_root]
        set upload_area [file normalize /tmp]
        set max_request_bytes 16777216
        set max_header_bytes 65536
        set request_memory_threshold 1048576
        set ftproot [::tclwire::support default_ftp_root]
        set certfile {}
        set keyfile {}
        set logfile [file normalize /tmp/tclwire.log]
        set logerr [file normalize /tmp/tclwire-err.log]
        set log_level info
        set conn_max_wait 1000
        set conn_max_workers 100
        set conn_max_per_thread 5
        set unix_socket [file normalize /tmp/tclwire.sock]
        set ftp_user_check 1
        set ftproot_follows_docroot [expr {$ftproot eq $docroot}]
        set startservers [default_protocols]
        set services [list [dict create \
            protocol http \
            port [protocol_default_port http]]]
        set custom_services 0
        set ports [protocol_defaults]
        set default_application default
        set default_encoding utf-8
        set applications [dict create \
            default [dict create class      ::tclwire::CApplication \
                                 package    tclwire::application    \
                                 hosts      {localhost 127.0.0.1}   \
                                 docroot    $docroot                \
                                 encoding   $default_encoding       \
                                 pool_policy [dict create minimum_workers 0 maximum_workers 20]]]

        return [dict create help         $help \
                            config_file  . \
                            host         $host \
                            quiet        $quiet \
                            debug        $debug \
                            debug_connection $debug_connection \
                            encoding     $default_encoding \
                            docroot      $docroot \
                            upload_area  $upload_area \
                            max_request_bytes $max_request_bytes \
                            max_header_bytes $max_header_bytes \
                            request_memory_threshold $request_memory_threshold \
                            ftproot      $ftproot \
                            certfile     $certfile \
                            keyfile      $keyfile \
                            ftp_user_check $ftp_user_check \
                            logfile      $logfile \
                            logerr       $logerr \
                            log_level    $log_level \
                            conn_max_wait $conn_max_wait \
                            conn_max_workers $conn_max_workers \
                            conn_max_per_thread $conn_max_per_thread \
                            unix_socket  $unix_socket \
                            startservers $startservers \
                            services     $services \
                            custom_services $custom_services \
                            ports        $ports \
                            ftproot_follows_docroot $ftproot_follows_docroot \
                            default_application $default_application \
                            applications $applications]
    }

    proc find_config_option {argv} {
        set config_file .
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set option [lindex $argv $i]
            if {$option eq "--config"} {
                set config_file [require_value $argv [incr i] $option]
            }
        }
        return $config_file
    }

    proc load_config_file {path} {
        if {$path eq "."} {
            return [dict create]
        }
        set path [file normalize $path]
        if {![file isfile $path]} {
            error "configuration file does not exist: $path"
        }
        return [::toml::tomlParse $path]
    }

    proc apply_file_config {config path toml_config} {
        if {$path eq "."} {
            return $config
        }
        set config_file [file normalize $path]
        set config_dir [file dirname $config_file]
        dict set config config_file $config_file

        if {[dict exists $toml_config tclwire]} {
            set global [dict get $toml_config tclwire]

            # These fields need no conversion. Filtering before merging keeps
            # unrelated TOML keys out while letting file values replace the
            # built-in defaults in one dictionary operation.
            set config [dict merge $config \
                [dict filter $global key host encoding default_application]]
            if {[dict exists $global log_level]} {
                dict set config log_level \
                    [normalize_log_level tclwire.log_level \
                        [dict get $global log_level]]
            }

            # dict filter selects the supported source fields; dict map
            # validates and replaces their values. The later merge applies
            # the transformed values without exposing unrelated TOML keys.
            set booleans [dict map {field value} \
                    [dict filter $global key \
                        quiet debug debug_connection ftp_user_check \
                        dump_multipart_requests] {
                parse_boolean "tclwire.$field" $value
            }]
            set paths [dict map {field value} \
                    [dict filter $global key \
                        docroot ftproot certfile keyfile logfile logerr libdir upload_area \
                        unix_socket] {
                resolve_config_path $config_dir $value
            }]
            set config [dict merge $config $booleans $paths]
            foreach {field minimum} {
                conn_max_wait 0
                conn_max_workers 1
                conn_max_per_thread 1
                max_request_bytes 1
                max_header_bytes 1
                request_memory_threshold 0
            } {
                if {[dict exists $global $field]} {
                    dict set config $field [parse_integer_min \
                        "tclwire.$field" [dict get $global $field] $minimum]
                }
            }

            if {[dict exists $global docroot] &&
                    ![dict exists $global ftproot]} {
                dict set config ftproot [dict get $config docroot]
            }
        }

        set startservers {}
        set services {}
        foreach protocol [implemented_protocols] {
            if {![dict exists $toml_config $protocol]} {
                continue
            }
            set protocol_config [dict get $toml_config $protocol]
            set port [protocol_default_port $protocol]
            if {[dict exists $protocol_config port]} {
                set port [parse_port_value "$protocol.port" \
                    [dict get $protocol_config port]]
            }
            dict set config ports $protocol $port

            set enabled 1
            if {[dict exists $protocol_config enabled]} {
                set enabled [parse_boolean "$protocol.enabled" \
                    [dict get $protocol_config enabled]]
            }
            if {!$enabled} {
                continue
            }

            set service [dict create protocol $protocol port $port]
            if {$protocol in {http https} &&
                    [dict exists $protocol_config upload_area]} {
                dict set service upload_area [resolve_config_path $config_dir \
                    [dict get $protocol_config upload_area]]
            }
            if {$protocol in {http https} &&
                    [dict exists $protocol_config max_request_bytes]} {
                dict set service max_request_bytes [parse_integer_min \
                    "$protocol.max_request_bytes" \
                    [dict get $protocol_config max_request_bytes] 1]
            }
            if {$protocol in {http https} &&
                    [dict exists $protocol_config max_header_bytes]} {
                dict set service max_header_bytes [parse_integer_min \
                    "$protocol.max_header_bytes" \
                    [dict get $protocol_config max_header_bytes] 1]
            }
            if {$protocol in {http https} &&
                    [dict exists $protocol_config request_memory_threshold]} {
                dict set service request_memory_threshold [parse_integer_min \
                    "$protocol.request_memory_threshold" \
                    [dict get $protocol_config request_memory_threshold] 0]
            }

            if {[dict exists $protocol_config log_level]} {
                dict set service log_level \
                    [normalize_log_level "$protocol.log_level" \
                        [dict get $protocol_config log_level]]
            }

            # The script form is useful here because inclusion depends on
            # both the key and its value. It still preserves original values;
            # dict map performs the subsequent path transformation.
            set tls_paths [dict filter $protocol_config script {field value} {
                expr {$field in {certfile keyfile} && $value ne {}}
            }]
            set tls_paths [dict map {field value} $tls_paths {
                resolve_config_path $config_dir $value
            }]
            set service [dict merge $service $tls_paths]

            lappend startservers $protocol
            lappend services $service

            if {$protocol in {ftp ftps}} {
                if {[dict exists $protocol_config root]} {
                    dict set config ftproot [resolve_config_path \
                        $config_dir [dict get $protocol_config root]]
                }
                if {[dict exists $protocol_config user_check]} {
                    dict set config ftp_user_check \
                        [parse_boolean "$protocol.user_check" \
                            [dict get $protocol_config user_check]]
                }
            }
        }
        dict set config startservers $startservers
        dict set config services $services
        dict set config custom_services 1

        set applications [dict create]
        foreach protocol {http https} {
            if {![dict exists $toml_config $protocol]} {
                continue
            }
            set protocol_config [dict get $toml_config $protocol]
            set protocol_libdir {}
            if {[dict exists $protocol_config libdir]} {
                set protocol_libdir [resolve_config_path \
                    $config_dir [dict get $protocol_config libdir]]
            }
            dict for {application_id descriptor} $protocol_config {
                if {$application_id in {enabled port certfile keyfile libdir log_level upload_area max_request_bytes max_header_bytes request_memory_threshold}} {
                    continue
                }
                if {[catch {dict size $descriptor}]} {
                    error "application '$protocol.$application_id' must be a table"
                }

                # Copy only descriptor values that already have the runtime's
                # representation. Paths and worker limits are normalized
                # separately below.
                set application [dict filter $descriptor key \
                    class package hosts encoding log_level reload_on_request \
                    retain_uploaded_files]
                if {[dict exists $application log_level]} {
                    dict set application log_level \
                        [normalize_log_level "$protocol.$application_id.log_level" \
                            [dict get $application log_level]]
                }
                foreach option {reload_on_request retain_uploaded_files} {
                    if {[dict exists $application $option]} {
                        dict set application $option [parse_boolean \
                            "$protocol.$application_id.$option" \
                            [dict get $application $option]]
                    }
                }
                if {![dict exists $application hosts]} {
                    dict set application hosts [list $application_id]
                }
                set application_paths [dict map {field value} \
                        [dict filter $descriptor key docroot libdir] {
                    resolve_config_path $config_dir $value
                }]
                set application [dict merge $application $application_paths]
                if {![dict exists $application libdir] &&
                        $protocol_libdir ne {}} {
                    dict set application libdir $protocol_libdir
                }
                if {[dict exists $descriptor file]} {
                    set application_file [dict get $descriptor file]
                    if {[file pathtype $application_file] eq "absolute"} {
                        set application_file [file normalize $application_file]
                    }
                    dict set application file $application_file
                }

                set pool_policy [dict filter $descriptor key \
                    minimum_workers maximum_workers]
                if {[dict size $pool_policy]} {
                    dict set application pool_policy $pool_policy
                }
                if {[dict exists $applications $application_id] &&
                        [dict get $applications $application_id] ne $application} {
                    error "application '$application_id' differs between HTTP and HTTPS"
                }
                dict set applications $application_id $application
            }
        }
        if {[dict size $applications]} {
            set merged_applications [dict create]
            set default_application [dict get $config default_application]
            if {[dict exists $config applications $default_application]} {
                dict set merged_applications $default_application \
                    [dict get $config applications $default_application]
            }
            dict for {application_id descriptor} $applications {
                if {[dict exists $merged_applications $application_id]} {
                    set inherited [dict get $merged_applications $application_id]
                    if {[dict exists $inherited pool_policy] &&
                            [dict exists $descriptor pool_policy]} {
                        dict set descriptor pool_policy [dict merge \
                            [dict get $inherited pool_policy] \
                            [dict get $descriptor pool_policy]]
                    }
                    set descriptor [dict merge $inherited $descriptor]
                }
                dict set merged_applications $application_id $descriptor
            }
            dict set config applications $merged_applications
        }
        return $config
    }

    proc apply_cli_config {config argv} {
        set custom_services 0
        set cli_services {}
        set startservers_set 0
        set port_overrides [dict create]
        set ftproot_set 0

        for {set i 0} {$i < [llength $argv]} {incr i} {
            set option [lindex $argv $i]
            switch -exact -- $option {
                --help {
                    dict set config help 1
                }
                --config {
                    incr i
                }
                --host {
                    dict set config host [require_value $argv [incr i] $option]
                }
                --startservers {
                    dict set config startservers [parse_protocol_list \
                        [require_value $argv [incr i] $option]]
                    set startservers_set 1
                }
                --httpport  -
                --httpsport -
                --ftpport   -
                --ftpsport  -
                --proxyport {
                    set protocol [string range $option 2 end-4]
                    dict set port_overrides $protocol \
                            [parse_port_value $option [require_value $argv [incr i] $option]]
                }
                --service {
                    set custom_services 1
                    lappend cli_services \
                        [parse_service_spec [require_value $argv [incr i] $option]]
                }
                --docroot {
                    set docroot [file normalize [require_value \
                        $argv [incr i] $option]]
                    dict set config docroot $docroot
                    set applications [dict get $config applications]
                    dict for {application_id descriptor} $applications {
                        dict set descriptor docroot $docroot
                        dict set applications $application_id $descriptor
                    }
                    dict set config applications $applications
                    if {!$ftproot_set} {
                        dict set config ftproot $docroot
                    }
                }
                --upload-area {
                    set value [require_value $argv [incr i] $option]
                    dict set config upload_area \
                        [expr {$value eq {} ? {} : [file normalize $value]}]
                }
                --max-request-bytes {
                    dict set config max_request_bytes [parse_integer_min $option \
                        [require_value $argv [incr i] $option] 1]
                }
                --max-header-bytes -
                --max_header_bytes {
                    dict set config max_header_bytes [parse_integer_min $option \
                        [require_value $argv [incr i] $option] 1]
                }
                --request-memory-threshold {
                    dict set config request_memory_threshold [parse_integer_min $option \
                        [require_value $argv [incr i] $option] 0]
                }
                --dump-multipart-requests {
                    dict set config dump_multipart_requests 1
                }
                --ftproot {
                    dict set config ftproot [file normalize \
                        [require_value $argv [incr i] $option]]
                    set ftproot_set 1
                }
                --certfile {
                    dict set config certfile [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --keyfile {
                    dict set config keyfile [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --noftp-user-check {
                    dict set config ftp_user_check 0
                }
                --logfile {
                    dict set config logfile [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --logerr {
                    dict set config logerr [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --log-level {
                    dict set config log_level [normalize_log_level $option \
                        [require_value $argv [incr i] $option]]
                }
                --conn-max-wait -
                --conn_max_wait {
                    dict set config conn_max_wait [parse_integer_min $option \
                        [require_value $argv [incr i] $option] 0]
                }
                --conn-max-workers -
                --conn_max_workers {
                    dict set config conn_max_workers [parse_integer_min $option \
                        [require_value $argv [incr i] $option] 1]
                }
                --conn-max-per-thread -
                --conn_max_per_thread {
                    dict set config conn_max_per_thread [parse_integer_min $option \
                        [require_value $argv [incr i] $option] 1]
                }
                --unix-socket {
                    dict set config unix_socket [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --quiet {
                    dict set config quiet 1
                }
                --debug {
                    dict set config debug 1
                }
                default {
                    error "unknown argument: $option"
                }
            }
        }

        if {$custom_services} {
            dict set config services $cli_services
        } else {
            set services [dict get $config services]
            if {$startservers_set} {
                set selected {}
                foreach protocol [dict get $config startservers] {
                    set found 0
                    foreach service $services {
                        if {[dict get $service protocol] eq $protocol} {
                            lappend selected $service
                            set found 1
                        }
                    }
                    if {!$found} {
                        lappend selected [dict create protocol $protocol \
                            port [dict get [dict get $config ports] $protocol]]
                    }
                }
                set services $selected
            }
            set updated {}
            foreach service $services {
                set protocol [dict get $service protocol]
                if {[dict exists $port_overrides $protocol]} {
                    dict set service port [dict get $port_overrides $protocol]
                }
                lappend updated $service
            }
            dict set config services $updated
        }
        return $config
    }

    proc finalize_config {config} {
        set applications [dict get $config applications]
        set default_application [dict get $config default_application]
        if {![dict exists $applications $default_application]} {
            error "default application is not registered: $default_application"
        }
        set default_descriptor [dict get $applications $default_application]

        dict for {application_id descriptor} $applications {
            set application_hosts {}
            if {[dict exists $descriptor hosts]} {
                set application_hosts [dict get $descriptor hosts]
            }

            # The named default application is the template for every
            # host-specific application. Global runtime values remain the
            # fallback for fields omitted by the default itself.
            set inherited [dict merge [dict create \
                docroot [dict get $config docroot] \
                encoding [dict get $config encoding]] $default_descriptor]
            if {$application_id eq $default_application} {
                set descriptor $inherited
            } else {
                if {[dict exists $inherited pool_policy] &&
                        [dict exists $descriptor pool_policy]} {
                    dict set descriptor pool_policy [dict merge \
                        [dict get $inherited pool_policy] \
                        [dict get $descriptor pool_policy]]
                }
                set descriptor [dict merge $inherited $descriptor]
                if {$application_hosts ne {}} {
                    dict set descriptor hosts $application_hosts
                }
            }
            if {[dict exists $config libdir] &&
                    ![dict exists $descriptor libdir]} {
                dict set descriptor libdir [dict get $config libdir]
            }
            dict set applications $application_id $descriptor
        }
        dict set config applications $applications

        set services [dict get $config services]
        set normalized_services {}
        foreach service $services {
            if {[dict get $service protocol] in {http https} &&
                    ![dict exists $service upload_area]} {
                dict set service upload_area [dict get $config upload_area]
            }
            if {[dict get $service protocol] in {http https} &&
                    ![dict exists $service max_request_bytes]} {
                dict set service max_request_bytes [dict get $config max_request_bytes]
            }
            if {[dict get $service protocol] in {http https} &&
                    ![dict exists $service max_header_bytes]} {
                dict set service max_header_bytes [dict get $config max_header_bytes]
            }
            if {[dict get $service protocol] in {http https} &&
                    ![dict exists $service request_memory_threshold]} {
                dict set service request_memory_threshold \
                    [dict get $config request_memory_threshold]
            }
            lappend normalized_services [normalize_service \
                $service [dict get $config certfile] [dict get $config keyfile]]
        }
        dict set config services $normalized_services
        dict set config startservers [lmap service $normalized_services {
            dict get $service protocol
        }]
        foreach internal {custom_services ports ftproot_follows_docroot} {
            dict unset config $internal
        }
        return $config
    }

    proc parse_args {argv} {
        set config_file [find_config_option $argv]
        set config [default_config]
        set config [apply_file_config $config $config_file \
            [load_config_file $config_file]]
        set config [apply_cli_config $config $argv]
        return [finalize_config $config]
    }

    proc prepare_config {argv} {
        set config [parse_args $argv]
        ::tclwire::support configure_debug [dict get $config debug]
        ::tclwire::accounting configure_debug_connection \
            [dict get $config debug_connection]
        ::tclwire::console configure $config
        return $config
    }

    proc service_transport_config {service} {
        set transport_config [dict create secure [dict get $service secure]]
        if {[dict get $service secure]} {
            dict set transport_config certfile [dict get $service certfile]
            dict set transport_config keyfile [dict get $service keyfile]
        }
        return $transport_config
    }

    proc ensure_application_dispatcher {config} {
        variable application_dispatcher

        if {$application_dispatcher eq {}} {
            set prepared_docroots {}
            dict for {application_id descriptor} [dict get $config applications] {
                set docroot [dict get $descriptor docroot]
                if {$docroot ni $prepared_docroots} {
                    ::tclwire::support prepare_doc_root $docroot \
                        [::tclwire::support runtime_doc_source]
                    lappend prepared_docroots $docroot
                }
            }
            set application_dispatcher \
                [::tclwire::ApplicationDispatcher new $config]
            $application_dispatcher start
        }
        return $application_dispatcher
    }

    proc http_service_agent_args {config service} {
        ensure_application_dispatcher $config
        set dump_multipart_requests 0
        if {[dict exists $config dump_multipart_requests]} {
            set dump_multipart_requests \
                [dict get $config dump_multipart_requests]
        }
        return [list -applicationconfig $config \
                     -protocol [dict get $service protocol] \
                     -uploadarea [dict get $service upload_area] \
                     -maxrequestbytes [dict get $service max_request_bytes] \
                     -maxheaderbytes [dict get $service max_header_bytes] \
                     -requestmemorythreshold \
                         [dict get $service request_memory_threshold] \
                     -dumpmultipartrequests $dump_multipart_requests]
    }

    proc ftp_service_agent_args {config service} {
        ::tclwire::support prepare_ftp_root [dict get $config ftproot]
        return [list -config [dict merge $config $service]]
    }

    proc proxy_service_agent_args {config service} {
        return [list -config $config]
    }

    proc create_transport_reactor {config service} {
        set protocol [dict get $service protocol]
        set service_id [dict get $service id]
        set descriptor [protocol_descriptor $protocol]
        set setup_proc [dict get $descriptor setup_proc]
        set agent_args [$setup_proc $config $service]

        return [::tclwire::TransportReactor new -host           [dict get $config host] \
                                                -port           [dict get $service port] \
                                                -protocol       $protocol \
                                                -serviceid      $service_id \
                                                -transportconfig [service_transport_config $service] \
                                                -agentclass     [dict get $descriptor agent_class] \
                                                -agentpackage   [dict get $descriptor agent_package] \
                                                -agentargs      $agent_args \
                                                -maxworkers     [dict get $config conn_max_workers] \
                                                -maxconnperthread [dict get $config conn_max_per_thread] \
                                                -connmaxwait    [dict get $config conn_max_wait]]
    }

    proc start {argv} {
        variable active
        variable active_config
        variable shutdown_requested
        variable transport_reactors
        variable console_reactor
        variable application_dispatcher

        if {$active} {
            error "TclWire runtime is already active"
        }

        set config [prepare_config $argv]
        if {[dict get $config help]} {
            return $config
        }

        ::tclwire::accounting initialize
        set transport_reactors [dict create]
        set console_reactor {}
        set logger_started 0
        set tpba_started 0
        try {

            ::tclwire::logger start $config
            set logger_started 1

            ::tclwire::tpba start
            set tpba_started 1

            set configured_services {}
            foreach service [dict get $config services] {
                set service_id [dict get $service id]
                if {$service_id in $configured_services} {
                    error "duplicate service endpoint: $service_id"
                }
                lappend configured_services $service_id
                set reactor [create_transport_reactor $config $service]
                dict set transport_reactors $service_id $reactor
                $reactor start
            }

            set console_reactor [::tclwire::ConsoleReactor new -path [dict get $config unix_socket] \
                                                               -shutdowncommand [list ::tclwire::runtime::request_shutdown]]
            $console_reactor start

        } on error {message options} {
            if {$console_reactor ne {}} {
                catch {$console_reactor destroy}
                set console_reactor {}
            }
            dict for {protocol reactor} $transport_reactors {
                catch {$reactor destroy}
            }
            set transport_reactors [dict create]
            if {$application_dispatcher ne {}} {
                catch {$application_dispatcher destroy}
                set application_dispatcher {}
            }
            if {$tpba_started} {
                catch {::tclwire::tpba stop}
            }
            if {$logger_started} {
                catch {::tclwire::logger stop}
            }
            return -options $options $message
        }

        set active_config $config
        set active 1
        set shutdown_requested 0
        return $config
    }

    proc stop {} {
        variable active
        variable active_config
        variable shutdown_requested
        variable transport_reactors
        variable console_reactor
        variable application_dispatcher

        if {$console_reactor ne {}} {
            catch {$console_reactor destroy}
            set console_reactor {}
        }
        dict for {protocol reactor} $transport_reactors {
            catch {$reactor destroy}
        }
        set transport_reactors [dict create]
        if {$application_dispatcher ne {}} {
            catch {$application_dispatcher destroy}
            set application_dispatcher {}
        }
        set tpba_error {}
        if {[catch {::tclwire::tpba stop} message options]} {
            set tpba_error [list $message $options]
        }
        catch {::tclwire::logger stop}

        set active 0
        set active_config {}
        set shutdown_requested 1

        if {$tpba_error ne {}} {
            lassign $tpba_error message options
            return -options $options $message
        }
        return
    }

    proc is_running {} {
        variable active
        return $active
    }

    proc config {} {
        variable active_config
        return $active_config
    }

    proc transport_reactor {{protocol http} {port {}}} {
        variable transport_reactors
        if {$port ne {}} {
            set service_id "$protocol:$port"
            if {![dict exists $transport_reactors $service_id]} {
                return {}
            }
            return [dict get $transport_reactors $service_id]
        }

        set matches {}
        dict for {service_id reactor} $transport_reactors {
            if {[string match "${protocol}:*" $service_id]} {
                lappend matches $reactor
            }
        }
        if {[llength $matches] == 0} {
            return {}
        }
        if {[llength $matches] > 1} {
            error "multiple '$protocol' services are active; specify a port"
        }
        return [lindex $matches 0]
    }

    proc transport_reactors {} {
        variable transport_reactors
        return $transport_reactors
    }

    proc console_reactor {} {
        variable console_reactor
        return $console_reactor
    }

    proc application_dispatcher {} {
        variable application_dispatcher
        return $application_dispatcher
    }

    proc request_shutdown {} {
        variable shutdown_requested
        set shutdown_requested 1
        return
    }

    proc run {argv} {
        variable shutdown_requested

        set config [start $argv]
        if {[dict get $config help]} {
            usage
            return $config
        }

        try {
            vwait [namespace which -variable shutdown_requested]
        } finally {
            stop
        }
        return $config
    }

    namespace export usage  parse_args prepare_config start stop is_running \
                     config transport_reactor transport_reactors request_shutdown run implemented_protocols \
                     default_protocols application_dispatcher console_reactor
    namespace ensemble create
}

package provide tclwire::runtime 0.1

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {::tclwire::runtime run $::argv} message options]} {
        puts stderr $message
        ::tclwire::runtime usage stderr
        exit 1
    }
}

unset ::tclwire_runtime_root
