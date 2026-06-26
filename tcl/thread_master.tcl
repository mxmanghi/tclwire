# -- thread_master.tcl -- Implementation of a thread pool manager
#
# Thread pool manager for TclWire services.
#
# Copyright (c) 2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.
#

package require TclOO
package require Thread
package require tclwire::accounting 1.2

namespace eval ::tclwire {}

::oo::class create ::tclwire::PlainMetric {
    method configure_metric_options {options} {
        return $options
    }

    method combined_workload {running_workload cumulative_workload options} {
        return $cumulative_workload
    }

    method thread_workload_changed {thread_id transition_id} {
        set record [my workload_record_for $thread_id]
        switch -exact -- $transition_id {
            thread-start {
            }
            request-processed {
                dict incr record cumulative_workload
                dict set record running_workload 0
                catch {my return_thread $thread_id}
            }
            thread-exit {
                my unmark_thread_eligible $thread_id
            }
            default {
                error "unknown plain workload transition: $transition_id"
            }
        }
        return [my store_workload_record $thread_id $record]
    }

    method thread_eligible_for_workload {thread_id record status} {
        return [expr {$status eq "idle"}]
    }
}

::oo::class create ::tclwire::ConcurrentConnectionMetric {
    variable metric_options
    variable connection_reservations

    method configure_metric_options {options} {
        set connection_reservations [dict create]
        set options [dict merge [dict create max_conn_per_thread 5] $options]
        set max_conn_per_thread [dict get $options max_conn_per_thread]
        if {![string is integer -strict $max_conn_per_thread] ||
                $max_conn_per_thread < 1} {
            error "max_conn_per_thread must be an integer greater than or equal to 1"
        }
        return $options
    }

    method combined_workload {running_workload cumulative_workload options} {
        set max_conn_per_thread [dict get $options max_conn_per_thread]
        return [expr {$max_conn_per_thread * $running_workload + $cumulative_workload}]
    }

    method thread_workload_changed {thread_id transition_id} {
        set record [my workload_record_for $thread_id]
        switch -exact -- $transition_id {
            thread-start {
            }
            new-connection-processing {
                dict incr record running_workload
                dict incr record cumulative_workload
                dict incr connection_reservations $thread_id
                my unmark_thread_eligible $thread_id
            }
            connection-open {
                if {[dict exists $connection_reservations $thread_id] &&
                        [dict get $connection_reservations $thread_id] > 0} {
                    dict incr connection_reservations $thread_id -1
                    if {[dict get $connection_reservations $thread_id] == 0} {
                        dict unset connection_reservations $thread_id
                    }
                } else {
                    dict incr record running_workload
                    dict incr record cumulative_workload
                }
                my unmark_thread_eligible $thread_id
            }
            connection-closed {
                if {[dict exists $connection_reservations $thread_id] &&
                        [dict get $connection_reservations $thread_id] > 0} {
                    dict incr connection_reservations $thread_id -1
                    if {[dict get $connection_reservations $thread_id] == 0} {
                        dict unset connection_reservations $thread_id
                    }
                }
                set running_workload [dict get $record running_workload]
                if {$running_workload > 0} {
                    dict set record running_workload [expr {$running_workload - 1}]
                }
                if {[dict get $record running_workload] == 0} {
                    catch {my return_thread $thread_id}
                }
            }
            idle-connection-agent {
                dict set record running_workload 0
                catch {my return_thread $thread_id}
            }
            thread-exit {
                my unmark_thread_eligible $thread_id
            }
            default {
                error "unknown connection workload transition: $transition_id"
            }
        }
        return [my store_workload_record $thread_id $record]
    }

    method thread_eligible_for_workload {thread_id record status} {
        if {$status ni {idle running}} {
            return false
        }
        set running_workload [dict get $record running_workload]
        set max_conn_per_thread [dict get $metric_options max_conn_per_thread]
        return [expr {$running_workload < $max_conn_per_thread}]
    }
}

