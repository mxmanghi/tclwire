# application_configuration.tcl --
#
# Immutable, validated application configuration value object.

package require TclOO

namespace eval ::tclwire {}

oo::class create ::tclwire::ApplicationConfiguration {
    variable application_id values

    constructor {id descriptor} {
        if {[catch {dict size $descriptor}]} {
            error "application configuration must be a dictionary"
        }
        set application_id $id
        set defaults [dict create \
            package {} \
            file {} \
            libdir {} \
            log_level {} \
            reload_on_request 0 \
            retain_uploaded_files 0 \
            pool_policy [dict create minimum_workers 0 maximum_workers 20]]
        set values [dict merge $defaults $descriptor]

        foreach property {class hosts docroot encoding application_paths} {
            if {![dict exists $descriptor $property]} {
                error "application '$id' is missing $property"
            }
        }
        if {[dict get $values package] eq {} &&
                [dict get $values file] eq {}} {
            error "application '$id' must define package or file"
        }
        if {[dict get $values file] ne {} &&
                ![file isfile [dict get $values file]]} {
            error "application '$id' file does not exist: [dict get $values file]"
        }
        if {[catch {llength [dict get $values hosts]}] ||
                [catch {llength [dict get $values application_paths]}]} {
            error "application '$id' hosts and application_paths must be lists"
        }
        if {[catch {
            set pool_policy [dict merge \
                [dict get $defaults pool_policy] \
                [dict get $values pool_policy]]
        }]} {
            error "application '$id' pool_policy must be a dictionary"
        }
        foreach property {minimum_workers maximum_workers} {
            set count [dict get $pool_policy $property]
            if {![string is integer -strict $count] || $count < 0} {
                error "application '$id' pool_policy.$property must be a nonnegative integer"
            }
        }
        if {[dict get $pool_policy maximum_workers] <
                [dict get $pool_policy minimum_workers]} {
            error "application '$id' maximum_workers must not be less than minimum_workers"
        }
        dict set values pool_policy $pool_policy
        foreach property {reload_on_request retain_uploaded_files} {
            if {![string is boolean -strict [dict get $values $property]]} {
                error "application '$id' $property must be a boolean"
            }
            dict set values $property \
                [expr {!![dict get $values $property]}]
        }
        if {[dict get $values reload_on_request] &&
                [dict get $values file] eq {}} {
            error "application '$id' reload_on_request requires file"
        }
        if {[dict get $values encoding] ni [encoding names]} {
            error "application '$id' has an unknown encoding: [dict get $values encoding]"
        }
    }

    method id {} {
        return $application_id
    }

    method get {property} {
        if {![dict exists $values $property]} {
            error "unknown application configuration property: $property"
        }
        return [dict get $values $property]
    }

    method snapshot {} {
        return $values
    }

    method serialize {} {
        return [dict create \
            type tclwire.application_configuration \
            version 1 \
            application_id $application_id \
            values $values]
    }

    self method deserialize {serialized} {
        if {[catch {dict size $serialized}]} {
            error "serialized application configuration must be a dictionary"
        }
        foreach property {type version application_id values} {
            if {![dict exists $serialized $property]} {
                error "serialized application configuration is missing $property"
            }
        }
        if {[dict get $serialized type] ne
                "tclwire.application_configuration"} {
            error "unsupported application configuration type: [dict get $serialized type]"
        }
        if {[dict get $serialized version] != 1} {
            error "unsupported application configuration version: [dict get $serialized version]"
        }
        return [my new \
            [dict get $serialized application_id] \
            [dict get $serialized values]]
    }

    foreach property {
        class hosts docroot encoding application_paths package file libdir
        log_level reload_on_request retain_uploaded_files pool_policy
    } {
        method $property {} [format {my get %s} [list $property]]
    }
}

package provide tclwire::application_configuration 0.1
