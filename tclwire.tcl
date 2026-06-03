#!/usr/bin/env tclsh
#
# tclwire.tcl -- TclWire application server entry point.
#
# TclWire application server entry point.
#
# Copyright (c) 2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

source [file join [file dirname [file normalize [info script]]] tclwire_common.tcl]
source [file join [file dirname [file normalize [info script]]] logger.tcl]
source [file join [file dirname [file normalize [info script]]] thread_master.tcl]

namespace eval ::tclwire {
    variable    next_service_id     0
    variable    thread_masters
    array set thread_masters {}
}

proc ::tclwire::usage {} {
    set implemented_servers [join [implemented_protocols] ", "]
    puts stderr "Usage: tclsh tclwire.tcl ?options?"
    puts stderr ""
    puts stderr "Options:"
    puts stderr "  --help"
    puts stderr "      Show this help message."
    puts stderr "  --host <address>"
    puts stderr "      Bind all selected servers to <address>. Default: 127.0.0.1"
    puts stderr "  --startservers <list>"
    puts stderr "      Comma-separated list of servers to start. Use 'all' to start every"
    puts stderr "      implemented server. Implemented servers: $implemented_servers"
    puts stderr "  --httpport <port>"
    puts stderr "      Port for the default HTTP server. Default: 8990"
    puts stderr "  --httpsport <port>"
    puts stderr "      Port for the default HTTPS server. Default: 9443"
    puts stderr "  --ftpport <port>"
    puts stderr "      Port for the default FTP server. Default: 8991"
    puts stderr "  --ftpsport <port>"
    puts stderr "      Port for the default implicit FTPS server. Default: 990"
    puts stderr "  --proxyport <port>"
    puts stderr "      Port for the default HTTP proxy server. Default: 8992"
    puts stderr "  --certfile <path>"
    puts stderr "      TLS certificate file for secure listeners."
    puts stderr "  --keyfile <path>"
    puts stderr "      TLS key file for secure listeners."
    puts stderr "  --service <protocol:port>"
    puts stderr "      Add an explicit service entry. May be repeated."
    puts stderr "  --docroot <path>"
    puts stderr "      Document root for HTTP/HTTPS test content."
    puts stderr "  --ftproot <path>"
    puts stderr "      Root directory exposed by the FTP server."
    puts stderr "  --noftp-user-check"
    puts stderr "      Disable system user verification for FTP login."
    puts stderr "  --logfile <path>"
    puts stderr "      File where request log lines are appended."
    puts stderr "      Default: /tmp/tclwire.log"
    puts stderr "  --quiet"
    puts stderr "      Suppress listener startup messages."
    puts stderr "  --debug"
    puts stderr "      Enable verbose test debug output."
}

proc ::tclwire::parse_service_spec {spec} {
    if {![regexp {^([a-z0-9_+-]+):([0-9]+)$} $spec -> protocol port]} {
        error "invalid service spec: $spec"
    }
    connection_class_spec $protocol
    if {$port < 1 || $port > 65535} {
        error "invalid port: $port"
    }

    return [dict create protocol $protocol port $port]
}

proc ::tclwire::parse_port_value {name value} {
    if {![string is integer -strict $value] || $value < 1 || $value > 65535} {
        error "invalid value for $name: $value"
    }
    return $value
}

proc ::tclwire::parse_startservers_value {value} {
    set normalized [string trim $value]
    if {$normalized eq {}} {
        error "invalid value for --startservers: empty list"
    }

    if {$normalized eq "all"} {
        return [implemented_protocols]
    }

    set selected {}
    foreach protocol [split $normalized ,] {
        set protocol [string trim $protocol]
        if {$protocol eq {}} {
            error "invalid value for --startservers: empty server name"
        }
        if {$protocol ni [implemented_protocols]} {
            error "unsupported server in --startservers: $protocol"
        }
        if {$protocol ni $selected} {
            lappend selected $protocol
        }
    }

    return $selected
}

