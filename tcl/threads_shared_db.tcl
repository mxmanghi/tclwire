# -- threads_accounting_db.tcl
#
# Shared TclWire state. ThreadMaster owns pool policy; this namespace provides
# the shared catalog and thread ledger used by infrastructure components,
# workers and inspectors.
#
# The shared array is named `tclwire`.
#
# Top-level references:
#
#   - timestamp: shared-state lifecycle timestamp, populated by its owner
#   - accounting: keyed thread accounting records
#   - connections: keyed connection accounting records
#   - tpba_thread_id: Thread-Pool Broker Agent endpoint identifier
#   - logger_thread_id: Logging Agent endpoint identifier
#
# Every cataloged reference is created with an empty value. Component owners
# replace that marker when the corresponding information becomes available and
# restore it to empty when the information is no longer valid.
#
#  thread accounting:
#
#   A dictionary having the following keys
#
#	- nruns: number of tasks carried out by the thread
#	- last_run_start: initial time of the last run performed
#	- last_run_end: ending time of the last run performed
#	- created_on: timestamp at which the accounting entry was created
#	- command: command currently or most recently run by the thread
#	- status: current status (created, allocated, idle, running, terminating)
#	- family: protocol or execution family assigned by the pool owner
#	- http_host: current or most recently observed Host header for HTTP(S) workers
#
#  connection accounting:
#
#   A dictionary keyed by connection_key. Each value describes one active
#   accepted client connection. Closed connections are removed from this store;
#   callers that need historical data must log the close snapshot returned by
#   record_connection_closed.
#

package require Thread
package require tclwire::shared_state 0.1

namespace eval ::tclwire::accounting {
    variable valid_thread_statuses {created allocated idle running terminating}
    variable valid_connection_statuses {opening open closing closed failed}

    proc initialize {} {
        return [::tclwire::shared_state initialize]
    }

    proc is_initialized {} {
        return [::tclwire::shared_state is_initialized]
    }

    proc reset {} {
        return [::tclwire::shared_state reset]
    }

    proc normalize_family {family} {
        return [string tolower [string trim $family]]
    }

    proc new_thread_account {{status created} {family {}} {http_host {}}} {
        variable valid_thread_statuses
        if {$status ni $valid_thread_statuses} {
            error "Unknown thread status '$status'"
        }

        set family [normalize_family $family]
        set account [dict create nruns      0 \
                          last_run_start    0 \
                          last_run_end      0 \
                          created_on        [clock seconds] \
                          command           {} \
                          status            $status \
                          family            $family \
                          http_host         $http_host]
        return $account
    }

    proc register_thread {tid {status created} {family {}}} {
        initialize
        ::tsv::lock tclwire {
            if {[::tsv::keylget tclwire accounting $tid thread_d]} {
                error "Thread $tid account already exists"
            }
            ::tsv::keylset tclwire accounting $tid [new_thread_account $status $family]
        }
        return $tid
    }

    proc add_new_thread {tid} {
        return [register_thread $tid created]
    }

    proc allocate_idle_thread {} {
        initialize
        set idle_thread ""
        ::tsv::lock tclwire {
            foreach tid [::tsv::keylkeys tclwire accounting] {
                ::tsv::keylget tclwire accounting $tid thd_d
                if {[dict get $thd_d status] == "idle"} {
                    set idle_thread $tid
                    dict set thd_d status allocated
                    ::tsv::keylset tclwire accounting $tid $thd_d
                    break
                }
            }
        }
        return $idle_thread
    }

