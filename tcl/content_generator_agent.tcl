# content_generator_agent.tcl --
#
# Reusable Content Generator Agent worker entrypoint.

package require Thread
package require tclwire::accounting 1.2
package require tclwire::application::io 0.1
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::cga {
    proc execute {pool_key application_class request_descriptor} {
        set worker_id [::thread::id]
        ::tclwire::accounting change_thread_status \
            $worker_id running [list $application_class \
                [dict get $request_descriptor transaction_id]]

        set application {}
        try {
            set application [$application_class new]
            ::tclwire::io begin \
                [dict get $request_descriptor connection_thread_id] \
                [dict get $request_descriptor connection_agent_id] \
                [dict get $request_descriptor transaction_id]
            $application handle_request $request_descriptor
            ::tclwire::io complete
        } on error {message options} {
            catch {::tclwire::io fail $message}
        } finally {
            ::tclwire::io end
            if {$application ne {}} {
                catch {$application destroy}
            }
            catch {::tclwire::tpba request [dict create \
                operation release_worker \
                pool_key $pool_key \
                worker_id $worker_id]}
        }
        return
    }
}

package provide tclwire::content_generator_agent 0.1
