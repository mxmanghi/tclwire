# -- thread_master.tcl -- Implementation of thread pool manager
#
# Implementation of the HTTP server support used by the TclCurl extension.
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

    # Boundary rule:
    # ::tclwire::accounting is the shared ledger visible to workers and
    # inspectors. ThreadMaster owns pool policy and lifecycle transitions.

    method accounting_snapshot {} {
        return [$accounting get_threads_database]
    }

    method per_status_lists {} {
        return [$accounting per_status_lists]
    }

    method thread_ids {{filter all}} {
        if {$filter eq "all"} {
            return [dict keys [[self] accounting_snapshot]]
        }

        set per_status_lists [[self] per_status_lists]
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

    method start_worker_thread {} {

        set thread_id [thread::create $thread_script]
        thread::preserve $thread_id

        # we allow worker->master thread communication through the ::thread::send
        ::thread::send -async $thread_id [list set ::master_thread_id [::thread::id]]
        return $thread_id

    }

    method allocate_thread {thread_id_v} {
        upvar 1 $thread_id_v thread_id

        set thread_id [$accounting allocate_idle_thread]
        if {$thread_id != ""} { return true }
        ::tsv::lock tclwire {
            set live_threads_number 0
            if {[::tsv::exists tclwire accounting]} {
                set live_threads_number [llength [::tsv::keylkeys tclwire accounting]]
            }
            if {$live_threads_number < $max_threads_number} { 
                set thread_id [[self] start_worker_thread]
                ::tsv::keylset tclwire accounting $thread_id [$accounting new_thread_account allocated]
                return true
            } 
        }
        return false
    }

    method return_thread {thread_id} {
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
        $accounting change_thread_status $thread_id idle
    }

    method run_on_thread {thread_id cmd} {
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
