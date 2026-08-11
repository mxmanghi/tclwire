#!/usr/bin/env tclsh

set project_root [file normalize [file join [file dirname [info script]] ".."]]

lappend ::auto_path $project_root

package require tclwire::runtime 0.1
package require tclwire::configuration_tree 0.1

set config_file [lindex $argv 0]
if {$config_file eq {}} {
  set config_file tclwire.toml.example
}

set app_id [lindex $argv 1]

set config [::tclwire::runtime prepare_config [list --config $config_file]]
set dispatcher [::tclwire::ApplicationDispatcher new $config]

try {
    if {$app_id eq {}} {
      set app_id [dict get $config default_application]
    }

    set application_config [$dispatcher application_configuration $app_id]

    puts [list object $application_config \
               type [info object class $application_config] \
               app_id [$application_config id]]

    puts [::tclwire::configuration tree [$application_config serialize]]
} finally {
  $dispatcher destroy
}

