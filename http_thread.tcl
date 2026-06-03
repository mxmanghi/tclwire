# http_thread.tcl --
#
# Worker-thread script template for HTTP service instances.

namespace eval ::tclwire {}

set ::tclwire::http_thread_script [format {
    namespace eval :: {
        package require TclOO
        package require Thread

        set tclwire_root %s

        source [file join $tclwire_root tclwire.tcl]

        variable accounting ::tclwire::accounting
        variable server {}
        variable master_thread_id {}

        proc apply_http_config {config} {
            if {[dict exists $config debug]} {
                ::tclwire::configure_debug_output [dict get $config debug]
            }
            if {[dict exists $config docroot] && [dict get $config docroot] ne {}} {
                ::tclwire::set_doc_root [dict get $config docroot]
            }
            if {[dict exists $config ftproot] && [dict get $config ftproot] ne {}} {
                ::tclwire::set_ftp_root [dict get $config ftproot]
            }
        }

        proc ensure_http_server {config} {
            variable server

            if {$server ne {}} {
                if {[dict exists $config docroot] && [dict get $config docroot] ne {}} {
                    [$server application] set_doc_root [dict get $config docroot]
                }
                return $server
            }

            set server [::tclwire::http_service new \
                -protocol [dict get $config protocol] \
                -connectionclass [dict get $config connection_class] \
                -secure [dict get $config secure] \
                -host [dict get $config host] \
                -port [dict get $config port] \
                -serviceconfig $config]
            if {[dict exists $config docroot] && [dict get $config docroot] ne {}} {
                [$server application] set_doc_root [dict get $config docroot]
            }
            return $server
        }

        proc ::tclwire::serve_transferred_http_connection {chan connection_id config} {
            set accounting ::tclwire::accounting
            ::tclwire::msgoutput "worker command start id=$connection_id chan=$chan"

            apply_http_config $config
            set server [ensure_http_server $config]
            $accounting change_thread_status [::thread::id] running "http connection $connection_id"

            if {[catch {$server serve_connection $chan $connection_id} error options]} {
                catch {close $chan}
                if {[info exists ::master_thread_id] && $::master_thread_id ne {}} {
                    ::thread::send -async $::master_thread_id \
                        [list ::tclwire::record_connection_closed $connection_id $error]
                }
                catch {$accounting change_thread_status [::thread::id] idle}
                return -options $options $error
            }
        }

        proc demand_thread_exit {} {
            variable accounting
            variable server

            catch {
                if {$server ne {}} {
                    $server destroy
                    set server {}
                }
            }
            catch {$accounting change_thread_status [::thread::id] terminating}
            ::thread::release [::thread::id]
        }

        ::thread::wait

        catch {
            variable accounting
            $accounting remove_thread [::thread::id]
        }
    }
} [list [::tclwire::repo_root]]]
