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

namespace eval ::tclwire {}

namespace eval ::tclwire::runtime {
    variable active 0
    variable active_config {}
    variable shutdown_requested 0
    variable transport_reactors [dict create]
    variable application_dispatcher {}
    variable protocol_defaults [dict create \
        http 8990 \
        https 9443 \
        ftp 8991 \
        ftps 990 \
        proxy 8992]

    proc implemented_protocols {} {
        variable protocol_defaults
        return [dict keys $protocol_defaults]
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
        puts $channel "      Add an explicit future service specification."
        puts $channel "  --docroot <path>"
        puts $channel "  --ftproot <path>"
        puts $channel "  --certfile <path>"
        puts $channel "  --keyfile <path>"
        puts $channel "  --noftp-user-check"
        puts $channel "  --logfile <path>    Default: /tmp/tclwire.log"
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

    proc parse_service_spec {spec} {
        if {![regexp {^([a-z0-9_+-]+):([0-9]+)$} $spec -> protocol port]} {
            error "invalid service spec: $spec"
        }
        if {$protocol ni [implemented_protocols]} {
            error "unsupported protocol in service spec: $protocol"
        }
        return [dict create \
            protocol $protocol \
            port [parse_port_value --service $port]]
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

    proc parse_args {argv} {
        variable protocol_defaults

        set host 127.0.0.1
        set quiet 0
        set debug 0
        set help 0
        set docroot [::tclwire::support default_doc_root]
        set ftproot [::tclwire::support default_ftp_root]
        set certfile {}
        set keyfile {}
        set logfile [file normalize /tmp/tclwire.log]
        set ftp_user_check 1
        set ftproot_follows_docroot [expr {$ftproot eq $docroot}]
        set startservers [default_protocols]
        set services {}
        set custom_services 0
        set ports $protocol_defaults
        set default_application default
        set default_encoding utf-8

        for {set i 0} {$i < [llength $argv]} {incr i} {
            set option [lindex $argv $i]
            switch -exact -- $option {
                --help {
                    set help 1
                }
                --host {
                    set host [require_value $argv [incr i] $option]
                }
                --startservers {
                    set startservers [parse_protocol_list \
                        [require_value $argv [incr i] $option]]
                }
                --httpport  -
                --httpsport -
                --ftpport   -
                --ftpsport  -
                --proxyport {
                    set protocol [string range $option 2 end-4]
                    dict set ports $protocol [parse_port_value $option [require_value $argv [incr i] $option]]
                }
                --service {
                    if {!$custom_services} {
                        set services {}
                        set custom_services 1
                    }
                    lappend services [parse_service_spec \
                        [require_value $argv [incr i] $option]]
                }
                --docroot {
                    set docroot [file normalize \
                        [require_value $argv [incr i] $option]]
                    if {$ftproot_follows_docroot} {
                        set ftproot $docroot
                    }
                }
                --ftproot {
                    set ftproot [file normalize \
                        [require_value $argv [incr i] $option]]
                    set ftproot_follows_docroot 0
                }
                --certfile {
                    set certfile [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --keyfile {
                    set keyfile [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --noftp-user-check {
                    set ftp_user_check 0
                }
                --logfile {
                    set logfile [file normalize \
                        [require_value $argv [incr i] $option]]
                }
                --quiet {
                    set quiet 1
                }
                --debug {
                    set debug 1
                }
                default {
                    error "unknown argument: $option"
                }
            }
        }

        set applications [dict create \
            default [dict create class      ::tclwire::CApplication \
                                 package    tclwire::application    \
                                 hosts      {localhost 127.0.0.1}   \
                                 docroot    $docroot                \
                                 encoding   $default_encoding       \
                                 pool_policy [dict create minimum_workers 0 maximum_workers 20]]]

        if {!$custom_services} {
            foreach protocol $startservers {
                lappend services [dict create \
                    protocol $protocol \
                    port [dict get $ports $protocol]]
            }
        } else {
            set selected {}
            foreach service $services {
                if {[dict get $service protocol] in $startservers} {
                    lappend selected $service
                }
            }
            set services $selected
        }

        return [dict create help         $help \
                            host         $host \
                            quiet        $quiet \
                            debug        $debug \
                            encoding     $default_encoding \
                            docroot      $docroot \
                            ftproot      $ftproot \
                            certfile     $certfile \
                            keyfile      $keyfile \
                            ftp_user_check $ftp_user_check \
                            logfile      $logfile \
                            startservers $startservers \
                            services     $services \
                            default_application $default_application \
                            applications $applications]
    }

    proc prepare_config {argv} {
        set config [parse_args $argv]
        ::tclwire::support configure_debug [dict get $config debug]
        return $config
    }

    proc start {argv} {
        variable active
        variable active_config
        variable shutdown_requested
        variable transport_reactors
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
        set logger_started 0
        set tpba_started 0
        try {

            ::tclwire::logger start $config
            set logger_started 1

            ::tclwire::tpba start
            set tpba_started 1

            set configured_protocols {}
            foreach service [dict get $config services] {
                set protocol [dict get $service protocol]
                if {$protocol in $configured_protocols} {
                    error "multiple listeners for protocol '$protocol' are not supported"
                }
                lappend configured_protocols $protocol

                switch -exact -- $protocol {
                    http {
                        if {$application_dispatcher eq {}} {
                            set application_dispatcher \
                                [::tclwire::ApplicationDispatcher new $config]
                            $application_dispatcher start
                        }
                        set reactor [::tclwire::TransportReactor new \
                            -host [dict get $config host] \
                            -port [dict get $service port] \
                            -protocol http \
                            -agentclass ::tclwire::HttpConnectionAgent \
                            -agentpackage tclwire::http::connection_agent \
                            -agentargs [list -applicationconfig $config]]
                    }
                    ftp {
                        ::tclwire::support prepare_ftp_root \
                            [dict get $config ftproot]
                        set reactor [::tclwire::TransportReactor new \
                            -host [dict get $config host] \
                            -port [dict get $service port] \
                            -protocol ftp \
                            -agentclass ::tclwire::FtpConnectionAgent \
                            -agentpackage tclwire::ftp::connection_agent \
                            -agentargs [list -config $config]]
                    }
                    proxy {
                        set reactor [::tclwire::TransportReactor new \
                            -host [dict get $config host] \
                            -port [dict get $service port] \
                            -protocol proxy \
                            -agentclass ::tclwire::ProxyConnectionAgent \
                            -agentpackage tclwire::proxy::connection_agent \
                            -agentargs [list -config $config]]
                    }
                    default {
                        error "configured protocol is not implemented: $protocol"
                    }
                }
                dict set transport_reactors $protocol $reactor
                $reactor start
            }

        } on error {message options} {
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
        variable application_dispatcher

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

    proc transport_reactor {{protocol http}} {
        variable transport_reactors
        if {![dict exists $transport_reactors $protocol]} {
            return {}
        }
        return [dict get $transport_reactors $protocol]
    }

    proc transport_reactors {} {
        variable transport_reactors
        return $transport_reactors
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
                     default_protocols application_dispatcher
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
