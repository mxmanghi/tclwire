# content_generator_agent.tcl --
#
# Reusable Content Generator Agent worker entrypoint.

package require Thread
package require tclwire::accounting 1.2
package require tclwire::application::io 0.1
package require tclwire::application::tools 0.1
package require tclwire::http::request 0.1
package require tclwire::logger::client 0.1
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::cga {
    proc log_application_error {request_descriptor message options} {
        set context [dict create]
        if {[dict exists $request_descriptor application_id]} {
            dict set context application_id \
                [dict get $request_descriptor application_id]
        }
        if {[dict exists $request_descriptor headers host]} {
            dict set context host [dict get $request_descriptor headers host]
        }

        set fields {}
        foreach field {application_id transaction_id method path} {
            if {[dict exists $request_descriptor $field]} {
                lappend fields \
                    "$field=[::tclwire::logger::log_value \
                        [dict get $request_descriptor $field]]"
            }
        }
        lappend fields \
            "error=[::tclwire::logger::log_value $message]"
        foreach {option label} {-errorcode errorcode -errorinfo errorinfo} {
            if {[dict exists $options $option]} {
                lappend fields \
                    "$label=[::tclwire::logger::log_value \
                        [dict get $options $option]]"
            }
        }
        set details [join $fields " "]

        if {[catch {
            ::tclwire::logger log_error application $details error $context
        }]} {
            # Keep a last-resort diagnostic when the asynchronous logger is
            # unavailable during startup or shutdown.
            catch {puts stderr "application level=error $details"}
        }
        return
    }

    proc execute {
        pool_key application_class application_descriptor request_descriptor
    } {
        set worker_id [::thread::id]
        ::tclwire::accounting change_thread_status $worker_id running \
                [list $application_class [dict get $request_descriptor transaction_id]]

        set application {}
        set request {}
        try {
            set application [$application_class new $application_descriptor]
            ::tclwire::io begin \
                [dict get $request_descriptor connection_thread_id] \
                [dict get $request_descriptor connection_agent_id] \
                [dict get $request_descriptor transaction_id]
            ::tclwire::tools::begin $request_descriptor
            set request [::tclwire::HttpRequest new $request_descriptor]
            $application handle_request $request
            if {[::tclwire::io::accepting_output]} {
                ::tclwire::io complete
            }
        } on error {message options} {
            log_application_error $request_descriptor $message $options
            catch {::tclwire::io fail $message}
        } finally {
            ::tclwire::tools::end
            ::tclwire::io end
            if {$request ne {}} {
                catch {$request destroy}
            }
            if {$application ne {}} {
                catch {$application destroy}
            }
            catch {
                ::tclwire::tpba notify_workload_transition \
                    $pool_key request-processed
            }
        }
        return
    }
}

package provide tclwire::content_generator_agent 0.1