    proc change_thread_status {tid newstatus {tcl_command ""}} {
        variable valid_thread_statuses
        initialize
        if {$newstatus ni $valid_thread_statuses} {
            error "Unknown thread status '$newstatus'"
        }

        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire accounting $tid thread_d]} {
                error "Thread $tid account doesn't exist"
            }

            dict with thread_d {
                set current_status $status
                set status $newstatus
                switch $newstatus {
                    running {
                        set last_run_start [clock seconds]
                        set command        $tcl_command
                    }
                    idle {
                        set last_run_end [clock seconds]
                        if {$current_status == "running"} { incr nruns }
                    }
                }
            }
            ::tsv::keylset tclwire accounting $tid $thread_d
        }
    }

    proc set_thread_http_host {tid http_host} {
        initialize
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire accounting $tid thread_d]} {
                error "Thread $tid account doesn't exist"
            }
            if {[dict get $thread_d family] ni {http https}} {
                error "Thread $tid does not belong to the http family"
            }
            dict set thread_d http_host $http_host
            ::tsv::keylset tclwire accounting $tid $thread_d
        }
        return $http_host
    }

    proc remove_thread {tid} {
        initialize
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire accounting $tid thread_d]} {
                error "Thread $tid account doesn't exist"
            }
            ::tsv::keyldel tclwire accounting $tid
        }
    }

    proc get_thread_account {tid} {
        initialize
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire accounting $tid thread_d]} {
                error "Thread $tid account doesn't exist"
            }
            return $thread_d
        }
    }

    proc get_threads_database {} {
        initialize
        ::tsv::lock tclwire {
            set threads_acc_d [dict create]
            foreach tid [::tsv::keylkeys tclwire accounting] {
                dict set threads_acc_d $tid [::tsv::keylget tclwire accounting $tid]
            }
        }
        return $threads_acc_d
    }

    proc new_connection_record {args} {
        variable valid_connection_statuses

        set now [clock seconds]
        set record [dict create \
            connection_key {} \
            connection_id {} \
            protocol {} \
            service_id {} \
            listener_host {} \
            listener_port {} \
            peer_host {} \
            peer_port {} \
            secure 0 \
            pool_key {} \
            worker_thread_id {} \
            agent_class {} \
            agent_id {} \
            status opening \
            opened_at $now \
            last_activity_at $now \
            closed_at {} \
            close_reason {} \
            transport_error {} \
            current_transaction_id {} \
            current_command {} \
            request_count 0 \
            bytes_in 0 \
            bytes_out 0]

        if {[llength $args] % 2 != 0} {
            error "connection record fields must be key/value pairs"
        }
        foreach {field value} $args {
            if {![dict exists $record $field]} {
                error "unknown connection record field '$field'"
            }
            dict set record $field $value
        }
        if {[dict get $record connection_key] eq {}} {
            error "connection record requires connection_key"
        }
        set status [dict get $record status]
        if {$status ni $valid_connection_statuses} {
            error "Unknown connection status '$status'"
        }
        return $record
    }

    proc validate_connection_update {fields} {
        variable valid_connection_statuses
        if {[llength $fields] % 2 != 0} {
            error "connection update fields must be key/value pairs"
        }
        set template [new_connection_record connection_key template]
        foreach {field value} $fields {
            if {![dict exists $template $field]} {
                error "unknown connection record field '$field'"
            }
            if {$field eq "status" && $value ni $valid_connection_statuses} {
                error "Unknown connection status '$value'"
            }
        }
        return
    }

    proc record_connection_opened {connection_key fields} {
        initialize
        set record [new_connection_record {*}$fields connection_key $connection_key]
        ::tsv::lock tclwire {
            if {[::tsv::keylget tclwire connections $connection_key connection_d]} {
                error "Connection $connection_key record already exists"
            }
            ::tsv::keylset tclwire connections $connection_key $record
        }
        return $connection_key
    }

    proc update_connection {connection_key fields} {
        initialize
        validate_connection_update $fields
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire connections $connection_key connection_d]} {
                error "Connection $connection_key record doesn't exist"
            }
            foreach {field value} $fields {
                dict set connection_d $field $value
            }
            if {![dict exists $fields last_activity_at] &&
                    [dict get $connection_d status] ni {closed failed}} {
                dict set connection_d last_activity_at [clock seconds]
            }
            ::tsv::keylset tclwire connections $connection_key $connection_d
        }
        return $connection_key
    }

    proc record_connection_closed {connection_key {fields {}}} {
        initialize
        validate_connection_update $fields
        set now [clock seconds]
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire connections $connection_key connection_d]} {
                error "Connection $connection_key record doesn't exist"
            }
            foreach {field value} $fields {
                dict set connection_d $field $value
            }
            if {![dict exists $fields status]} {
                dict set connection_d status closed
            }
            if {![dict exists $fields closed_at] ||
                    [dict get $connection_d closed_at] eq {}} {
                dict set connection_d closed_at $now
            }
            if {![dict exists $fields last_activity_at]} {
                dict set connection_d last_activity_at $now
            }
            ::tsv::keyldel tclwire connections $connection_key
            return $connection_d
        }
    }

    proc remove_connection {connection_key} {
        initialize
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire connections $connection_key connection_d]} {
                error "Connection $connection_key record doesn't exist"
            }
            ::tsv::keyldel tclwire connections $connection_key
        }
        return
    }

    proc get_connection_record {connection_key} {
        initialize
        ::tsv::lock tclwire {
            if {![::tsv::keylget tclwire connections $connection_key connection_d]} {
                error "Connection $connection_key record doesn't exist"
            }
            return $connection_d
        }
    }

    proc get_connections_database {} {
        initialize
        ::tsv::lock tclwire {
            set connections_d [dict create]
            foreach connection_key [::tsv::keylkeys tclwire connections] {
                dict set connections_d $connection_key \
                    [::tsv::keylget tclwire connections $connection_key]
            }
        }
        return $connections_d
    }

    proc per_status_lists {} {
        variable valid_thread_statuses
        set per_status_db [dict create created {} allocated {} idle {} running {} terminating {}]

        dict for {tid th_d} [get_threads_database] {
            dict with th_d {
                if {$status ni $valid_thread_statuses} {
                    error "Thread $tid account has unknown status '$status'"
                }
                dict lappend per_status_db $status $tid
            }
        }
        return $per_status_db
    }

    set ns_commands [lmap c [info commands [namespace current]::*] {
        set c [namespace tail $c]
        if {[regexp {[A-Z].*} $c]} {
            continue
        } else {
            set c
        }}
    ]

    namespace export {*}$ns_commands
    namespace ensemble create

    unset ns_commands
    unset c
}

::tclwire::accounting initialize

package provide tclwire::accounting 1.2
