# tclwire_common.tcl --
#
# Shared TclWire runtime definitions used by the entry point and worker
# threads.

source [file join [file dirname [file normalize [info script]]] support.tcl]
source [file join [file dirname [file normalize [info script]]] threads_shared_db.tcl]
source [file join [file dirname [file normalize [info script]]] service_logging.tcl]
source [file join [file dirname [file normalize [info script]]] service_base.tcl]

namespace eval ::tclwire {
    variable next_connection_id 0
    variable service_classes
    variable connection_classes
    variable connections {}
    array set service_classes {}
    array set connection_classes {}
}

proc ::tclwire::record_connection_opened {protocol chan host port service_endpoint worker_thread_id} {
    variable next_connection_id
    variable connections

    set connection_id [incr next_connection_id]
    dict set connections $connection_id [dict create \
        id $connection_id \
        created_on [clock seconds] \
        closed_on 0 \
        protocol $protocol \
        channel $chan \
        peer_host $host \
        peer_port $port \
        service_endpoint $service_endpoint \
        worker_thread_id $worker_thread_id \
        status open \
        error {}]

    return $connection_id
}

proc ::tclwire::record_connection_closed {connection_id {error {}}} {
    variable connections

    if {![dict exists $connections $connection_id]} {
        return
    }

    dict set connections $connection_id closed_on [clock seconds]
    dict set connections $connection_id status closed
    dict set connections $connection_id error $error
}

proc ::tclwire::connection_database {} {
    variable connections
    return $connections
}

proc ::tclwire::register_connection_class {protocol spec} {
    variable connection_classes
    variable service_classes

    if {![dict exists $spec service_class]} {
        error "missing service_class for connection protocol: $protocol"
    }
    if {![dict exists $spec connection_class]} {
        dict set spec connection_class $protocol
    }
    if {![dict exists $spec secure]} {
        dict set spec secure 0
    }
    if {![dict exists $spec thread_script]} {
        dict set spec thread_script {}
    }

    set connection_classes($protocol) $spec
    set service_classes($protocol) [dict get $spec service_class]
    namespace ensemble configure ::tclwire -map [command_map]
    return $spec
}

proc ::tclwire::register_service_class {protocol class_name} {
    set spec [dict create \
        service_class $class_name \
        connection_class $protocol \
        secure 0]

    switch -exact -- $protocol {
        http  { dict set spec default_port 8990 }
        ftp   { dict set spec default_port 8991 }
        proxy { dict set spec default_port 8992 }
    }

    register_connection_class $protocol $spec
    return $class_name
}

proc ::tclwire::connection_class_spec {protocol} {
    variable connection_classes

    if {![info exists connection_classes($protocol)]} {
        error "unsupported protocol: $protocol"
    }
    return $connection_classes($protocol)
}

proc ::tclwire::service_class {protocol} {
    return [dict get [connection_class_spec $protocol] service_class]
}

proc ::tclwire::implemented_protocols {} {
    variable connection_classes

    return [lsort [array names connection_classes]]
}

proc ::tclwire::connection_protocols_for_class {connection_class} {
    variable connection_classes

    set protocols {}
    foreach protocol [array names connection_classes] {
        if {[dict get $connection_classes($protocol) connection_class] eq $connection_class} {
            lappend protocols $protocol
        }
    }
    return [lsort $protocols]
}

proc ::tclwire::default_protocols {} {
    return [list http]
}

proc ::tclwire::default_port {protocol} {
    set spec [connection_class_spec $protocol]
    if {[dict exists $spec default_port]} {
        return [dict get $spec default_port]
    }
    error "missing default port for protocol: $protocol"
}

proc ::tclwire::command_map {} {
    return [dict create \
        connection_class_spec           ::tclwire::connection_class_spec        \
        connection_database             ::tclwire::connection_database          \
        connection_protocols_for_class  ::tclwire::connection_protocols_for_class \
        default_port                    ::tclwire::default_port                 \
        log_value                       ::tclwire::log_value                    \
        default_protocols               ::tclwire::default_protocols            \
        register_connection_class       ::tclwire::register_connection_class    \
        register_service_class          ::tclwire::register_service_class       \
        service_class                   ::tclwire::service_class                \
        start_logfile                   ::tclwire::start_logfile                \
        stop_logfile                    ::tclwire::stop_logfile                 \
        timestamp                       ::tclwire::timestamp                    \
        write_log_line                  ::tclwire::write_log_line]
}

namespace ensemble create -command ::tclwire -map [::tclwire::command_map]

source [file join [file dirname [file normalize [info script]]] service_thread.tcl]
source [file join [file dirname [file normalize [info script]]] http_thread.tcl]
source [file join [file dirname [file normalize [info script]]] ftp_thread.tcl]
source [file join [file dirname [file normalize [info script]]] proxy_thread.tcl]
source [file join [file dirname [file normalize [info script]]] http_endpoint.tcl]
source [file join [file dirname [file normalize [info script]]] http_server.tcl]
source [file join [file dirname [file normalize [info script]]] ftp_server.tcl]
source [file join [file dirname [file normalize [info script]]] proxy_server.tcl]
::tclwire::register_connection_class https [dict create service_class       ::tclwire::http_service \
                                                        connection_class    http    \
                                                        secure              1       \
                                                        default_port        9443]

::tclwire::register_connection_class ftps [dict create service_class    ::tclwire::ftp_service  \
                                                       connection_class ftp                     \
                                                       secure           1                       \
                                                       default_port     990]