::oo::class create ::tclwire::ThreadMaster {
    variable max_threads_number
    variable accounting
    variable thread_script
    variable thread_family
    variable owned_threads
    variable metric_options
    variable workload_db
    variable eligible_threads_list

    constructor {tscript {mtn 100} {family {}}} {
        set max_threads_number $mtn
        set accounting ::tclwire::accounting
        $accounting initialize
        set thread_script $tscript
        set thread_family [string tolower [string trim $family]]
        set owned_threads {}
        set metric_options [dict create]
        set workload_db [dict create]
        set eligible_threads_list {}
    }

    # Boundary rule:
    # ::tclwire::accounting is the shared ledger visible to workers and
    # inspectors. ThreadMaster owns pool policy and lifecycle transitions.

    method accounting_snapshot {} {
        set snapshot [dict create]
        foreach thread_id [[self] thread_ids all] {
            set thread_account [$accounting get_thread_account $thread_id]
            dict set snapshot $thread_id $thread_account
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
            if {[catch {$accounting get_thread_account $thread_id} thread_account]} {
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
        return [expr {[lsearch -exact $owned_threads $thread_id] >= 0}]
    }

    method remove_thread {thread_id} {
        set index [lsearch -exact $owned_threads $thread_id]
        if {$index < 0} {
            error "Thread $thread_id is not owned by this ThreadMaster"
        }
        set owned_threads [lreplace $owned_threads $index $index]
        if {[dict exists $workload_db $thread_id]} {
            dict unset workload_db $thread_id
        }
        my unmark_thread_eligible $thread_id
        return true
    }

    method configure_metric {metric_class options} {
        ::oo::objdefine [self] mixin $metric_class
        set metric_options [my configure_metric_options $options]
        return $metric_class
    }

    method configure_metric_options {options} {
        return $options
    }

    method combined_workload {running_workload cumulative_workload options} {
        return [expr {$running_workload + $cumulative_workload}]
    }

    method thread_eligible_for_workload {thread_id record status} {
        return [expr {$status eq "idle"}]
    }

    method thread_workload_changed {thread_id transition_id} {
        switch -exact -- $transition_id {
            thread-start -
            thread-exit {
                set record [my workload_record_for $thread_id]
                return [my store_workload_record $thread_id $record]
            }
            default {
                error "unknown workload transition: $transition_id"
            }
        }
    }

    method workload_index {record} {
        if {[dict exists $record running_workload]} {
            set running_workload [dict get $record running_workload]
        } else {
            set running_workload 0
        }
        if {[dict exists $record cumulative_workload]} {
            set cumulative_workload [dict get $record cumulative_workload]
        } else {
            set cumulative_workload 0
        }
        return [my combined_workload $running_workload $cumulative_workload $metric_options]
    }

    method workload_record {thread_id running_workload cumulative_workload} {
        set record [dict create \
            thread_id $thread_id \
            running_workload $running_workload \
            cumulative_workload $cumulative_workload]
        dict set record combined_workload [my workload_index $record]
        return $record
    }

    method workload_record_for {thread_id} {
        if {[dict exists $workload_db $thread_id]} {
            return [dict get $workload_db $thread_id]
        }
        return [my workload_record $thread_id 0 0]
    }

    method store_workload_record {thread_id record} {
        set running_workload [dict get $record running_workload]
        set cumulative_workload [dict get $record cumulative_workload]
        set record [my workload_record $thread_id $running_workload $cumulative_workload]
        dict set workload_db $thread_id $record

        set up_to_date_rec [dict filter $record key running_workload cumulative_workload combined_workload]
        $accounting update_thread_workload $thread_id $up_to_date_rec

        set status [my thread_status $thread_id]
        if {[my thread_eligible_for_workload $thread_id $record $status]} {
            my mark_thread_eligible $thread_id
        } else {
            my unmark_thread_eligible $thread_id
        }
        return $record

    }

    method candidate_workload {thread_id} {
        if {[dict exists $workload_db $thread_id]} {
            set record [dict get $workload_db $thread_id]
            if {[dict exists $record combined_workload]} {
                return [dict get $record combined_workload]
            }
            return [my workload_index $record]
        }
        return [my workload_index [dict create \
            thread_id $thread_id \
            running_workload 0 \
            cumulative_workload 0]]
    }

    method mark_thread_eligible {thread_id} {
        if {[lsearch -exact $eligible_threads_list $thread_id] < 0} {
            lappend eligible_threads_list $thread_id
        }
        return $eligible_threads_list
    }

    method unmark_thread_eligible {thread_id} {
        set index [lsearch -exact $eligible_threads_list $thread_id]
        if {$index >= 0} {
            set eligible_threads_list \
                [lreplace $eligible_threads_list $index $index]
        }
        return $eligible_threads_list
    }

    method eligible_thread_ids {} {
        set retained {}
        foreach thread_id $eligible_threads_list {
            if {![[self] owns_thread $thread_id]} {
                continue
            }
            if {[catch {my thread_status $thread_id} status]} {
                continue
            }
            set record [my workload_record_for $thread_id]
            if {[my thread_eligible_for_workload $thread_id $record $status]} {
                lappend retained $thread_id
            }
        }
        set eligible_threads_list $retained
        return $eligible_threads_list
    }

    method allocate_owned_idle_thread {thread_id_v} {
        upvar 1 $thread_id_v thread_id

        set selected {}
        set selected_workload {}
        set candidates [my eligible_thread_ids]
        foreach status {idle running} {
            foreach candidate [[self] thread_ids $status] {
                set record [my workload_record_for $candidate]
                if {[my thread_eligible_for_workload $candidate $record $status] &&
                        $candidate ni $candidates} {
                    lappend candidates $candidate
                }
            }
        }
        foreach candidate $candidates {
            set candidate_workload [my candidate_workload $candidate]
            if {$selected eq {} ||
                    $candidate_workload < $selected_workload ||
                    ($candidate_workload == $selected_workload &&
                        [string compare $candidate $selected] < 0)} {
                set selected $candidate
                set selected_workload $candidate_workload
            }
        }
        if {$selected ne {}} {
            my unmark_thread_eligible $selected
            $accounting change_thread_status $selected allocated
            set thread_id $selected
            return true
        }
        return false
    }

    method live_threads_number {} {
        return [dict size [[self] accounting_snapshot]]
    }

    method thread_account {thread_id} {
        return [$accounting get_thread_account $thread_id]
    }

    method thread_status {thread_id} {
        set thread_account [[self] thread_account $thread_id]
        return [dict get $thread_account status]
    }

    method stats {} {
        return [dict create \
            max_threads_number $max_threads_number \
            live_threads_number [[self] live_threads_number] \
            per_status_lists [[self] per_status_lists] \
            workloads $workload_db \
            eligible_threads_list [my eligible_thread_ids]]
    }

    method resize {new_max_threads_number} {
        if {![string is integer -strict $new_max_threads_number] || $new_max_threads_number < 1} {
            error "maximum thread number must be a positive integer"
        }
        set max_threads_number $new_max_threads_number
        return $max_threads_number
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
        if {[catch {
            $accounting register_thread $thread_id allocated $thread_family
            my store_workload_record $thread_id [my workload_record $thread_id 0 0]
            my thread_workload_changed $thread_id thread-start
        } error options]} {
            catch {thread::release $thread_id}
            return -options $options $error
        }

        # we allow worker->master thread communication through the ::thread::send
        ::thread::send -async $thread_id [list set ::master_thread_id [::thread::id]]
        return $thread_id

    }

    method allocate_thread {thread_id_v} {
        upvar 1 $thread_id_v thread_id

        if {[[self] allocate_owned_idle_thread thread_id]} {
            return true
        }

        set live_threads_number [[self] live_threads_number]
        if {$live_threads_number < $max_threads_number} {
            set thread_id [[self] start_worker_thread $thread_script]
            lappend owned_threads $thread_id
            return true
        }
        return false
    }

    method acquire_worker {} {
        set thread_id ""
        if {![[self] allocate_thread thread_id]} { return "" }
        return $thread_id
    }

    method return_thread {thread_id} {
        if {![[self] owns_thread $thread_id]} {
            error "Thread $thread_id is not owned by this ThreadMaster"
        }
        set status [[self] thread_status $thread_id]
        switch -exact -- $status {
            allocated -
            created -
            running {
                $accounting change_thread_status $thread_id idle
                my mark_thread_eligible $thread_id
                return true
            }
            idle {
                my mark_thread_eligible $thread_id
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

    method stop_threads {{filter all}} {
        foreach tid [[self] thread_ids $filter] {
            thread::send -async $tid demand_thread_exit
        }
    }


}
package provide tclwire::threadpool 2.0