proc ::tclwire::parse_args {argv} {
    set host 127.0.0.1
    set quiet 0
    set debug 0
    set docroot [::tclwire::doc_root]
    set ftproot [::tclwire::ftp_root]
    set certfile {}
    set keyfile {}
    set logfile [file normalize /tmp/tclwire.log]
    set ftp_user_check 1
    set ftproot_follows_docroot [expr {$ftproot eq $docroot}]
    array set default_ports {}
    foreach protocol [implemented_protocols] {
        set spec [connection_class_spec $protocol]
        if {[dict exists $spec default_port]} {
            set default_ports($protocol) [dict get $spec default_port]
        }
    }
    set startservers [default_protocols]
    set services {}
    set custom_services 0

    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        switch -- $arg {
            --host {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --host"
                }
                set host [lindex $argv $i]
            }
            --httpport {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --httpport"
                }
                if {![info exists default_ports(http)]} {
                    error "HTTP protocol is not available"
                }
                set default_ports(http) [parse_port_value --httpport [lindex $argv $i]]
            }
            --httpsport {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --httpsport"
                }
                if {![info exists default_ports(https)]} {
                    error "HTTPS protocol is not available"
                }
                set default_ports(https) [parse_port_value --httpsport [lindex $argv $i]]
            }
            --ftpport {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --ftpport"
                }
                if {![info exists default_ports(ftp)]} {
                    error "FTP protocol is not available"
                }
                set default_ports(ftp) [parse_port_value --ftpport [lindex $argv $i]]
            }
            --ftpsport {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --ftpsport"
                }
                if {![info exists default_ports(ftps)]} {
                    error "FTPS protocol is not available"
                }
                set default_ports(ftps) [parse_port_value --ftpsport [lindex $argv $i]]
            }
            --proxyport {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --proxyport"
                }
                if {![info exists default_ports(proxy)]} {
                    error "proxy protocol is not available"
                }
                set default_ports(proxy) [parse_port_value --proxyport [lindex $argv $i]]
            }
            --startservers {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --startservers"
                }
                set startservers [parse_startservers_value [lindex $argv $i]]
            }
            --certfile {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --certfile"
                }
                set certfile [file normalize [lindex $argv $i]]
            }
            --keyfile {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --keyfile"
                }
                set keyfile [file normalize [lindex $argv $i]]
            }
            --docroot {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after $arg"
                }
                set docroot [file normalize [lindex $argv $i]]
                if {$ftproot_follows_docroot} {
                    set ftproot $docroot
                }
            }
            --ftproot {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after $arg"
                }
                set ftproot [file normalize [lindex $argv $i]]
                set ftproot_follows_docroot 0
            }
            --noftp-user-check {
                set ftp_user_check 0
            }
            --logfile {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --logfile"
                }
                set logfile [file normalize [lindex $argv $i]]
            }
            --service {
                incr i
                if {$i >= [llength $argv]} {
                    error "missing value after --service"
                }
                if {!$custom_services} {
                    set services {}
                    set custom_services 1
                }
                lappend services [parse_service_spec [lindex $argv $i]]
            }
            --quiet {
                set quiet 1
            }
            --debug {
                set debug 1
            }
            --help {
                usage
                exit 0
            }
            default {
                error "unknown argument: $arg"
            }
        }
    }

    if {!$custom_services} {
        set services {}
        foreach protocol $startservers {
            if {![info exists default_ports($protocol)]} {
                error "missing default port for protocol: $protocol"
            }
            lappend services [dict create protocol $protocol port $default_ports($protocol)]
        }
    } else {
        set filtered_services {}
        foreach service_spec $services {
            if {[dict get $service_spec protocol] in $startservers} {
                lappend filtered_services $service_spec
            }
        }
        set services $filtered_services
    }

    return [dict create host $host quiet $quiet debug $debug        \
                        docroot $docroot ftproot $ftproot           \
                        certfile $certfile keyfile $keyfile         \
                        ftp_user_check $ftp_user_check              \
                        logfile $logfile                            \
                        services $services startservers $startservers]
}

proc ::tclwire::configure_roots {config} {
    set docroot [dict get $config docroot]
    set ftproot [dict get $config ftproot]
    set connection_classes {}

    foreach service_spec [dict get $config services] {
        set spec [connection_class_spec [dict get $service_spec protocol]]
        set connection_class [dict get $spec connection_class]
        if {$connection_class ni $connection_classes} {
            lappend connection_classes $connection_class
        }
    }

    if {[lsearch -exact $connection_classes http] >= 0} {
        set docroot_exists [file exists $docroot]
        if {$docroot_exists && ![file isdirectory $docroot]} {
            error "document root exists but is not a directory: $docroot"
        }

        if {!$docroot_exists} {
            file mkdir $docroot
        }
        seed_doc_root $docroot
        ::tclwire::set_doc_root $docroot
    }

    if {[lsearch -exact $connection_classes ftp] >= 0} {
        if {[file exists $ftproot] && ![file isdirectory $ftproot]} {
            error "FTP root exists but is not a directory: $ftproot"
        }

        if {![file exists $ftproot]} {
            file mkdir $ftproot
            seed_ftp_root $ftproot
        }
        ::tclwire::set_ftp_root $ftproot
    }
}

proc ::tclwire::configure_https_credentials {config} {
    set certfile    [dict get $config certfile]
    set keyfile     [dict get $config keyfile]

    if {$certfile ne {}} {
        ::tclwire::set_https_cert_file $certfile
    }
    if {$keyfile ne {}} {
        ::tclwire::set_https_key_file $keyfile
    }
}

proc ::tclwire::seed_doc_root {docroot} {
    set index_source [file join [::tclwire::repo_root] index.html]
    set index_target [file join $docroot index.html]
    if {[file exists $index_source] && ![file exists $index_target]} {
        file copy $index_source $index_target
    }
}

proc ::tclwire::seed_ftp_root {ftproot} {
    set welcome_target [file join $ftproot welcome.txt]
    if {![file exists $welcome_target]} {
        set chan [open $welcome_target w]
        try {
            puts $chan "Welcome to TclWire FTP."
        } finally {
            close $chan
        }
    }
}

