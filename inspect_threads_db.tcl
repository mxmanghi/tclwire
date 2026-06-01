# -- inspect_threads_db.tcl -- Report the shared thread accounting database
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.
#

package require Thread
package require report
package require struct::matrix

source [file join [file dirname [file normalize [info script]]] threads_shared_db.tcl]

namespace eval ::tclwire::inspect_threads_db {

    proc timestamp {seconds} {
        if {$seconds eq "" || $seconds == 0} {
            return ""
        }
        return [clock format $seconds -format %T]
    }

    proc accounting_field {thread_d field} {
        if {[dict exists $thread_d $field]} {
            return [dict get $thread_d $field]
        }
        return ""
    }

    proc format_report {} {
        set matrix [::struct::matrix]
        $matrix add columns 8
        $matrix add row [list # thread_id nruns last_run_start last_run_end created_on status command]

        set row_number 0
        dict for {tid thread_d} [lsort -dictionary -stride 2 [::tclwire::accounting get_threads_database]] {
            incr row_number
            $matrix add row [list \
                $row_number \
                $tid \
                [accounting_field $thread_d nruns] \
                [timestamp [accounting_field $thread_d last_run_start]] \
                [timestamp [accounting_field $thread_d last_run_end]] \
                [timestamp [accounting_field $thread_d created_on]] \
                [accounting_field $thread_d status] \
                [accounting_field $thread_d command]]
        }

        catch {::report::rmstyle tclwire_threads_table}
        ::report::defstyle tclwire_threads_table {} {
            data       set [split "[string repeat "| " [columns]]|"]
            topdata    set [data get]
            top        set [split "[string repeat "+ - " [columns]]+"]
            bottom     set [top get]
            topcapsep  set [top get]
            top        enable
            bottom     enable
            topcapsep  enable
            tcaption   1

            justify 0 right
            pad 0 both
            for {set i 1} {$i < [columns]} {incr i} {
                justify $i left
                pad $i both
            }
        }

        set report [::report::report tclwire_threads_report [$matrix columns] style tclwire_threads_table]
        set output [$matrix format 2string $report]
        $report destroy
        $matrix destroy

        return $output
    }

    namespace export format_report
    namespace ensemble create
}

if {[file normalize $argv0] eq [file normalize [info script]]} {
    puts [::tclwire::inspect_threads_db format_report]
}
