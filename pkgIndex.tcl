package ifneeded tclwire::threadpool 2.0 {
    set dir [file join [pwd] testservers]
    source [file join $dir threads_shared_db.tcl]
    source [file join $dir logger.tcl]
    source [file join $dir thread_master.tcl]
}
