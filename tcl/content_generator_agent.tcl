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

namespace eval ::tclwire::app {
    variable application_active 0
    variable application_values {}
    variable request_active 0
    variable request_values {}

    proc require_dictionary {label values} {
        if {[catch {dict size $values}]} {
            error "$label context must be a dictionary"
        }
        return
    }

    proc begin_application {context_values} {
        variable application_active
        variable application_values

        if {$application_active} {
            error "a TclWire application context is already active"
        }
        require_dictionary application $context_values
        set application_values $context_values
        set application_active 1
        return
    }

    proc end_application {} {
        variable application_active
        variable application_values

        set application_active 0
        set application_values {}
        return
    }

    proc application_active {} {
        variable application_active
        return $application_active
    }

    proc application_get {field} {
        variable application_active
        variable application_values

        if {!$application_active} {
            error "no TclWire application context is active"
        }
        if {![dict exists $application_values $field]} {
            error "unknown TclWire application context field: $field"
        }
        return [dict get $application_values $field]
    }

    proc application_snapshot {} {
        variable application_active
        variable application_values

        if {!$application_active} {
            error "no TclWire application context is active"
        }
        return $application_values
    }

    proc current {} {
        tailcall application_get application
    }

    proc application {} {
        tailcall application_get application
    }

    proc application_class {} {
        tailcall application_get application_class
    }

    proc application_descriptor {} {
        tailcall application_get application_descriptor
    }

    proc configuration {} {
        tailcall application_get configuration
    }

    proc pool_key {} {
        tailcall application_get pool_key
    }

    proc begin_request {context_values} {
        variable request_active
        variable request_values

        if {$request_active} {
            error "a TclWire request context is already active"
        }
        require_dictionary request $context_values
        set request_values $context_values
        set request_active 1
        return
    }

    proc end_request {} {
        variable request_active
        variable request_values

        set request_active 0
        set request_values {}
        return
    }

    proc request_active {} {
        variable request_active
        return $request_active
    }

    proc in_request {} {
        tailcall request_active
    }

    proc request_get {field} {
        variable request_active
        variable request_values

        if {!$request_active} {
            error "no TclWire request context is active"
        }
        if {![dict exists $request_values $field]} {
            error "unknown TclWire request context field: $field"
        }
        return [dict get $request_values $field]
    }

    proc request_snapshot {} {
        variable request_active
        variable request_values

        if {!$request_active} {
            error "no TclWire request context is active"
        }
        return $request_values
    }

    proc request {} {
        tailcall request_get request
    }

    proc request_descriptor {} {
        tailcall request_get request_descriptor
    }

    proc snapshot {} {
        set values [application_snapshot]
        if {[request_active]} {
            set values [dict merge $values [request_snapshot]]
        }
        return $values
    }
}

namespace eval ::tclwire::cga {
    variable initialized 0
    variable pool_key {}
    variable application {}
    variable application_class {}
    variable application_descriptor {}
    variable configuration {}
    variable pending_pool_key {}
    variable pending_serialized_configuration {}
    variable initialization_error {}
    variable initialization_options {}

    namespace eval context {
        proc begin {context_values} {
            if {[catch {dict size $context_values}]} {
                error "CGA application context must be a dictionary"
            }
            set application_values [dict create]
            foreach field {
                application application_class application_descriptor
                configuration pool_key
            } {
                if {[dict exists $context_values $field]} {
                    dict set application_values $field \
                        [dict get $context_values $field]
                }
            }
            set request_values [dict create]
            foreach field {request request_descriptor} {
                if {[dict exists $context_values $field]} {
                    dict set request_values $field \
                        [dict get $context_values $field]
                }
            }
            if {[dict size $application_values]} {
                if {[::tclwire::app::application_active]} {
                    ::tclwire::app::end_application
                }
                ::tclwire::app::begin_application $application_values
            }
            if {[dict size $request_values]} {
                ::tclwire::app::begin_request $request_values
            }
            return
        }

        proc end {} {
            ::tclwire::app::end_request
            return
        }

        proc active {} {
            tailcall ::tclwire::app::request_active
        }

        proc get {field} {
            if {![::tclwire::app::request_active]} {
                error "no CGA application context is active"
            }
            switch -exact -- $field {
                request -
                request_descriptor {
                    tailcall ::tclwire::app::request_get $field
                }
                default {
                    tailcall ::tclwire::app::application_get $field
                }
            }
        }

        proc snapshot {} {
            if {![::tclwire::app::request_active]} {
                error "no CGA application context is active"
            }
            tailcall ::tclwire::app::snapshot
        }

        foreach field {
            application application_class application_descriptor configuration
            pool_key request request_descriptor
        } {
            proc $field {} [format {get %s} [list $field]]
        }
    }

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
        variable application
        variable application_class
        variable application_descriptor
        variable configuration
        variable initialization_error
        variable initialization_options

        set worker_pool_key [string trim $worker_pool_key]
        if {$worker_pool_key eq {}} {
            error "content generator worker pool key must not be empty"
        }

