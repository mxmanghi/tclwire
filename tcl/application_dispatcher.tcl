# application_dispatcher.tcl --
#
# Host-based application selection and Content Generator Agent pool dispatch.

package require TclOO
package require Thread
package require tclwire::application_configuration 0.1
package require tclwire::environment 0.1
package require tclwire::support 0.1
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ApplicationDispatcher {
    variable applications application_configurations
    variable default_application project_root run_directory owned_pools

    constructor {application_config} {
        # The dispatcher receives the already-loaded application runtime
        # dictionary.  Make sure it is a dictionary before any descriptor
        # inheritance or path resolution starts.

        if {[catch {dict size $application_config}]} {
            error "application configuration must be a dictionary"
        }

        # Cache the top-level runtime state used while normalizing each
        # application descriptor and later while dispatching requests.

        set applications        [dict get $application_config applications]
        set application_configurations [dict create]
        set default_application [dict get $application_config default_application]
        set project_root        [::tclwire::support project_root]
        set run_directory       [file normalize [pwd]]
        set owned_pools         {}

        # Global docroot and encoding are fallbacks.  They are copied into an
        # application descriptor only when that descriptor does not name its
        # own value.

        set default_docroot {}
        if {[dict exists $application_config docroot]} {
            set default_docroot [dict get $application_config docroot]
        }
        set default_encoding {}
        if {[dict exists $application_config encoding]} {
            set default_encoding [dict get $application_config encoding]
        }
        set default_aliases {}
        if {[dict exists $application_config aliases]} {
            set default_aliases [dict get $application_config aliases]
        }
        set server_defaults [dict create hostname    {} \
                                         admin       {} \
                                         logfile     {} \
                                         logerr      {} \
                                         server_path {}]
        if {[dict exists $application_config host]} {
            dict set server_defaults hostname [dict get $application_config host]
        }
        foreach {target source} {
            hostname    hostname
            admin       admin
            logfile     logfile
            logerr      logerr
            server_path server_path
        } {
            if {[dict exists $application_config $source]} {
                dict set server_defaults $target [dict get $application_config $source]
            }
        }

        if {![dict exists $applications $default_application]} {
            error "default application is not registered: $default_application"
        }

        # Normalize class names in the default descriptor once because every
        # non-default application inherits from this loaded descriptor.

        set default_descriptor [::tclwire::normalize_application_descriptor_classes \
                                        [dict get $applications $default_application]]
        if {[dict exists $default_descriptor aliases]} {
            set default_descriptor [my merge_application_aliases \
                [dict create aliases $default_aliases] $default_descriptor]
        } else {
            dict set default_descriptor aliases $default_aliases
        }
        dict for {application_id original_descriptor} $applications {

            # Work on a normalized copy and remember which fields were present
            # in the original descriptor.  After inheritance these booleans tell
            # us whether a value was explicitly configured here or merely
            # inherited from the default application.
            set descriptor  \
                [::tclwire::normalize_application_descriptor_classes $original_descriptor]
            set had_hosts           [dict exists $original_descriptor hosts]
            set explicit_class      [dict exists $original_descriptor class]
            set explicit_package    [dict exists $original_descriptor package]
            set explicit_file       [dict exists $original_descriptor file]
            set explicit_chore      [dict exists $original_descriptor chore]
            set explicit_chore_class [dict exists $original_descriptor chore_class]

            # In this context 'loader' means the descriptor fields that tell the
            # worker how the application class gets made available before it is instantiated.
            # Specifically:
            #
            #   - package: load the application implementation with package require ...
            #   - file: load/source a Tcl file containing the application implementation
            #   - reload_on_request: if enabled, retire the worker after each
            #     request so the replacement worker sources the current file
            #
            # So 'inherited loader' means: a non-default application inherited package,
            # file, or reload behavior from the default application descriptor.
            # That matters because a virtual host may inherit most settings from the default
            # app but select a different class through an environment. If it keeps
            # the default app's file, replacement workers would source the wrong
            # implementation file for the new class. The constructor therefore
            # removes inherited loader fields when the final class no longer
            # matches the inherited default class, unless the descriptor
            # explicitly supplied its own package or file.

            set suppress_inherited_loader 0

            if {$application_id ne $default_application} {
                # Non-default applications inherit the default application as a
                # template.  Pool policy is a shallow option dictionary, so host
                # descriptors override only the policy keys they name.
                if {[dict exists $default_descriptor pool_policy] &&
                    [dict exists $descriptor pool_policy]} {

                    set dpp [dict get $default_descriptor pool_policy]
                    set pp  [dict get $descriptor pool_policy]

                    dict set descriptor pool_policy [dict merge $dpp $pp]
                }

                # `configure` is nested by TclOO class name.  A plain
                # `dict merge` would replace the whole inherited per-class
                # option block when a host overrides one option.  This helper
                # merges one level deeper so inherited class configuration
                # survives and only the named options are overlaid.
                set descriptor [my merge_nested_dict_field $default_descriptor $descriptor configure]
                set descriptor [my merge_application_aliases $default_descriptor $descriptor]

                # Apply the main descriptor inheritance after special nested
                # fields have been merged.
                set descriptor [dict merge $default_descriptor $descriptor]

                # Chores are operational side tasks, not application behavior
                # that should silently spread to every virtual host.  Drop
                # inherited chore fields unless this descriptor explicitly
                # opted into them.
                if {!$explicit_chore && [dict exists $descriptor chore]} {
                    dict unset descriptor chore
                }
                if {!$explicit_chore_class && [dict exists $descriptor chore_class]} {
                    dict unset descriptor chore_class
                }

                # A virtual host descriptor without an explicit host list is
                # addressed by its application id.
                if {!$had_hosts} {
                    dict set descriptor hosts [list $application_id]
                }

                # If an environment-specific class replaces the inherited
                # default class, then the default application's package/file
                # loader no longer matches the selected class.  Mark inherited
                # loader fields for removal unless this descriptor explicitly
                # supplied its own package or file.
                if {[dict exists $original_descriptor environment] &&
                        $explicit_class &&
                        !$explicit_package &&
                        !$explicit_file &&
                        [dict exists $default_descriptor class] &&
                        [dict get $descriptor class] ne
                            [dict get $default_descriptor class]} {
                    set suppress_inherited_loader 1
                }
            }
            if {!$explicit_class} {
                # Descriptors may delegate the application class choice to the
                # selected environment.  When that happens, inherited loader
                # fields are suppressed for the same reason as above: they were
                # attached to the inherited class, not necessarily to the
                # environment-selected class.
                set environment_class [::tclwire::environment application_class $application_id $descriptor]
                if {$environment_class ne {}} {
                    dict set descriptor class $environment_class
                    set suppress_inherited_loader 1
                }
            }
            if {$suppress_inherited_loader} {
                # Remove inherited package/file loader settings that came from
                # the default descriptor.  A descriptor's explicit package or
                # file is preserved because that is an intentional loader for
                # the final selected class.
                if {!$explicit_package && [dict exists $descriptor package]} {
                    dict unset descriptor package
                }
                if {!$explicit_file && [dict exists $descriptor file]} {
                    dict unset descriptor file
                }
                # `reload_on_request` requires a concrete source file for
                # replacement workers. If the class came from the environment
                # and no explicit file was configured, ask the environment for
                # a matching file; otherwise disable reloads so the inherited
                # file is not used for the wrong class.
                if {!$explicit_file &&  [dict exists $descriptor reload_on_request] &&
                                        [dict get $descriptor reload_on_request]} {
                    set environment_file [::tclwire::environment application_file \
                                                        $application_id $descriptor]
                    if {$environment_file ne {}} {
                        dict set descriptor file $environment_file
                    } else {
                        dict set descriptor reload_on_request 0
                    }
                }
            }

            # Resolve required descriptor defaults and fail early when no
            # per-application or global value exists.
            if {![dict exists $descriptor docroot]} {
                if {![string length $default_docroot]} {
                    error "application '$application_id' is missing docroot"
                }
                dict set descriptor docroot $default_docroot
            }
            dict set descriptor docroot [file normalize [dict get $descriptor docroot]]
            if {![dict exists $descriptor aliases]} {
                dict set descriptor aliases $default_aliases
            }

            # Inherit the global library directory, then normalize it.  An
            # empty libdir is treated as absent.
            if {![dict exists $descriptor libdir] && [dict exists $application_config libdir]} {
                dict set descriptor libdir [dict get $application_config libdir]
            }
            if {[dict exists $descriptor libdir]} {
                if {[dict get $descriptor libdir] eq {}} {
                    dict unset descriptor libdir
                } else {
                    dict set descriptor libdir \
                        [file normalize [dict get $descriptor libdir]]
                }
            }

            # Encoding is required by the request path; use the global default
            # only when the application omitted it.
            if {![dict exists $descriptor encoding]} {
                if {![string length $default_encoding]} {
                    error "application '$application_id' is missing encoding"
                }
                dict set descriptor encoding $default_encoding
            }
            dict for {field value} $server_defaults {
                if {![dict exists $descriptor $field]} {
                    dict set descriptor $field $value
                }
            }

            # Build the ordered search path used to resolve relative
            # application source files and chore files.
            dict set descriptor application_paths [my application_paths $descriptor]
            if {[dict exists $descriptor file] &&
                    [dict get $descriptor file] ne {}} {
                dict set descriptor file [my resolve_application_file $application_id $descriptor file]
            }
            if {[dict exists $descriptor chore] &&
                    [dict get $descriptor chore] ne {}} {
                dict set descriptor chore [my resolve_application_file $application_id $descriptor chore]
            }

            # Wrap the normalized descriptor in the per-application helper and
            # store snapshots for fast host dispatch.
            set configuration [::tclwire::ApplicationConfiguration new $application_id $descriptor]
            dict set application_configurations $application_id $configuration
            dict set applications $application_id [$configuration snapshot]
        }
    }

    # Merge descriptor fields whose value is itself a dictionary of named
    # dictionaries.  `configure` uses this shape: its outer keys are TclOO
    # class names and each value is that class's option dictionary.  A plain
    # `dict merge` would replace the complete inherited configure block for a
    # class whenever a virtual host overrides one option.  This keeps the
    # inherited class block and overlays only the options named by the
    # virtual-host descriptor.
    method merge_nested_dict_field {base override field} {
        if {![dict exists $base $field] || ![dict exists $override $field]} {
            return $override
        }

        set merged [dict get $base $field]
        dict for {key values} [dict get $override $field] {
            if {[dict exists $merged $key] &&
                    ![catch {dict size [dict get $merged $key]}] &&
                    ![catch {dict size $values}]} {
                dict set merged $key [dict merge [dict get $merged $key] $values]
            } else {
                dict set merged $key $values
            }
        }
        dict set override $field $merged
        return $override
    }

    method merge_application_aliases {base override} {
        if {![dict exists $base aliases] || ![dict exists $override aliases]} {
            return $override
        }
        set aliases [dict get $override aliases]
        foreach alias [dict get $base aliases] {
            if {$alias ni $aliases} {
                lappend aliases $alias
            }
        }
        dict set override aliases $aliases
        return $override
    }

    destructor {
        my stop
        dict for {application_id configuration} $application_configurations {
            $configuration destroy
        }
    }

    method resolve_application_file {application_id descriptor {field file}} {
        set application_file [dict get $descriptor $field]
        if {[file pathtype $application_file] eq "absolute"} {
            return [file normalize $application_file]
        }

        set search_directories [dict get $descriptor application_paths]

        set searched {}
        foreach directory $search_directories {
            set candidate [file normalize [file join $directory $application_file]]
            if {$candidate in $searched} {
                continue
            }
            lappend searched $candidate
            if {[file isfile $candidate]} {
                return $candidate
            }
        }
        error "application '$application_id' $field '$application_file' was not found; searched: [join $searched {, }]"
    }

    method application_paths {descriptor} {
        set paths [list $project_root $run_directory [dict get $descriptor docroot]]
        if {[dict exists $descriptor libdir]} {
            lappend paths [dict get $descriptor libdir]
        }

        set unique_paths {}
        foreach directory $paths {
            if {$directory ni $unique_paths} {
                lappend unique_paths $directory
            }
        }
        return $unique_paths
    }

    method normalize_host {host} {
        set host [string tolower [string trim $host]]
        if {[regexp {^\[([^\]]+)\](?::[0-9]+)?$} $host -> address]} {
            return $address
        }
        regsub {:[0-9]+$} $host {} host
        return $host
    }

    method select_application {request_descriptor} {
        set host {}
        if {[dict exists $request_descriptor headers host]} {
            set host [my normalize_host \
                [dict get $request_descriptor headers host]]
        }
        if {![string length $host]} {
            return $default_application
        }

        dict for {application_id descriptor} $applications {
            if {$application_id eq $default_application} {
                continue
            }
            foreach configured_host [dict get $descriptor hosts] {
                if {$host eq [my normalize_host $configured_host]} {
                    return $application_id
                }
            }
        }
        set default_descriptor [dict get $applications $default_application]
        foreach configured_host [dict get $default_descriptor hosts] {
            if {$host eq [my normalize_host $configured_host]} {
                return $default_application
            }
        }
        error "no application is configured for Host '$host'"
    }

    method application {application_id} {
        if {![dict exists $applications $application_id]} {
            error "unknown application: $application_id"
        }
        return [dict get $applications $application_id]
    }

    method application_configuration {application_id} {
        if {![dict exists $application_configurations $application_id]} {
            error "unknown application: $application_id"
        }
        return [dict get $application_configurations $application_id]
    }

    method pool_key {application_id} {
        set response [::tclwire::tpba request [dict create \
            operation pool_key \
            descriptor [dict create \
                kind application \
                application $application_id]]]
        if {![dict get $response ok]} {
            error [dict get $response error]
        }
        return [dict get $response result]
    }

    method worker_script {application_configuration pool_key} {
        set pool_key [string trim $pool_key]
        if {![string length $pool_key]} {
            error "application worker pool key must not be empty"
        }
        set application_descriptor [$application_configuration snapshot]
        set application_paths [dict get $application_descriptor application_paths]

        set loader {}
        if {[dict exists $application_descriptor file] &&
            [dict get $application_descriptor file] ne {}} {

            set loader [list namespace eval ::tclwire::app \
                [list source [dict get $application_descriptor file]]]
        } elseif {[dict exists $application_descriptor package] &&
                [dict get $application_descriptor package] ne {}} {
            set loader [list package require \
                [dict get $application_descriptor package] 0.1]
        }
        set exit_pool_notification [format {
            catch {::tclwire::tpba notify_workload_transition %s thread-exit}
            catch {::tclwire::tpba request [dict create operation remove_worker \
                                                        pool_key %s \
                                                        worker_id [::thread::id]]}
        } [list $pool_key] [list $pool_key]]
        set initialize_cga [list \
            ::tclwire::cga::initialize \
            $pool_key [$application_configuration serialize]]
        return [format {
            set application_paths %s
            set inherited_paths {}
            foreach directory $auto_path {
                if {$directory ni $application_paths} {
                    lappend inherited_paths $directory
                }
            }
            set auto_path [concat $application_paths $inherited_paths]
            package require Thread
            package require tclwire::accounting 1.2
            package require tclwire::content_generator_agent 0.1
            foreach directory [lreverse $application_paths] {
                set pkg_index [file join $directory pkgIndex.tcl]
                if {[file isfile $pkg_index]} {
                    set dir $directory
                    source $pkg_index
                    unset dir
                }
            }
            %s
            # This command runs in the new CGA worker interpreter.  It creates
            # and initializes the application object once for this application
            # pool member; future runtime reconfiguration should replace the
            # pool and retire these threads, not alter the application contract
            # request by request.
            %s
            ::tclwire::cga::configure_thread_exit_command \
                [list after 0 [list ::thread::release [::thread::id]]]

            proc demand_thread_exit {} {
                ::thread::release [::thread::id]
            }

            proc application_signal {args} {
                ::tclwire::cga::signal {*}$args
            }

            ::thread::wait
            ::tclwire::cga::shutdown
            %s
            ::tclwire::accounting remove_thread [::thread::id]
        } [list $application_paths] $loader $initialize_cga \
            $exit_pool_notification]
    }

    method start {} {
        dict for {application_id descriptor} $applications {
            set key [my pool_key $application_id]
            set policy [dict create minimum_workers 0 maximum_workers 20]
            if {[dict exists $descriptor pool_policy]} {
                set policy [dict merge $policy [dict get $descriptor pool_policy]]
            }

            # asking the TPBA to create a worker pool associated to the application
            # which will have the script composed by [worker_script]

            set response [::tclwire::tpba request \
                        [dict create operation      create_pool  \
                                     pool_key       $key         \
                                     worker_script  [my worker_script \
                                                        [my application_configuration $application_id] \
                                                        $key] \
                                     policy         $policy \
                                     descriptor     [dict create kind        application \
                                                                 application $application_id \
                                                                 family      application \
                                                                 class       [dict get $descriptor class] \
                                                                 hosts       [dict get $descriptor hosts]]]]

            if {![dict get $response ok]} {
                my stop
                error [dict get $response error]
            }
            lappend owned_pools $key
        }
        return $owned_pools
    }

    method stop {} {
        foreach key $owned_pools {
            catch {::tclwire::tpba request [dict create \
                operation destroy_pool \
                pool_key $key]}
        }
        set owned_pools {}
        return
    }

    method dispatch {request_descriptor} {
        set application_id [my select_application $request_descriptor]
        set descriptor [my application $application_id]
        set key [my pool_key $application_id]

        # getting a worker thread handle from the TPBA

        set response [::tclwire::tpba request [dict create operation acquire_worker \
                                                           pool_key  $key]]
        if {![dict get $response ok]} {
            error [dict get $response error]
        }
        set worker_id [dict get $response result]
        if {[catch {::thread::exists $worker_id} worker_exists] ||
                !$worker_exists} {
            error "application pool is exhausted: $key"
        }

        dict set request_descriptor application_id $application_id
        dict set request_descriptor application_pool_key $key
        if {[catch {
            ::thread::send -async $worker_id \
                [list ::tclwire::cga::execute $request_descriptor]
        } message options]} {
            catch {::tclwire::tpba request [dict create operation   release_worker \
                                                        pool_key    $key \
                                                        worker_id   $worker_id]}
            return -options $options $message
        }
        return [dict create application_id  $application_id \
                            pool_key        $key \
                            worker_id       $worker_id \
                            encoding        [dict get $descriptor encoding]]
    }

    unexport merge_nested_dict_field
}

package provide tclwire::application_dispatcher 0.1
