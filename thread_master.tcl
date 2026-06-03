# -- thread_master.tcl -- Implementation of thread pool manager
#
# Thread pool manager for TclWire services.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.
#
#

package require TclOO
package require Thread

catch {::tclwire::ThreadMaster destroy }
#source [file join [file dirname [file normalize [info script]]] threads_shared_db.tcl]
#source [file join [file dirname [file normalize [info script]]] logger.tcl]

namespace eval ::tclwire {}

# Default stale-thread predicate.
#
# Call signature:
#   {*}$predicate thread_id thread_account now
#
# thread_id is the Tcl thread id, thread_account is the accounting dictionary,
# and now is the current epoch timestamp in seconds.
if {[info commands ::tclwire::is_stale] eq {}} {
    proc ::tclwire::is_stale {thread_id thread_account now} {
        if {![dict exists $thread_account status] || [dict get $thread_account status] ne "idle"} {
            return false
        }

        if {[dict exists $thread_account nruns] && [dict get $thread_account nruns] > 10} {
            return true
        }

        if {![dict exists $thread_account last_run_end]} {
            return false
        }

        set last_run_end [dict get $thread_account last_run_end]
        if {$last_run_end <= 0} {
            return false
        }

        return [expr {($now - $last_run_end) > 60}]
    }
}

