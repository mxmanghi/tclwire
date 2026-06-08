package ifneeded tclwire::accounting 1.2 \
    [list source [file join $dir tcl threads_shared_db.tcl]]

package ifneeded tclwire::threadpool 2.0 "
    package require tclwire::accounting 1.2
    source [list [file join $dir logger.tcl]]
    source [list [file join $dir tcl thread_master.tcl]]
"

package ifneeded tclwire::tpba 0.1 "
    package require tclwire::threadpool 2.0
    source [list [file join $dir tcl tpba.tcl]]
"
