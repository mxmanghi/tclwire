# proxy_thread.tcl --
#
# Worker-thread script template for HTTP proxy service instances.

namespace eval ::tclwire {}

set ::tclwire::proxy_thread_script [::tclwire::service_thread_script {
        proc ::tclwire::serve_transferred_proxy_connection {chan connection_id config} {
            ::tclwire::service_thread_serve \
                proxy \
                ::tclwire::proxy_service \
                $config \
                {} \
                {} \
                $chan \
                $connection_id \
                {} \
                "worker proxy command start id=$connection_id chan=$chan"
        }
}]
