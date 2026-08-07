# runtime_services.tcl --
#
# Runtime service and dispatcher assembly.
#
# This module bridges normalized configuration to live runtime components. It
# prepares application docroots, creates the ApplicationDispatcher, derives
# per-protocol connection-agent constructor arguments, and constructs
# TransportReactor objects from normalized service descriptors.

namespace eval ::tclwire::runtime {
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

        if {![info object isa object $application_dispatcher]} {
            set default_application [dict get $config default_application]
            set descriptor [dict get $config applications $default_application]
            ::tclwire::support prepare_doc_root \
                [dict get $descriptor docroot] \
                [::tclwire::support runtime_doc_source] \
                [dict get $config force_docroot_seeding]
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
}
