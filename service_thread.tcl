# service_thread.tcl --
#
# Shared worker-thread script support for TclWire services.

namespace eval ::tclwire {}

proc ::tclwire::service_thread_script {body} {
    return [format {
    namespace eval :: {
        package require TclOO
        package require Thread

        set tclwire_root %s

        source [file join $tclwire_root service_worker.tcl]

        variable accounting ::tclwire::accounting
        variable server {}
        variable master_thread_id {}

%s

        proc demand_thread_exit {} {
            ::tclwire::service_thread_demand_exit
        }

        ::thread::wait

        ::tclwire::service_thread_cleanup
    }
} [list [::tclwire::repo_root]] $body]
}

proc ::tclwire::service_thread_apply_config {config root_keys} {
    if {[dict exists $config debug]} {
        ::tclwire::configure_debug_output [dict get $config debug]
    }

    foreach root_key $root_keys {
        switch -exact -- $root_key {
            docroot {
                if {[dict exists $config docroot] && [dict get $config docroot] ne {}} {
                    ::tclwire::set_doc_root [dict get $config docroot]
                }
            }
            ftproot {
                if {[dict exists $config ftproot] && [dict get $config ftproot] ne {}} {
                    ::tclwire::set_ftp_root [dict get $config ftproot]
                }
            }
            default {
                error "unknown service thread root key: $root_key"
            }
        }
    }
}

proc ::tclwire::service_thread_refresh_server {server config refresh_keys} {
    foreach refresh_key $refresh_keys {
        switch -exact -- $refresh_key {
            docroot {
                if {[dict exists $config docroot] && [dict get $config docroot] ne {}} {
                    [$server application] set_doc_root [dict get $config docroot]
                }
            }
            default {
                error "unknown service thread refresh key: $refresh_key"
            }
        }
    }
}

proc ::tclwire::service_thread_ensure_server {service_class config refresh_keys} {
    upvar #0 ::server server

    if {$server ne {}} {
        service_thread_refresh_server $server $config $refresh_keys
        return $server
    }

    set server [$service_class new \
        -protocol [dict get $config protocol] \
        -connectionclass [dict get $config connection_class] \
        -secure [dict get $config secure] \
        -host [dict get $config host] \
        -port [dict get $config port] \
        -serviceconfig $config]
    service_thread_refresh_server $server $config $refresh_keys
    return $server
}

proc ::tclwire::service_thread_serve {protocol service_class config root_keys refresh_keys chan connection_id serve_args {start_message {}}} {
    set accounting ::tclwire::accounting
    if {$start_message eq {}} {
        set start_message "worker $protocol command start id=$connection_id chan=$chan"
    }
    ::tclwire::msgoutput $start_message

    service_thread_apply_config $config $root_keys
    set server [service_thread_ensure_server $service_class $config $refresh_keys]
    $accounting change_thread_status [::thread::id] running "$protocol connection $connection_id"

    if {[catch {$server serve_connection $chan $connection_id {*}$serve_args} error options]} {
        catch {close $chan}
        if {[info exists ::master_thread_id] && $::master_thread_id ne {}} {
            ::thread::send -async $::master_thread_id \
                [list ::tclwire::record_connection_closed $connection_id $error]
        }
        catch {$accounting change_thread_status [::thread::id] idle}
        return -options $options $error
    }
}

proc ::tclwire::service_thread_demand_exit {} {
    set accounting ::tclwire::accounting
    upvar #0 ::server server

    catch {
        if {$server ne {}} {
            $server destroy
            set server {}
        }
    }
    catch {$accounting change_thread_status [::thread::id] terminating}
    ::thread::release [::thread::id]
}

proc ::tclwire::service_thread_cleanup {} {
    set accounting ::tclwire::accounting
    catch {
        $accounting remove_thread [::thread::id]
    }
}
