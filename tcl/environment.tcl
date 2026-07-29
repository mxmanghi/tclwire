# environment.tcl --
#
# Shared inspection helpers for application environment contracts.

namespace eval ::tclwire::environment {
    namespace export command load application_class
    namespace ensemble create

    proc command {environment} {
        if {[string match ::* $environment]} {
            return $environment
        }
        return ::tclwire::envs::$environment
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
            if {[info commands ${command}::application_class] eq {}} {
                continue
            }
            set candidate [${command}::application_class]
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
}

package provide tclwire::environment 0.1
