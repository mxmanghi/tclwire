# shared_state.tcl --
#
# Idempotent initializer for TclWire shared thread state.

package require Thread

namespace eval ::tclwire::shared_state {
    variable catalog_keys {
        timestamp
        accounting
        connections
        debug_connection
        tpba_thread_id
        logger_thread_id
        logger_levels
    }

    proc initialize {} {
        variable catalog_keys
        ::tsv::lock tclwire {
            foreach key $catalog_keys {
                if {![::tsv::exists tclwire $key]} {
                    ::tsv::set tclwire $key {}
                }
            }
            if {[::tsv::get tclwire debug_connection] eq {}} {
                ::tsv::set tclwire debug_connection 0
            }
        }
        return
    }

    proc is_initialized {} {
        variable catalog_keys
        ::tsv::lock tclwire {
            foreach key $catalog_keys {
                if {![::tsv::exists tclwire $key]} {
                    return 0
                }
            }
        }
        return 1
    }

    proc reset {} {
        variable catalog_keys
        ::tsv::lock tclwire {
            foreach key $catalog_keys {
                if {$key eq "debug_connection"} {
                    ::tsv::set tclwire $key 0
                } else {
                    ::tsv::set tclwire $key {}
                }
            }
        }
        return
    }

    namespace export initialize is_initialized reset
    namespace ensemble create
}

::tclwire::shared_state initialize

package provide tclwire::shared_state 0.1
