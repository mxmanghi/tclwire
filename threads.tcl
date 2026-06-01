lappend auto_path testservers/
package require tclwire::threadpool
source testservers/thread_base.tcl

set tm [::tclwire::ThreadMaster new $thread_script]

