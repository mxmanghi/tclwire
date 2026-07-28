# runtime_chores.tcl --
#
# Runtime chore registration adapters.
#
# This module converts normalized runtime configuration into scheduler chore specs.
# 
# Server chores are singleton runtime tasks and carry a server_context
# envelope for classes that opt into ::tclwire::ServerChore. Application chores
# are per-application tasks and carry an application_context dictionary
# containing application_id, serialized ApplicationConfiguration, and TPBA
# pool_key for classes that opt into ::tclwire::ApplicationChore.
#

namespace eval ::tclwire::runtime {
    proc stripped_server_chore_specs {config} {
        if {![dict exists $config server_chores]} { return {} }

        set specs {}
        foreach spec [dict get $config server_chores] {
            foreach field {server_context application_context} {
                if {[dict exists $spec $field]} {
                    dict unset spec $field
                }
            }
            lappend specs $spec
        }
        return $specs
    }

    proc application_configuration_envelopes {config} {
        variable application_dispatcher

        set dispatcher $application_dispatcher
        set destroy_dispatcher 0
        if {$dispatcher eq {}} {
            set dispatcher [::tclwire::ApplicationDispatcher new $config]
            set destroy_dispatcher 1
        }
        set envelopes [dict create]
        try {
            dict for {application_id descriptor} [dict get $config applications] {
                set configuration [$dispatcher application_configuration $application_id]
                dict set envelopes $application_id [$configuration serialize]
            }
        } finally {
            if {$destroy_dispatcher} {
                $dispatcher destroy
            }
        }
        return $envelopes
    }

    proc server_configuration_envelope {config} {
        set values $config
        foreach field {applications server_chores} {
            if {[dict exists $values $field]} {
                dict unset values $field
            }
        }
        return [dict create type                tclwire.server_configuration \
                            version             1 \
                            values              $values \
                            server_chores       [stripped_server_chore_specs $config] \
                            application_configs [application_configuration_envelopes $config]]
    }

    proc config_has_application_chores {config} {
        dict for {application_id descriptor} [dict get $config applications] {
            if {[dict exists $descriptor chore] && ([dict get $descriptor chore] ne {})} {
                return 1
            }
        }
        return 0
    }

    proc config_has_server_chores {config} {
        return [expr {[dict exists $config server_chores] && [llength [dict get $config server_chores]] > 0}]
    }

    proc server_chore_specs {config} {
        if {![dict exists $config server_chores]} {
            return {}
        }
        set server_context [server_configuration_envelope $config]
        set specs {}
        foreach spec [dict get $config server_chores] {
            if {![dict exists $spec paths]} {
                set paths [list [pwd]]
                if {[dict exists $config libdir]} {
                    lappend paths [dict get $config libdir]
                }
                lappend paths [::tclwire::support project_root]
                dict set spec paths [unique_directories $paths]
            }
            dict set spec server_context $server_context
            lappend specs $spec
        }
        return $specs
    }

    proc application_chore_specs {config} {
        variable application_dispatcher

        set dispatcher $application_dispatcher
        set destroy_dispatcher 0
        if {$dispatcher eq {}} {
            set dispatcher [::tclwire::ApplicationDispatcher new $config]
            set destroy_dispatcher 1
        }
        set specs {}
        try {
            dict for {application_id descriptor} [dict get $config applications] {
                set application [$dispatcher application $application_id]
                if {![dict exists $application chore] ||
                        [dict get $application chore] eq {}} {
                    continue
                }
                set class {}
                if {[dict exists $application chore_class]} {
                    set class [dict get $application chore_class]
                }
                set configuration [$dispatcher application_configuration $application_id]
                set pool_key app:[string tolower [string trim $application_id]]
                lappend specs [dict create \
                    name application:$application_id \
                    file [dict get $application chore] \
                    class $class \
                    paths [dict get $application application_paths] \
                    application_context [dict create \
                        application_id $application_id \
                        application_config [$configuration serialize] \
                        pool_key $pool_key] \
                    application_id $application_id]
            }
        } finally {
            if {$destroy_dispatcher} {
                $dispatcher destroy
            }
        }
        return $specs
    }
}
