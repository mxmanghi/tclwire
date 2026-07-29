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
    variable configuration {}
    variable pending_pool_key {}
    variable pending_serialized_configuration {}
    variable initialization_error {}
    variable initialization_options {}

    proc install_configuration_envelope {worker_pool_key serialized_configuration} {
        variable pending_pool_key
        variable pending_serialized_configuration
        variable initialization_error
        variable initialization_options

        # Keep worker creation lightweight.  Some thread implementations do
        # not return from thread::create until the startup script reaches
        # thread::wait.  The worker script therefore installs the immutable
        # configuration envelope here and schedules object construction on the
        # worker event loop.  execute still receives only request data.
        set pending_pool_key $worker_pool_key
        set pending_serialized_configuration $serialized_configuration
        set initialization_error {}
        set initialization_options {}
        after 0 ::tclwire::cga::initialize_pending
        return
    }

    proc initialize {worker_pool_key serialized_configuration} {
        variable initialized
        variable pool_key
        variable application_class
        variable application_descriptor
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
        envs::install [$configuration environments]
        set pool_key $worker_pool_key
        set application_class [$configuration class]
        set application_descriptor [$configuration snapshot]
        dict set application_descriptor application_id [$configuration id]
        set initialized 1
        return
    }

    proc environments {} {
        tailcall ::tclwire::cga::envs::list
    }

    proc has_environment {environment} {
        tailcall ::tclwire::cga::envs::present $environment
    }

    namespace eval envs {
        variable installed {}
        variable installed_names {}
        variable installing {}
        variable application_namespace_path {}
        variable application_namespace_path_saved 0

    proc command {environment} {
        if {[string match ::* $environment]} {
            return $environment
        }
        return ::tclwire::envs::$environment
    }

    proc name {environment command} {
        if {[info commands ${command}::name] ne {}} {
            return [${command}::name]
        }
        return [namespace tail $command]
    }

    proc normalize {environment} {
        set environment [string trim $environment]
        if {[string match ::* $environment]} {
            return [namespace tail $environment]
        }
        return $environment
    }

    proc list {} {
        variable installed_names
        return $installed_names
    }

    proc present {environment} {
        variable installed_names
        return [expr {[normalize $environment] in $installed_names}]
    }

    proc require_contract {environment command} {
        if {![namespace exists $command]} {
            error "application environment '$environment' is not a namespace"
        }
        foreach method {install uninstall} {
            if {[info commands ${command}::$method] eq {}} {
                error "application environment '$environment' does not implement $method"
            }
        }
        return
    }

    proc load {environment} {
        set environment [string trim $environment]
        if {$environment eq {}} {
            error "application environment name must not be empty"
        }
        set command [command $environment]
        if {![namespace exists $command]} {
            if {[string match ::* $environment]} {
                error "application environment is not available: $environment"
            }
            package require tclwire::$environment
        }
        if {![namespace exists $command]} {
            error "application environment is not available: $environment"
        }
        return $command
    }

    proc append_path {namespaces} {
        namespace eval ::tclwire::app {}
        set path [namespace eval ::tclwire::app {namespace path}]
        foreach namespace $namespaces {
            if {![namespace exists $namespace]} {
                error "application environment path namespace does not exist: $namespace"
            }
            if {$namespace ni $path} {
                lappend path $namespace
            }
        }
        namespace eval ::tclwire::app [::list namespace path $path]
        return
    }

    proc install_one {environment} {
        variable installed
        variable installed_names
        variable installing

        set command [load $environment]
        require_contract $environment $command
        if {$command in $installed} {
            return
        }
        if {$command in $installing} {
            error "cyclic application environment dependency involving $command"
        }
        lappend installing $command

        try {
            set required_environments {}
            if {[info commands ${command}::requires] ne {}} {
                set required_environments [${command}::requires]
            }
            foreach required $required_environments {
                install_one $required
            }

            ${command}::install
            if {[info commands ${command}::path_namespaces] ne {}} {
                set namespaces [${command}::path_namespaces]
            } else {
                set namespaces [::list $command]
            }
            append_path $namespaces
        } finally {
            set index [lsearch -exact $installing $command]
            if {$index >= 0} {
                set installing [lreplace $installing $index $index]
            }
        }

        lappend installed $command
        set environment_name [name $environment $command]
        if {$environment_name ni $installed_names} {
            lappend installed_names $environment_name
        }
        return
    }

    proc install {environments} {
        variable application_namespace_path
        variable application_namespace_path_saved

        if {[catch {llength $environments}]} {
            error "application environments must be a list"
        }
        namespace eval ::tclwire::app {}
        set application_namespace_path \
            [namespace eval ::tclwire::app {namespace path}]
        set application_namespace_path_saved 1
        foreach environment $environments {
            install_one $environment
        }
        return
    }

    proc shutdown {} {
        variable installed
        variable installed_names
        variable installing
        variable application_namespace_path
        variable application_namespace_path_saved

        if {$application_namespace_path_saved} {
            catch {
                namespace eval ::tclwire::app \
                    [::list namespace path $application_namespace_path]
            }
        }
        foreach environment [lreverse $installed] {
            catch {${environment}::uninstall}
        }
        set installed {}
        set installed_names {}
        set installing {}
        set application_namespace_path {}
        set application_namespace_path_saved 0
        return
    }
    }

    proc initialize_pending {} {
        variable initialized
        variable pending_pool_key
        variable pending_serialized_configuration
        variable initialization_error
        variable initialization_options

        if {$initialized || $pending_pool_key eq {}} {
            return
        }
        set worker_pool_key $pending_pool_key
        set serialized_configuration $pending_serialized_configuration
        set pending_pool_key {}
        set pending_serialized_configuration {}

        if {[catch {
            initialize $worker_pool_key $serialized_configuration
        } message options]} {
            set initialization_error $message
            set initialization_options $options
        }
        return
    }

    proc ensure_initialized {} {
        variable initialized
        variable configuration
        variable pending_pool_key
        variable initialization_error
        variable initialization_options

        if {!$initialized && $initialization_error eq {} &&
             $pending_pool_key ne {}} {
            initialize_pending
        }
        if {$initialized && $configuration ne {}} {
            return
        }
        if {$initialization_error ne {}} {
            return -options $initialization_options $initialization_error
        }
        error "content generator worker is not initialized"
    }

    proc shutdown {} {
        variable initialized
        variable pool_key
        variable application_class
        variable application_descriptor
        variable configuration
        variable pending_pool_key
        variable pending_serialized_configuration
        variable initialization_error
        variable initialization_options

        if {$configuration ne {}} {
            catch {$configuration destroy}
        }
        envs::shutdown
        set initialized 0
        set pool_key {}
        set application_class {}
        set application_descriptor {}
        set configuration {}
        set pending_pool_key {}
        set pending_serialized_configuration {}
        set initialization_error {}
        set initialization_options {}
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

    proc execute {request_descriptor} {
        variable initialized
        variable pool_key
        variable application_class
        variable application_descriptor
        variable configuration

        ensure_initialized

        set worker_id [::thread::id]
        ::tclwire::accounting change_thread_status $worker_id running \
                [list $application_class [dict get $request_descriptor transaction_id]]

        set application {}
        set request {}
        try {
            # Establish the error-reporting path before any application-owned
            # reload, constructor, or request-handling code can fail.
            ::tclwire::io begin [dict get $request_descriptor connection_thread_id] \
                                [dict get $request_descriptor connection_agent_id]  \
                                [dict get $request_descriptor transaction_id]

            # The configuration and application descriptor are owned by the
            # worker and are stable for the lifetime of this CGA pool member.
            # Per-request work may read them, but cleanup must not destroy the
            # configuration object; it is released by cga::shutdown on worker
            # exit.
            reload_application_class $application_class $configuration
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
