# application_dispatcher.tcl --
#
# Host-based application selection and Content Generator Agent pool dispatch.

package require TclOO
package require Thread
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
        set project_root        [file normalize \
                                    [file join [file dirname [info script]] ..]]
        set owned_pools         {}
        set default_docroot {}
        if {[dict exists $application_config docroot]} {
            set default_docroot [dict get $application_config docroot]
        }

        dict for {application_id descriptor} $applications {
            if {![dict exists $descriptor docroot]} {
                if {$default_docroot eq {}} {
                    error "application '$application_id' is missing docroot"
                }
                dict set descriptor docroot $default_docroot
            }
            dict set descriptor docroot \
                [file normalize [dict get $descriptor docroot]]
            dict set applications $application_id $descriptor
        }
        my validate
    }

    destructor {
        my stop
    }

    method validate {} {
        if {![dict exists $applications $default_application]} {
            error "default application is not registered: $default_application"
        }
        dict for {application_id descriptor} $applications {
            foreach field {class package hosts docroot} {
                if {![dict exists $descriptor $field]} {
                    error "application '$application_id' is missing $field"
                }
            }
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
        return [format {
            lappend auto_path %s
            package require Thread
            package require tclwire::accounting 1.2
            package require tclwire::content_generator_agent 0.1
            package require %s 0.1

            proc demand_thread_exit {} {
                ::thread::release [::thread::id]
            }

            ::thread::wait
            catch {::tclwire::accounting remove_thread [::thread::id]}
        } [list $project_root] [list [dict get $application_descriptor package]]]
    }

    method start {} {
        dict for {application_id descriptor} $applications {
            set key [my pool_key $application_id]
            set policy [dict create minimum_workers 0 maximum_workers 20]
            if {[dict exists $descriptor pool_policy]} {
                set policy [dict merge $policy [dict get $descriptor pool_policy]]
            }

            # asking the TPBA to create a worker pool associated to the application
            # to run the script stored in the application descriptor

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
        set response [::tclwire::tpba request [dict create \
            operation acquire_worker \
            pool_key $key]]
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
            ::thread::send -async $worker_id [list \
                ::tclwire::cga::execute \
                $key \
                [dict get $descriptor class] \
                $descriptor \
                $request_descriptor]
        } message options]} {
            catch {::tclwire::tpba request [dict create \
                operation release_worker \
                pool_key $key \
                worker_id $worker_id]}
            return -options $options $message
        }
        return [dict create application_id  $application_id \
                            pool_key        $key \
                            worker_id       $worker_id]
    }
}

package provide tclwire::application_dispatcher 0.1
