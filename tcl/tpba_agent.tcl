# tpba_agent.tcl --
#
# Runtime loaded only inside the Thread-Pool Broker Agent thread.

namespace eval ::tclwire {}

namespace eval ::tclwire::tpba {
    variable broker {}

    proc agent_initialize {} {
        variable broker

        if {$broker ne {}} {
            error "TPBA agent is already initialized"
        }

        set broker [::tclwire::TPBA new]
        return [::thread::id]
    }

    proc agent_execute_command {command} {
        variable broker

        if {$broker eq {}} {
            error "TPBA agent is not initialized"
        }
        return [$broker execute_command $command]
    }

    proc agent_shutdown {} {
        variable broker

        if {$broker ne {}} {
            catch {$broker destroy}
            set broker {}
        }
        after 0 [list ::thread::release [::thread::id]]
        return
    }
}
