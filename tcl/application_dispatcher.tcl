# application_dispatcher.tcl --
#
# Host-based application selection and Content Generator Agent pool dispatch.

package require TclOO
package require Thread
package require tclwire::support 0.1
package require tclwire::tpba::control 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ApplicationDispatcher {
    variable applications default_application project_root owned_pools

    constructor {application_config} {
        if {[catch {dict size $application_config}]} {
            error "application configuration must be a dictionary"
        }
        set applications        [dict get $application_config applications]
        set default_application [dict get $application_config default_application]
        set project_root        [::tclwire::support project_root]
        set owned_pools         {}
        set default_docroot {}
        if {[dict exists $application_config docroot]} {
            set default_docroot [dict get $application_config docroot]
        }
        set default_encoding {}
        if {[dict exists $application_config encoding]} {
            set default_encoding [dict get $application_config encoding]
        }

        if {![dict exists $applications $default_application]} {
            error "default application is not registered: $default_application"
        }
        set default_descriptor [dict get $applications $default_application]
        dict for {application_id original_descriptor} $applications {
            set descriptor $original_descriptor
            set had_hosts [dict exists $original_descriptor hosts]
            if {$application_id ne $default_application} {
                if {[dict exists $default_descriptor pool_policy] &&
                    [dict exists $descriptor pool_policy]} {

                    dict set descriptor pool_policy [dict merge \
                        [dict get $default_descriptor pool_policy] \
                        [dict get $descriptor pool_policy]]

                }
                set descriptor [dict merge $default_descriptor $descriptor]
                if {!$had_hosts} {
                    dict set descriptor hosts [list $application_id]
                }
            }
            if {![dict exists $descriptor docroot]} {
                if {$default_docroot eq {}} {
                    error "application '$application_id' is missing docroot"
                }
                dict set descriptor docroot $default_docroot
            }
            dict set descriptor docroot \
                [file normalize [dict get $descriptor docroot]]
            if {![dict exists $descriptor libdir] &&
                    [dict exists $application_config libdir]} {
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
            if {![dict exists $descriptor encoding]} {
                if {$default_encoding eq {}} {
                    error "application '$application_id' is missing encoding"
                }
                dict set descriptor encoding $default_encoding
            }
            dict set descriptor application_paths \
                [my application_paths $descriptor]
            if {[dict exists $descriptor file]} {
                dict set descriptor file \
                    [my resolve_application_file $application_id $descriptor]
            }
            my validate_descriptor $application_id $descriptor
            dict set applications $application_id $descriptor
        }
    }

    destructor {
        my stop
    }

    method resolve_application_file {application_id descriptor} {
        set application_file [dict get $descriptor file]
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
        error "application '$application_id' file '$application_file' was not found; searched: [join $searched {, }]"
    }

    method application_paths {descriptor} {
        set paths [list [dict get $descriptor docroot]]
        if {[dict exists $descriptor libdir]} {
            lappend paths [dict get $descriptor libdir]
        }
        lappend paths $project_root

        set unique_paths {}
        foreach directory $paths {
            if {$directory ni $unique_paths} {
                lappend unique_paths $directory
            }
        }
        return $unique_paths
    }

    method validate_descriptor {application_id descriptor} {
        foreach field {class hosts docroot encoding application_paths} {
            if {![dict exists $descriptor $field]} {
                error "application '$application_id' is missing $field"
            }
        }
        if {![dict exists $descriptor package] &&
                ![dict exists $descriptor file]} {
            error "application '$application_id' must define package or file"
        }
        if {[dict exists $descriptor file] &&
                ![file isfile [dict get $descriptor file]]} {
            error "application '$application_id' file does not exist: [dict get $descriptor file]"
        }
        if {[dict get $descriptor encoding] ni [encoding names]} {
            error "application '$application_id' has an unknown encoding: [dict get $descriptor encoding]"
        }
        return
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
        if {$host eq {}} {
            return $default_application
        }

        dict for {application_id descriptor} $applications {
            foreach configured_host [dict get $descriptor hosts] {
                if {$host eq [my normalize_host $configured_host]} {
                    return $application_id
                }
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

    method worker_script {application_descriptor} {
        set application_paths [dict get $application_descriptor application_paths]

        set loader {}
        if {[dict exists $application_descriptor file]} {
            set loader [list source [dict get $application_descriptor file]]
        } else {
            set loader [list package require \
                [dict get $application_descriptor package] 0.1]
        }
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
            %s

            proc demand_thread_exit {} {
                ::thread::release [::thread::id]
            }

            ::thread::wait
            ::tclwire::accounting remove_thread [::thread::id]
        } [list $application_paths] $loader]
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
                                     worker_script  [my worker_script $descriptor] \
                                     policy         $policy \
                                     descriptor     [dict create kind        application \
                                                                 application $application_id \
                                                                 family      application \
                                                                 class       [dict get $descriptor class]]]]

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
        if {$worker_id eq {}} {
            error "application pool is exhausted: $key"
        }

        dict set request_descriptor application_id $application_id
        dict set request_descriptor application_pool_key $key
        dict set request_descriptor application_descriptor $descriptor
        if {[catch {
            ::thread::send -async $worker_id \
                [list ::tclwire::cga::execute $key \
                                              [dict get $descriptor class] \
                                              $descriptor \
                                              $request_descriptor]
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
}

package provide tclwire::application_dispatcher 0.1
