# proxy_thread.tcl --
#
# Worker-thread script template for HTTP proxy service instances.

namespace eval ::tclwire {}

set ::tclwire::proxy_thread_script [format {
    namespace eval :: {
        package require TclOO
        package require Thread

        set tclwire_root %s

        source [file join $tclwire_root tclwire.tcl]

        variable accounting ::tclwire::accounting
        variable server {}
        variable master_thread_id {}

        proc apply_proxy_config {config} {
            if {[dict exists $config debug]} {
                ::tclwire::configure_debug_output [dict get $config debug]
            }
        }

        proc ensure_proxy_server {config} {
            variable server

            if {$server ne {}} {
                return $server
            }

            set server [::tclwire::proxy_service new \
                -protocol [dict get $config protocol] \
                -connectionclass [dict get $config connection_class] \
                -secure [dict get $config secure] \
                -host [dict get $config host] \
                -port [dict get $config port] \
                -serviceconfig $config]
            return $server
        }

        proc ::tclwire::serve_transferred_proxy_connection {chan connection_id config} {
            set accounting ::tclwire::accounting
            ::tclwire::msgoutput "worker proxy command start id=$connection_id chan=$chan"

            apply_proxy_config $config
            set server [ensure_proxy_server $config]
            $accounting change_thread_status [::thread::id] running "proxy connection $connection_id"

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
