lappend auto_path [pwd]
package require tclwire::threadpool
source thread_base.tcl

set tm [::tclwire::ThreadMaster new $thread_script]
