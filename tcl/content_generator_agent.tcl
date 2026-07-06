# content_generator_agent.tcl --
#
# Reusable Content Generator Agent worker entrypoint.

package require Thread
package require tclwire::accounting 1.2
package require tclwire::application_configuration 0.1
package require tclwire::application::io 0.1
package require tclwire::application::tools 0.1
package require tclwire::http::request 0.1
package require tclwire::logger::client 0.1
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

namespace eval ::tclwire::cga {
    proc cleanup_uploaded_files {configuration request_descriptor} {
        if {[$configuration retain_uploaded_files]} {
            return
        }
        if {![dict exists $request_descriptor multipart_parts]} {
            return
        }

        set failures [::tclwire::http::multipart cleanup_files \
            [dict get $request_descriptor multipart_parts]]
        foreach failure $failures {
            set details [join [list \
                "path=[::tclwire::logger::log_value \
                    [dict get $failure path]]" \
                "error=[::tclwire::logger::log_value \
                    [dict get $failure message]]"] " "]
            if {[catch {
                ::tclwire::logger log_error upload_cleanup $details warn
            }]} {
                catch {puts stderr "upload_cleanup level=warn $details"}
            }
        }
        return
    }

    proc reload_application_class {application_class configuration} {
        if {![$configuration reload_on_request]} {
            return
        }

        set application_file [$configuration file]
        if {[info commands $application_class] ne {}} {
            if {![info object isa class $application_class]} {
                error "application command is not a TclOO class: $application_class"
            }
            $application_class destroy
        }

        uplevel #0 [list source $application_file]
        if {![info object isa class $application_class]} {
            error "reloaded application file did not define class $application_class"
        }
        return
    }

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
        pool_key application_class serialized_configuration request_descriptor
    } {
        set worker_id [::thread::id]
        ::tclwire::accounting change_thread_status $worker_id running \
                [list $application_class [dict get $request_descriptor transaction_id]]

        set application {}
        set configuration {}
        set request {}
        try {
            # Establish the error-reporting path before any application-owned
            # configuration, reload, or constructor code can fail.
            ::tclwire::io begin \
                [dict get $request_descriptor connection_thread_id] \
                [dict get $request_descriptor connection_agent_id] \
                [dict get $request_descriptor transaction_id]
            set configuration \
                [::tclwire::ApplicationConfiguration deserialize \
                    $serialized_configuration]
            reload_application_class \
                $application_class $configuration
            set application_descriptor [$configuration snapshot]
            dict set application_descriptor application_id \
                [$configuration id]
            set application [$application_class new $application_descriptor]
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
            catch {::tclwire::tools::end}
            catch {::tclwire::io end}
            if {$request ne {}} {
                catch {$request destroy}
            }
            if {$application ne {}} {
                catch {$application destroy}
            }
            if {$configuration ne {}} {
                cleanup_uploaded_files $configuration $request_descriptor
                $configuration destroy
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
