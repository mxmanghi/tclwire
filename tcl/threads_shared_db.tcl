# -- threads_accounting_db.tcl
#
# Shared thread accounting space. ThreadMaster owns pool policy; this namespace
# provides the shared ledger used by ThreadMaster, workers and inspectors.
#
# the accounting database is named `tclwire`
#
#  sections:
#
#   - timestamp: timestamp stored when accounting space is instantiated
#   - accounting <thread-id> <thread accounting>
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
#	- http_host: current or most recently observed Host header for HTTP workers
#

package require Thread

namespace eval ::tclwire::accounting {
    variable valid_thread_statuses {created allocated idle running terminating}

    proc initialize {} {
        ::tsv::lock tclwire {
            if {![::tsv::exists tclwire timestamp]} {
                ::tsv::set tclwire timestamp [clock format [clock seconds]]
            }
            if {![::tsv::exists tclwire accounting]} {
                ::tsv::set tclwire accounting {}
            }
        }
        return
    }

    proc is_initialized {} {
        ::tsv::lock tclwire {
            return [expr {
                [::tsv::exists tclwire timestamp] &&
                [::tsv::exists tclwire accounting]
            }]
        }
    }

    proc reset {} {
        ::tsv::lock tclwire {
            ::tsv::set tclwire timestamp [clock format [clock seconds]]
            ::tsv::set tclwire accounting {}
        }
        return
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
        set account [dict create \
            nruns 0 \
            last_run_start 0 \
            last_run_end 0 \
            created_on [clock seconds] \
            command {} \
            status $status \
            family $family]
        if {$family eq "http"} {
            dict set account http_host $http_host
        }
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
            if {![dict exists $thread_d family] || [dict get $thread_d family] ne "http"} {
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
            if {[::tsv::keylget tclwire accounting $tid thread_d]} {
                ::tsv::keyldel tclwire accounting $tid
            }
        }
    }

    proc get_thread_account {tid} {
        initialize
        ::tsv::lock tclwire {
            if {[::tsv::keylget tclwire accounting $tid thread_d]} {
                return $thread_d
            }
        }
        return ""
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

    proc per_status_lists {} {
        variable valid_thread_statuses
        set per_status_db [dict create created {} allocated {} idle {} running {} terminating {}]

        dict for {tid th_d} [get_threads_database] {
            dict with th_d {
                if {$status ni $valid_thread_statuses} {
                    dict lappend per_status_db unknown $tid
                    continue
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
