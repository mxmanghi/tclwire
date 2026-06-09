# http_thread.tcl --
#
# Worker-thread script template for HTTP service instances.

namespace eval ::tclwire {}

set ::tclwire::http_thread_script [::tclwire::service_thread_script {
        proc ::tclwire::serve_transferred_http_connection {chan connection_id config} {
            ::tclwire::service_thread_serve \
                http \
                ::tclwire::http_service \
                $config \
                {docroot ftproot} \
                {docroot} \
                $chan \
                $connection_id \
                {} \
                "worker command start id=$connection_id chan=$chan"
        }
}]
