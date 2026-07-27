# runtime_protocols.tcl --
#
# Protocol metadata for the TclWire runtime.
#
# This module owns the protocol descriptor table used while parsing service
# configuration and while constructing transport reactors. The descriptor
# dictionary is keyed by protocol name and each value carries the default port,
# TLS flag, human description, connection-agent package/class, and the runtime
# setup procedure used to build agent constructor arguments.

namespace eval ::tclwire::runtime {
    ::tclwire::define_constant protocol_descriptors [dict create \
        http [dict create   default_port 8990 \
                            description "HTTP application service" \
                            secure 0 \
                            agent_class ::tclwire::HttpConnectionAgent \
                            agent_package tclwire::http::connection_agent \
                            setup_proc ::tclwire::runtime::http_service_agent_args] \
        https [dict create  default_port 9443 \
                            description "HTTPS application service" \
                            secure 1 \
                            agent_class ::tclwire::HttpConnectionAgent \
                            agent_package tclwire::http::connection_agent \
                            setup_proc ::tclwire::runtime::http_service_agent_args] \
        ftp [dict create    default_port 8991 \
                            description "FTP file transfer service" \
                            secure 0 \
                            agent_class ::tclwire::FtpConnectionAgent \
                            agent_package tclwire::ftp::connection_agent \
                            setup_proc ::tclwire::runtime::ftp_service_agent_args] \
        ftps [dict create   default_port 990 \
                            description "FTPS file transfer service" \
                            secure 1 \
                            agent_class ::tclwire::FtpConnectionAgent \
                            agent_package tclwire::ftp::connection_agent \
                            setup_proc ::tclwire::runtime::ftp_service_agent_args] \
        proxy [dict create  default_port 8992 \
                            description "HTTP proxy service" \
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
    proc secure_protocol {protocol} {
        return [dict get [protocol_descriptor $protocol] secure]
    }

    proc normalize_service {service default_certfile default_keyfile} {
        set protocol [dict get $service protocol]
        set descriptor [protocol_descriptor $protocol]
        set port [dict get $service port]
        dict set service id "$protocol:$port"
        dict set service secure [dict get $descriptor secure]
        if {![dict exists $service description]} {
            dict set service description [dict get $descriptor description]
        }
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
}