proc ::tclwire::thread_script_for_connection_class {connection_class} {
    variable connection_classes

    foreach protocol [array names connection_classes] {
        set spec $connection_classes($protocol)
        if {[dict get $spec connection_class] ne $connection_class} {
            continue
        }
        if {[dict exists $spec thread_script] && [dict get $spec thread_script] ne {}} {
            return [dict get $spec thread_script]
        }
    }

    switch -exact -- $connection_class {
        http {
            return $::tclwire::http_thread_script
        }
        ftp {
            return $::tclwire::ftp_thread_script
        }
        proxy {
            return $::tclwire::proxy_thread_script
        }
        default {
            return {}
        }
    }
}

proc ::tclwire::thread_master_for_connection_class {connection_class} {
    variable thread_masters

    set thread_script [thread_script_for_connection_class $connection_class]
    if {$thread_script eq {}} {
        return {}
    }

    if {![info exists thread_masters($connection_class)]} {
        set thread_masters($connection_class) [::tclwire::ThreadMaster new $thread_script]
    }

    return $thread_masters($connection_class)
}

proc ::tclwire::stop_thread_masters {} {
    variable thread_masters

    foreach connection_class [array names thread_masters] {
        set thread_master $thread_masters($connection_class)
        catch {$thread_master stop_threads}
        catch {$thread_master destroy}
        unset thread_masters($connection_class)
    }
}

proc ::tclwire::create_service {protocol host port quiet logfile thread_master service_config} {
    variable next_service_id

    set connection_spec [connection_class_spec $protocol]
    set class_name [dict get $connection_spec service_class]
    set connection_class [dict get $connection_spec connection_class]
    set secure [dict get $connection_spec secure]
    set object_name ::tclwire::service[incr next_service_id]

    return [$class_name create $object_name \
                                -protocol           $protocol   \
                                -connectionclass    $connection_class \
                                -secure             $secure     \
                                -host               $host       \
                                -port               $port       \
                                -quiet              $quiet      \
                                -logfile            $logfile    \
                                -threadmaster       $thread_master \
                                -serviceconfig      $service_config]
}

proc ::tclwire::start_services {config} {
    set host [dict get $config host]
    set quiet [dict get $config quiet]
    set logfile [dict get $config logfile]
    set instances {}

    foreach service_spec [dict get $config services] {
        set protocol [dict get $service_spec protocol]
        set port     [dict get $service_spec port]
        set connection_spec [connection_class_spec $protocol]
        set connection_class [dict get $connection_spec connection_class]
        set thread_master [thread_master_for_connection_class $connection_class]
        set service [create_service $protocol $host $port $quiet $logfile $thread_master $config]
        $service start
        lappend instances $service
    }

    return [dict create services $instances]
}

proc ::tclwire::stop_services {service_state} {
    set services [dict get $service_state services]
    foreach service $services {
        catch {$service destroy}
    }
    stop_thread_masters
}

proc ::tclwire::run {argv} {
    set config [parse_args $argv]
    ::tclwire::configure_debug_output [dict get $config debug]
    configure_roots $config
    configure_https_credentials $config
    start_logfile $config
    set service_state [start_services $config]
    try {
        vwait ::tclwire::forever
    } finally {
        stop_services $service_state
        stop_logfile
    }
}

proc ::tclwire::command_map {} {
    return [dict create \
        configure_https_credentials ::tclwire::configure_https_credentials \
        configure_roots ::tclwire::configure_roots \
        connection_class_spec ::tclwire::connection_class_spec \
        connection_database ::tclwire::connection_database \
        connection_protocols_for_class ::tclwire::connection_protocols_for_class \
        create_service ::tclwire::create_service \
        default_port ::tclwire::default_port \
        log_value ::tclwire::log_value \
        default_protocols ::tclwire::default_protocols \
        parse_args ::tclwire::parse_args \
        parse_service_spec ::tclwire::parse_service_spec \
        register_connection_class ::tclwire::register_connection_class \
        register_service_class ::tclwire::register_service_class \
        run ::tclwire::run \
        seed_doc_root ::tclwire::seed_doc_root \
        seed_ftp_root ::tclwire::seed_ftp_root \
        service_class ::tclwire::service_class \
        start_services ::tclwire::start_services \
        start_logfile ::tclwire::start_logfile \
        stop_services ::tclwire::stop_services \
        stop_thread_masters ::tclwire::stop_thread_masters \
        stop_logfile ::tclwire::stop_logfile \
        timestamp ::tclwire::timestamp \
        write_log_line ::tclwire::write_log_line \
        usage ::tclwire::usage]
}

namespace ensemble configure ::tclwire -map [::tclwire::command_map]

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    if {[catch {::tclwire::run $argv} message]} {
        puts stderr $message
        ::tclwire::usage
        exit 1
    }
    puts stderr "Server exits..."
}
