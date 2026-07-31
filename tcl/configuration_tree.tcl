# configuration_tree.tcl --
#
# Structured ASCII rendering helpers for runtime configuration dictionaries.
#
# `::tclwire::configuration tree` renders Tcl dictionaries; it does not
# introspect TclOO objects by itself.  Application code therefore has to pass
# a dictionary snapshot or serialized envelope.  In a request handler, including
# a Rivet script, the current worker's application configuration object is:
#
#   ::tclwire::app::configuration
#
# To show the current application descriptor values:
#
#   package require tclwire::configuration_tree 0.1
#   puts "<pre>"
#   puts [::tclwire::configuration tree \
#       [[::tclwire::app::configuration] snapshot]]
#   puts "</pre>"
#
# To include the envelope metadata as well as the values:
#
#   puts [::tclwire::configuration tree \
#       [[::tclwire::app::configuration] serialize]]
#
# Passing `[::tclwire::app::configuration]` directly will not render the
# application configuration; that value is an object command, not a dictionary.

namespace eval ::tclwire {}

namespace eval ::tclwire::configuration {
    variable dict_fields {
        application_configs applications configure pool_policy values
    }
    variable list_fields {
        application_paths args environment hosts paths server_chores services startservers
    }

    proc tree {configuration {sink {}}} {
        set lines [render_node configuration $configuration {} {} 1]
        set text [join $lines \n]
        if {$sink ne {}} {
            emit_lines $lines $sink
        }
        return $text
    }

    proc emit_lines {lines sink} {
        foreach line $lines {
            if {[lindex $sink 0] eq "apply"} {
                {*}$sink $line
                continue
            }
            set command {}
            set replaced 0
            foreach word $sink {
                if {[string first "%s" $word] >= 0} {
                    lappend command [string map [list %s $line] $word]
                    set replaced 1
                } else {
                    lappend command $word
                }
            }
            if {!$replaced} {
                lappend command $line
            }
            {*}$command
        }
        return [llength $lines]
    }

    proc render_node {label value prefix path is_last} {
        set line_prefix [branch_prefix $prefix $is_last]
        set child_prefix [child_prefix $prefix $is_last]
        set field [lindex $path end]
        set is_root [expr {[llength $path] == 0}]
        if {$is_root} {
            set line_prefix {}
            set child_prefix {}
        }

        if {[should_render_dict $field $value]} {
            set lines [list "${line_prefix}${label}"]
            set keys [dict keys $value]
            set count [llength $keys]
            set index 0
            foreach key $keys {
                incr index
                set child [dict get $value $key]
                lappend lines {*}[render_node $key $child $child_prefix \
                    [linsert $path end $key] [expr {$index == $count}]]
            }
            return $lines
        }

        if {[should_render_list $field $value]} {
            set lines [list "${line_prefix}${label}"]
            set count [llength $value]
            for {set index 0} {$index < $count} {incr index} {
                set child [lindex $value $index]
                lappend lines {*}[render_node "\[$index\]" $child $child_prefix \
                    [linsert $path end $index] [expr {$index == $count - 1}]]
            }
            return $lines
        }

        return [list "${line_prefix}${label} = [format_scalar $value]"]
    }

    proc branch_prefix {prefix is_last} {
        if {$is_last} {
            return "${prefix}`-- "
        }
        return "${prefix}|-- "
    }

    proc child_prefix {prefix is_last} {
        if {$is_last} {
            return "${prefix}    "
        }
        return "${prefix}|   "
    }

    proc should_render_dict {field value} {
        variable dict_fields
        if {$field in $dict_fields} {
            return [is_dict $value]
        }
        if {[is_dict $value] && ![should_render_list $field $value]} {
            return 1
        }
        return 0
    }

    proc should_render_list {field value} {
        variable list_fields
        if {[catch {llength $value}]} {
            return 0
        }
        if {$field in $list_fields} {
            return 1
        }
        if {![is_dict $value] && [llength $value] > 1} {
            return 1
        }
        return 0
    }

    proc is_dict {value} {
        if {[catch {dict size $value}]} {
            return 0
        }
        set seen [dict create]
        dict for {key item} $value {
            if {[llength $key] != 1 || [dict exists $seen $key]} {
                return 0
            }
            dict set seen $key 1
        }
        return 1
    }

    proc format_scalar {value} {
        if {$value eq {}} {
            return {{}}
        }
        if {[string first \n $value] >= 0} {
            return [list $value]
        }
        return $value
    }

    namespace export tree emit_lines
    namespace ensemble create
}

package provide tclwire::configuration_tree 0.1
