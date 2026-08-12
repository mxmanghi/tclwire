# environment.tcl --
#
# Shared inspection helpers for application environment contracts.

package require TclOO

namespace eval ::tclwire {}

oo::class create ::tclwire::ApplicationEnvironment {
    variable installed

    constructor {} {
        set installed 0
    }

    destructor {
        catch {my uninstall}
    }

    method name {} {
        return [namespace tail [info object namespace [self]]]
    }

    method requires {} {
        return {}
    }

    method path_namespaces {} {
        return {}
    }

    method application_class {} {
        return {}
    }

    method application_file {} {
        return {}
    }

    method enabled {} {
        return $installed
    }

    method application_configuration {} {
        if {[info commands ::tclwire::cga::envs::application_configuration] eq {}} {
            error "no CGA environment application configuration is active"
        }
        set application_configuration [::tclwire::cga::envs::application_configuration]
        if {$application_configuration eq {}} {
            error "no CGA environment application configuration is active"
        }
        return $application_configuration
    }

    method configuration {{key {}}} {
        set application_configuration [my application_configuration]
        set configuration [$application_configuration environment_configuration [my name]]
        if {$key eq {}} {
            return $configuration
        }
        if {![dict exists $configuration $key]} {
            error "environment '[my name]' configuration has no key: $key"
        }
        return [dict get $configuration $key]
    }

    method install {} {
        if {$installed} {
            return
        }
        my do_install
        set installed 1
        return
    }

    method uninstall {} {
        if {!$installed} {
            return
        }
        my do_uninstall
        set installed 0
        return
    }

    method do_install {} {
        return
    }

    method do_uninstall {} {
        return
    }
}

namespace eval ::tclwire::environment {
    namespace export command load object application_class application_file
    namespace ensemble create

    proc command {environment} {
        if {[string match ::* $environment]} {
            return $environment
        }
        return ::tclwire::envs::$environment
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
        if {$environment eq {}} {
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
        object $command
        return $command
    }

    proc application_class {application_id descriptor} {
        if {![dict exists $descriptor environment]} {
            return {}
        }
        set environments [dict get $descriptor environment]
        if {[catch {llength $environments}]} {
            error "application '$application_id' environment must be a list"
        }

        set application_class {}
        foreach environment $environments {
            set command [load $environment]
            set environment_object [object $command]
            set candidate [$environment_object application_class]
            if {$candidate eq {}} {
                continue
            }
            if {$application_class ne {} && $candidate ne $application_class} {
                error "application '$application_id' environments define multiple application classes"
            }
            set application_class $candidate
        }
        return $application_class
    }

    proc application_file {application_id descriptor} {
        if {![dict exists $descriptor environment]} {
            return {}
        }
        set environments [dict get $descriptor environment]
        if {[catch {llength $environments}]} {
            error "application '$application_id' environment must be a list"
        }

        set application_file {}
        foreach environment $environments {
            set command [load $environment]
            set environment_object [object $command]
            set candidate [$environment_object application_file]
            if {$candidate eq {}} {
                continue
            }
            set candidate [file normalize $candidate]
            if {$application_file ne {} && $candidate ne $application_file} {
                error "application '$application_id' environments define multiple application files"
            }
            set application_file $candidate
        }
        return $application_file
    }
}

package provide tclwire::environment 0.1