::oo::class create ::tclwire::ThreadMaster {
    variable max_threads_number
    variable accounting
    variable thread_script
    variable logger
    variable owned_threads

    # Boundary rule:
    # ::tclwire::accounting is the shared ledger visible to workers and
    # inspectors. ThreadMaster owns pool policy and lifecycle transitions.

    method accounting_snapshot {} {
        set snapshot [dict create]
        foreach thread_id [[self] thread_ids all] {
            set thread_account [$accounting get_thread_account $thread_id]
            if {$thread_account ne {}} {
                dict set snapshot $thread_id $thread_account
            }
        }
        return $snapshot
    }

    method per_status_lists {} {
        set per_status_db [dict create created {} allocated {} idle {} running {} terminating {}]
        dict for {thread_id thread_account} [[self] accounting_snapshot] {
            set status [dict get $thread_account status]
            if {![dict exists $per_status_db $status]} {
                dict set per_status_db $status {}
            }
            dict lappend per_status_db $status $thread_id
        }
        return $per_status_db
    }

    method thread_ids {{filter all}} {
        set live_thread_ids {}
        set retained_thread_ids {}
        foreach thread_id $owned_threads {
            set thread_account [$accounting get_thread_account $thread_id]
            if {$thread_account eq {}} {
                continue
            }
            lappend retained_thread_ids $thread_id
            if {$filter eq "all" || [dict get $thread_account status] eq $filter} {
                lappend live_thread_ids $thread_id
            }
        }
        set owned_threads $retained_thread_ids
        return $live_thread_ids
    }

    method owns_thread {thread_id} {
        return [expr {[lsearch -exact [[self] thread_ids all] $thread_id] >= 0}]
    }

    method allocate_owned_idle_thread {thread_id_v} {
        upvar 1 $thread_id_v thread_id

        foreach candidate [[self] thread_ids idle] {
            if {[catch {$accounting change_thread_status $candidate allocated}]} {
                continue
            }
            set thread_id $candidate
            return true
        }
        return false
    }

    method all_accounting_thread_ids {{filter all}} {
        if {$filter eq "all"} {
            return [dict keys [$accounting get_threads_database]]
        }

        set per_status_lists [$accounting per_status_lists]
        if {[dict exists $per_status_lists $filter]} {
            return [dict get $per_status_lists $filter]
        }
        return {}
    }

    method live_threads_number {} {
        return [dict size [[self] accounting_snapshot]]
    }

    method thread_account {thread_id} {
        return [$accounting get_thread_account $thread_id]
    }

    method thread_status {thread_id} {
        set thread_account [[self] thread_account $thread_id]
        if {$thread_account eq {}} {
            return ""
        }
        return [dict get $thread_account status]
    }

    method stats {} {
        return [dict create \
            max_threads_number $max_threads_number \
            live_threads_number [[self] live_threads_number] \
            per_status_lists [[self] per_status_lists]]
    }

    method resize {new_max_threads_number} {
        if {![string is integer -strict $new_max_threads_number] || $new_max_threads_number < 1} {
            error "maximum thread number must be a positive integer"
        }
        set max_threads_number $new_max_threads_number
        return $max_threads_number
    }

    constructor {tscript {mtn 100}} {
        set max_threads_number $mtn
        set accounting ::tclwire::accounting
        set thread_script $tscript
        set logger [::tclwire::logger new]
        set owned_threads {}
    }

    destructor {
        $logger destroy
    }

    # -- start_worker_thread <thread-script>
    #
    # Central method for starting new threads executing the 
    # script stored in the procedure only argument
    # 
    # Returns: thread_id
    #

    method start_worker_thread {thread_script} {

        set thread_id [thread::create $thread_script]
        thread::preserve $thread_id

        # we allow worker->master thread communication through the ::thread::send
        ::thread::send -async $thread_id [list set ::master_thread_id [::thread::id]]
        return $thread_id

    }

    method allocate_thread {thread_id_v} {
        upvar 1 $thread_id_v thread_id

        if {[[self] allocate_owned_idle_thread thread_id]} {
            return true
        }
        ::tsv::lock tclwire {
            set live_threads_number 0
            set retained_thread_ids {}
            foreach owned_thread_id $owned_threads {
                if {![::tsv::keylget tclwire accounting $owned_thread_id thread_account]} {
                    continue
                }
                lappend retained_thread_ids $owned_thread_id
                incr live_threads_number
            }
            set owned_threads $retained_thread_ids

            if {$live_threads_number < $max_threads_number} {
                set thread_id [[self] start_worker_thread $thread_script]
                lappend owned_threads $thread_id
                ::tsv::keylset tclwire accounting $thread_id [$accounting new_thread_account allocated]
                return true
            } 
        }
        return false
    }

    method acquire_worker {} {
        set thread_id ""
        if {![[self] allocate_thread thread_id]} {
            return ""
        }
        return $thread_id
    }

    method return_thread {thread_id} {
        if {![[self] owns_thread $thread_id]} {
            error "Thread $thread_id is not owned by this ThreadMaster"
        }
        set status [[self] thread_status $thread_id]
        switch -exact -- $status {
            allocated -
            created {
                $accounting change_thread_status $thread_id idle
                return true
            }
            idle {
                return true
            }
            "" {
                error "Thread $thread_id is not in the pool"
            }
            default {
                error "Thread $thread_id cannot be returned from status '$status'"
            }
        }
    }

    method worker_ready {thread_id} {
        if {![[self] owns_thread $thread_id]} {
            error "Thread $thread_id is not owned by this ThreadMaster"
        }
        $accounting change_thread_status $thread_id idle
    }

    method run_on_thread {thread_id cmd} {
        if {![[self] owns_thread $thread_id]} {
            error "Thread $thread_id is not owned by this ThreadMaster"
        }
        set status [[self] thread_status $thread_id]
        if {$status eq {}} {
            error "Thread $thread_id is not in the pool"
        }
        if {$status ni {allocated idle}} {
            error "Thread $thread_id is not available: status is '$status'"
        }

        $accounting change_thread_status $thread_id allocated
        thread::send -async $thread_id $cmd
        return $thread_id
    }

    method submit {cmd {thread_id_v ""}} {
        set thread_id ""
        if {![[self] allocate_thread thread_id]} {
            return false
        }
        if {$thread_id_v ne ""} {
            upvar 1 $thread_id_v caller_thread_id
            set caller_thread_id $thread_id
        }
        [[self] run_on_thread $thread_id $cmd]
        return true
    }

    method stale_thread_ids {{is_stale_cmd ::tclwire::is_stale}} {
        set now [clock seconds]
        set stale_thread_ids {}
        dict for {thread_id thread_account} [[self] accounting_snapshot] {
            if {[{*}$is_stale_cmd $thread_id $thread_account $now]} {
                lappend stale_thread_ids $thread_id
            }
        }
        return $stale_thread_ids
    }

    method release_stale_threads {{is_stale_cmd ::tclwire::is_stale}} {
        set stale_thread_ids [[self] stale_thread_ids $is_stale_cmd]
        foreach thread_id $stale_thread_ids {
            $accounting change_thread_status $thread_id terminating
        }
        foreach thread_id $stale_thread_ids {
            thread::send -async $thread_id demand_thread_exit
        }
        return $stale_thread_ids
    }

    method broadcast {cmd {filter all}} {
        foreach tid [[self] thread_ids $filter] {
            thread::send -async $tid $cmd
        }
    }

    method stop_threads {{filter all}} {
        [self] broadcast demand_thread_exit $filter
    }

    method stop_thread {thread_id} {
        thread::send -async $thread_id demand_thread_exit
    }


}
package provide tclwire::threadpool 2.0
