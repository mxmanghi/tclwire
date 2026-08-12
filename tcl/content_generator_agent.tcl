# content_generator_agent.tcl --
#
# Reusable Content Generator Agent worker entrypoint.

package require Thread
package require TclOO
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

    proc environment_configuration {args} {
        if {[llength $args] > 2} {
            error {wrong # args: should be "::tclwire::app::environment_configuration ?environment? ?key?"}
        }
        set configuration [application_get configuration]
        tailcall $configuration environment_configuration {*}$args
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
    variable native_exit_command ::tcl::exit_process
    variable exit_command {}
    variable thread_exit_command {}
    variable thread_exit_requested 0

    namespace eval context {
        proc require_fields {label values fields} {
            foreach field $fields {
                if {![dict exists $values $field]} {
                    error "$label context is missing $field"
                }
            }
            return
        }

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
            if {[dict size $application_values]} {
                require_fields application $application_values {
                    application application_class application_descriptor
                    configuration pool_key
                }
            }
            set request_values [dict create]
            foreach field {request request_descriptor} {
                if {[dict exists $context_values $field]} {
                    dict set request_values $field \
                        [dict get $context_values $field]
                }
            }
            if {[dict size $request_values]} {
                require_fields request $request_values {
                    request request_descriptor
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

    proc install_exit_interceptor {} {
        variable native_exit_command

        if {[info commands $native_exit_command] eq {}} {
            rename ::exit $native_exit_command
            proc ::exit {args} {
                tailcall ::tclwire::cga::exit {*}$args
            }
        }
        return
    }

    proc uninstall_exit_interceptor {} {
        variable native_exit_command

        if {[info commands $native_exit_command] ne {}} {
            rename ::exit {}
            rename $native_exit_command ::exit
        }
        return
    }

    proc configure_thread_exit_command {command} {
        variable thread_exit_command

        set previous $thread_exit_command
        set thread_exit_command $command
        return $previous
    }

    proc configure_exit_command {command} {
        variable exit_command

        if {[catch {llength $command}]} {
            error "CGA exit command must be a command prefix list"
        }
        set previous $exit_command
        set exit_command $command
        return $previous
    }

    proc thread_exit_requested {} {
        variable thread_exit_requested
        return $thread_exit_requested
    }

    proc request_thread_exit {} {
        variable thread_exit_command
        variable thread_exit_requested

        set thread_exit_requested 1
        if {$thread_exit_command ne {}} {
            uplevel #0 $thread_exit_command
        }
        return
    }

    proc retire_after_request {} {
        variable pool_key

        request_thread_exit
        catch {
            ::tclwire::tpba notify_workload_transition \
                $pool_key thread-exit
        }
        catch {
            ::tclwire::tpba request [dict create operation remove_worker \
                                                pool_key $pool_key \
                                                worker_id [::thread::id]]
        }
        return
    }

    proc exit {{code 0}} {
        variable exit_command

        if {$exit_command ne {}} {
            tailcall {*}$exit_command $code
        }
        request_thread_exit
        return -code error -errorcode {TCLWIRE THREAD_EXIT} $code
    }

    proc initialize {worker_pool_key serialized_configuration} {
        variable initialized
        variable pool_key
        variable application
        variable application_class
        variable application_descriptor
        variable configuration

        set worker_pool_key [string trim $worker_pool_key]
        if {![string length $worker_pool_key]} {
            error "content generator worker pool key must not be empty"
        }

        if {$initialized || [info object isa object $configuration] ||
                            [info object isa object $application]} {
            shutdown
        }

        # A CGA worker belongs to one application pool.  The immutable
        # application configuration is therefore worker initialization state,
        # not request payload. Runtime reconfiguration should replace pools
        # and retire their workers instead of sending a different application
        # configuration with each request.

        install_exit_interceptor
        set configuration [::tclwire::ApplicationConfiguration deserialize $serialized_configuration]
        envs::configure_application $configuration
        envs::install [$configuration environment]

        set pool_key $worker_pool_key
        set application {}
        set application_class [$configuration class]
        set application_descriptor [$configuration snapshot]
        dict set application_descriptor application_id [$configuration id]
        if {[catch {
            create_application_object
        } message options]} {
            shutdown
            return -options $options $message
        }
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
        variable path_namespaces {}
        variable application_namespace_path {}
        variable application_namespace_path_saved 0
        variable application_configuration {}

    proc command {environment} {
        if {[string match ::* $environment]} {
            return $environment
        }
        return ::tclwire::envs::$environment
    }

    proc name {environment command} {
        return [[object $command] name]
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
        object $command
        return
    }

    proc object_available {command} {
        if {[info commands ${command}::object] eq {}} {
            return 0
        }
        return 1
    }

    proc object {command} {
        if {![object_available $command]} {
            error "application environment '$command' does not expose object"
        }
        set environment_object [${command}::object]
        if {![info object isa object $environment_object]} {
            error "application environment object is not a TclOO object: $environment_object"
        }
        return $environment_object
    }

    proc load {environment} {
        set environment [string trim $environment]
        if {![string length $environment]} {
            error "application environment name must not be empty"
        }
        set command [command $environment]
        if {![string match ::* $environment] &&
                (![namespace exists $command] ||
                 ![object_available $command])} {
            package require tclwire::$environment
        } elseif {![namespace exists $command]} {
            if {[string match ::* $environment]} {
                error "application environment is not available: $environment"
            }
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

        if {![llength $path_namespaces]} {
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

    proc configure_application {configuration} {
        variable application_configuration

        if {$configuration ne {} && ![info object isa object $configuration]} {
            error "CGA environment application configuration must be a TclOO object"
        }
        set application_configuration $configuration
        return
    }

    proc application_configuration {} {
        variable application_configuration
        return $application_configuration
    }

    proc install_environment {environment} {
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
            set environment_object [object $command]
            set required_environments [$environment_object requires]
            foreach required $required_environments {
                install_environment $required
            }

            $environment_object install
            set namespaces [$environment_object path_namespaces]
            if {![llength $namespaces]} {
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
            install_environment $environment
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
        variable application_configuration

        if {$application_namespace_path_saved} {
            catch {
                namespace eval ::tclwire::app \
                    [::list namespace path $application_namespace_path]
            }
        }
        foreach environment [lreverse $installed] {
            set environment_object [object $environment]
            catch {$environment_object uninstall}
        }
        set installed {}
        set installed_names {}
        set installing {}
        set path_namespaces {}
        set application_namespace_path {}
        set application_namespace_path_saved 0
        set application_configuration {}
        return
    }
    }

    proc ensure_initialized {} {
        variable initialized
        variable configuration
        variable application

        if {$initialized && [info object isa object $configuration]} {
            return
        }
        error "content generator worker is not initialized"
    }

    proc require_request_descriptor {request_descriptor} {
        if {[catch {dict size $request_descriptor}]} {
            error "CGA request descriptor must be a dictionary"
        }
        foreach field {
            application_id connection_thread_id connection_agent_id
            transaction_id
        } {
            if {![dict exists $request_descriptor $field] ||
                    ![string length [dict get $request_descriptor $field]]} {
                error "CGA request descriptor is missing $field"
            }
        }
        return
    }

    proc shutdown {} {
        variable initialized
        variable pool_key
        variable application
        variable application_class
        variable application_descriptor
        variable configuration
        variable exit_command
        variable thread_exit_command
        variable thread_exit_requested

        catch {::tclwire::app::end_request}
        if {[info object isa object $application]} {
            catch {$application shutdown}
            catch {$application destroy}
        }
        set application {}
        catch {::tclwire::app::end_application}
        envs::shutdown
        if {[info object isa object $configuration]} {
            catch {$configuration destroy}
        }
        set initialized 0
        set pool_key {}
        set application_class {}
        set application_descriptor {}
        set application {}
        set configuration {}
        set exit_command {}
        set thread_exit_command {}
        set thread_exit_requested 0
        uninstall_exit_interceptor
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

    proc destroy_application_object {} {
        variable application

        if {[info object isa object $application]} {
            catch {$application shutdown}
            catch {$application destroy}
        }

        set application {}
        catch {::tclwire::app::end_application}
        return
    }

    proc create_application_object {} {
        variable pool_key
        variable application
        variable application_class
        variable application_descriptor
        variable configuration

        destroy_application_object
        if {[info commands $application_class] eq {} ||
           ![info object isa class $application_class]} {
            error "application command is not a TclOO class: $application_class"
        }
        set application [$application_class new $application_descriptor]

        envs::append_to_namespace [info object namespace $application]
        ::tclwire::app::begin_application \
                        [dict create application            $application \
                                     application_class      $application_class \
                                     application_descriptor $application_descriptor \
                                     configuration          $configuration \
                                     pool_key               $pool_key]

        try {
            $application initialize
        } on error {message options} {
            destroy_application_object
            return -options $options $message
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
                    "$field=[::tclwire::logger::log_value [dict get $request_descriptor $field]]"
            }
        }
        lappend fields "error=[::tclwire::logger::log_value $message]"
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
        catch {::tclwire::app::end_request}
        catch {::tclwire::tools::end}
        catch {::tclwire::io end}
        return
    }

    proc process_request {request_descriptor} {
        variable application

        set request [::tclwire::HttpRequest new $request_descriptor]
        try {
            ::tclwire::app::begin_request [dict create  request            $request \
                                                        request_descriptor $request_descriptor]
            $application handle_request $request
            if {[::tclwire::io::accepting_output]} {
                ::tclwire::io complete
            }
        } finally {
            catch {::tclwire::app::end_request}
            catch {$request destroy}
        }
        return
    }

    proc execute {request_descriptor} {
        variable initialized
        variable pool_key
        variable application
        variable application_class
        variable configuration

        require_request_descriptor $request_descriptor
        set worker_id [::thread::id]

        try {
            # Establish the error-reporting path before any
            # application-owned request-handling code can fail.
            begin_request_ambient $request_descriptor

            ensure_initialized
            ::tclwire::accounting change_thread_status $worker_id running \
                [list $application_class \
                      [dict get $request_descriptor transaction_id]]

            process_request $request_descriptor
        } on error {message options} {
            log_application_error $request_descriptor $message $options
            catch {::tclwire::io fail $message}
        } finally {
            set reload_on_request 0
            if {[info object isa object $configuration]} {
                set reload_on_request [$configuration reload_on_request]
                cleanup_uploaded_files $configuration $request_descriptor
            }
            end_request_ambient
            if {$reload_on_request} {
                retire_after_request
            } else {
                catch {
                    ::tclwire::tpba notify_workload_transition \
                        $pool_key request-processed
                }
            }
        }
        return
    }
}

package provide tclwire::content_generator_agent 0.1
