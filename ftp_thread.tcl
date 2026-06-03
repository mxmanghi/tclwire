# ftp_thread.tcl --
#
# Worker-thread script template for FTP service instances.

namespace eval ::tclwire {}

set ::tclwire::ftp_thread_script [::tclwire::service_thread_script {
        proc ::tclwire::serve_transferred_ftp_connection {chan connection_id host port config} {
            ::tclwire::service_thread_serve \
                ftp \
                ::tclwire::ftp_service \
                $config \
                {ftproot} \
                {} \
                $chan \
                $connection_id \
                [list $host $port] \
                "worker FTP command start id=$connection_id chan=$chan"
        }
}]