        if {$initialized || $configuration ne {} || $initialization_error ne {}} {
            shutdown
        }

        # A CGA worker belongs to one application pool.  The immutable
        # application configuration is therefore worker initialization state,
        # not request payload. Runtime reconfiguration should replace pools
        # and retire their workers instead of sending a different application
        # configuration with each request.

        set configuration [::tclwire::ApplicationConfiguration deserialize $serialized_configuration]
        envs::install [$configuration environment]

        set pool_key $worker_pool_key
        set application {}
        set application_class [$configuration class]
        set application_descriptor [$configuration snapshot]
        dict set application_descriptor application_id [$configuration id]
        set initialized 1
        set initialization_error {}
        set initialization_options {}
        if {[catch {
            create_application_object 0
        } message options]} {
            set initialized 0
            set initialization_error $message
            set initialization_options $options
        }
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
        variable path_namespaces {}
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
        variable path_namespaces

        namespace eval ::tclwire::app {}
        set path [namespace eval ::tclwire::app {namespace path}]
        foreach namespace $namespaces {
            if {![namespace exists $namespace]} {
                error "application environment path namespace does not exist: $namespace"
            }
            if {$namespace ni $path} {
                lappend path $namespace
            }
            if {$namespace ni $path_namespaces} {
                lappend path_namespaces $namespace
            }
        }
        namespace eval ::tclwire::app [::list namespace path $path]
        return
    }

    proc append_to_namespace {target_namespace} {
        variable path_namespaces

        if {$path_namespaces eq {}} {
            return
        }
        if {![namespace exists $target_namespace]} {
            error "target namespace does not exist: $target_namespace"
        }
        set path [namespace eval $target_namespace {namespace path}]
        foreach namespace $path_namespaces {
            if {$namespace ni $path} {
                lappend path $namespace
            }
        }
        namespace eval $target_namespace [::list namespace path $path]
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
        variable path_namespaces
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
        set path_namespaces {}
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
        if {$initialization_error ne {}} {
            return -options $initialization_options $initialization_error
        }
        if {$initialized && $configuration ne {}} {
            return
        }
        error "content generator worker is not initialized"
    }

    proc shutdown {} {
        variable initialized
        variable pool_key
        variable application
        variable application_class
        variable application_descriptor
        variable configuration
        variable pending_pool_key
        variable pending_serialized_configuration
        variable initialization_error
        variable initialization_options

        catch {::tclwire::app::end_request}
        if {$application ne {}} {
            catch {$application destroy}
        }
        set application {}
        catch {::tclwire::app::end_application}
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

    proc destroy_application_object {} {
        variable application

        if {$application ne {}} {
            catch {$application destroy}
        }
        set application {}
        catch {::tclwire::app::end_application}
        return
    }

    proc create_application_object {reload} {
        variable pool_key
        variable application
        variable application_class
        variable application_descriptor
        variable configuration

        destroy_application_object
        if {$reload} {
            reload_application_class $application_class $configuration
        }
        set application [$application_class new $application_descriptor]
        envs::append_to_namespace [info object namespace $application]
        ::tclwire::app::begin_application \
            [dict create application            $application \
                         application_class      $application_class \
                         application_descriptor $application_descriptor \
                         configuration          $configuration \
                         pool_key               $pool_key]
        return $application
    }

    proc application_object {} {
        variable application
        variable configuration

        set reload [$configuration reload_on_request]
        if {$application eq {} || $reload} {
            create_application_object $reload
        }
        return $application
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
        variable application
        variable application_class
        variable application_descriptor
        variable configuration

        set worker_id [::thread::id]

        set request {}
        try {
            # Establish the error-reporting path before any application-owned
            # reload, constructor, or request-handling code can fail.
            ::tclwire::io begin [dict get $request_descriptor connection_thread_id] \
                                [dict get $request_descriptor connection_agent_id]  \
                                [dict get $request_descriptor transaction_id]

            ensure_initialized
            ::tclwire::accounting change_thread_status $worker_id running \
                [list $application_class \
                      [dict get $request_descriptor transaction_id]]

            # The configuration and application descriptor are owned by the
            # worker and are stable for the lifetime of this CGA pool member.
            # Per-request work may read them, but cleanup must not destroy the
            # configuration object; it is released by cga::shutdown on worker
            # exit.
            application_object

            ::tclwire::tools::begin $request_descriptor
            set request [::tclwire::HttpRequest new $request_descriptor]
            ::tclwire::app::begin_request \
                [dict create request            $request \
                             request_descriptor $request_descriptor]

            $application handle_request $request
            if {[::tclwire::io::accepting_output]} {
                ::tclwire::io complete
            }
        } on error {message options} {
            log_application_error $request_descriptor $message $options
            catch {::tclwire::io fail $message}
        } finally {
            catch {::tclwire::app::end_request}
            catch {::tclwire::tools::end}
            catch {::tclwire::io end}
            if {$request ne {}} {
                catch {$request destroy}
            }
            if {$configuration ne {}} {
                cleanup_uploaded_files $configuration $request_descriptor
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
