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
    variable initialized 0
    variable pool_key {}
    variable application_class {}
    variable application_descriptor {}
    variable application {}
    variable configuration {}

    proc initialize {worker_pool_key serialized_configuration} {
        variable initialized
        variable pool_key
        variable application_class
        variable application_descriptor
        variable application
        variable configuration

        set worker_pool_key [string trim $worker_pool_key]
        if {$worker_pool_key eq {}} {
            error "content generator worker pool key must not be empty"
        }

        if {$initialized} {
            shutdown
        }

        # A CGA worker belongs to one application pool.  The immutable
        # application configuration is therefore worker initialization state,
        # not request payload.  Runtime reconfiguration should replace pools
        # and retire their workers instead of sending a different application
        # configuration with each request.

        set configuration [::tclwire::ApplicationConfiguration deserialize $serialized_configuration]
        set pool_key $worker_pool_key
        set application_class [$configuration class]
        set application_descriptor [$configuration snapshot]
        dict set application_descriptor application_id [$configuration id]
        if {[info commands $application_class] eq {} ||
           ![info object isa class $application_class]} {
            error "application command is not a TclOO class: $application_class"
        }

        try {
            set application [$application_class new $application_descriptor]
            $application initialize
        } on error {message options} {
            if {$application ne {}} {
                catch {$application destroy}
            }
            if {$configuration ne {}} {
                catch {$configuration destroy}
            }
            set pool_key {}
            set application_class {}
            set application_descriptor {}
            set application {}
            set configuration {}
            return -options $options $message
        }
        set initialized 1
        return
    }

    proc ensure_initialized {} {
        variable initialized
        variable configuration

        if {$initialized && $configuration ne {}} {
            return
        }
        error "content generator worker is not initialized"
    }

    proc shutdown {} {
        variable initialized
        variable pool_key
        variable application_class
        variable application_descriptor
        variable application
        variable configuration

        if {$application ne {}} {
            catch {$application shutdown}
            catch {$application destroy}
        }
        if {$configuration ne {}} {
            catch {$configuration destroy}
        }
        set initialized 0
        set pool_key {}
        set application_class {}
        set application_descriptor {}
        set application {}
        set configuration {}
        return
    }

    proc cleanup_uploaded_files {configuration request_descriptor} {
        if {[$configuration retain_uploaded_files]} {
            return
        }
        if {[dict exists $request_descriptor body_storage] &&
                [dict get $request_descriptor body_storage] eq "spooled_file" &&
                [dict exists $request_descriptor body_path]} {
            set path [dict get $request_descriptor body_path]
            if {[catch {file delete $path} message options] && [file exists $path]} {
                catch {::tclwire::logger log_error upload_cleanup \
                    "path=$path error=$message" warn}
            }
        }
        set failures {}
        if {[dict exists $request_descriptor multipart_parts]} {
            set failures [::tclwire::http::multipart cleanup_files \
                [dict get $request_descriptor multipart_parts]]
        }
        foreach failure $failures {
            set details [join [list "path=[::tclwire::logger::log_value [dict get $failure path]]" \
                                    "error=[::tclwire::logger::log_value [dict get $failure message]]"] " "]
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

        namespace eval ::tclwire::app [list source $application_file]
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

    proc signal {args} {
        variable application

        ensure_initialized
        return [$application signal {*}$args]
    }

    proc begin_request_ambient {request_descriptor} {
        ::tclwire::io begin [dict get $request_descriptor connection_thread_id] \
                            [dict get $request_descriptor connection_agent_id]  \
                            [dict get $request_descriptor transaction_id]
        ::tclwire::tools::begin $request_descriptor
        return
    }

    proc end_request_ambient {} {
        catch {::tclwire::tools::end}
        catch {::tclwire::io end}
        return
    }

    proc process_request {request_descriptor} {
        variable application

        set request [::tclwire::HttpRequest new $request_descriptor]
        try {
            $application handle_request $request
            if {[::tclwire::io::accepting_output]} {
                ::tclwire::io complete
            }
        } finally {
            $request destroy
        }
        return
    }

    proc execute {request_descriptor} {
        variable initialized
        variable pool_key
        variable application_class
        variable configuration

        ensure_initialized

        set worker_id [::thread::id]
        ::tclwire::accounting change_thread_status $worker_id running \
                [list $application_class [dict get $request_descriptor transaction_id]]

        try {

            # Establish the error-reporting path before any application-owned
            # request-handling code can fail.
            begin_request_ambient $request_descriptor
            process_request $request_descriptor

        } on error {message options} {
            log_application_error $request_descriptor $message $options
            catch {::tclwire::io fail $message}
        } finally {
            end_request_ambient
            cleanup_uploaded_files $configuration $request_descriptor
            catch {
                ::tclwire::tpba notify_workload_transition \
                    $pool_key request-processed
            }
        }
        return
    }
}

package provide tclwire::content_generator_agent 0.1
