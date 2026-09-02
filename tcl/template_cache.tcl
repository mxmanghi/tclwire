# template_cache.tcl --
#
# Cache parsed template scripts by normalized file path and optional loader
# qualifiers, such as a source encoding.

namespace eval ::tclwire {}

oo::class create ::tclwire::TemplateCache {
    variable loader
    variable cache_policy
    variable entries

    constructor {template_loader {policy always}} {
        set loader $template_loader
        set entries [dict create]
        my policy $policy
    }

    method policy {{new_policy {}}} {
        if {$new_policy eq {}} {
            return $cache_policy
        }
        if {$new_policy ni {always mtime immutable}} {
            error "invalid template cache policy \"$new_policy\": must be always, mtime, or immutable"
        }
        set cache_policy $new_policy
        return $cache_policy
    }

    method get {path args} {
        set path [file normalize $path]
        set key [list $path {*}$args]
        switch -- $cache_policy {
            always {
                return [my load $path {*}$args]
            }
            mtime {
                set mtime [file mtime $path]
                if {[dict exists $entries $key] &&
                    [dict get $entries $key mtime] == $mtime} {
                    return [dict get $entries $key script]
                }
                set script [my load $path {*}$args]
                dict set entries $key [dict create mtime $mtime script $script]
                return $script
            }
            immutable {
                if {![dict exists $entries $key]} {
                    dict set entries $key [dict create script [my load $path {*}$args]]
                }
                return [dict get $entries $key script]
            }
        }
    }

    method clear {args} {
        if {[llength $args] == 0} {
            set entries [dict create]
        } else {
            set path [file normalize [lindex $args 0]]
            set key [list $path {*}[lrange $args 1 end]]
            dict unset entries $key
        }
        return
    }

    method load {path args} {
        tailcall {*}$loader $path {*}$args
    }
}

package provide tclwire::template_cache 0.1
