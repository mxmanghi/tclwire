package require Tcl 8.6

namespace eval ::tcl_highlight {
    variable commands
    set commands [dict create]

    foreach command {
        after append apply array binary break case catch cd chan clock close
        concat continue coroutine dict encoding eof error eval exec exit expr
        fblocked fconfigure fcopy file fileevent flush for foreach format gets
        glob global history if incr info interp join lappend lassign lindex
        linsert list llength load lrange lrepeat lreplace lreverse lsearch
        lset lsort namespace open package pid proc puts pwd read regexp regsub
        rename return scan seek set socket source split string subst switch
        tailcall tell throw time trace try unload unset update uplevel upvar
        variable vwait while yield yieldto zlib

        oo::class oo::copy oo::define oo::objdefine oo::object
        constructor destructor export filter forward method mixin my next
        self superclass unexport variable

        itcl::body itcl::class itcl::code itcl::configbody itcl::delete
        itcl::delete_helper itcl::ensemble itcl::find itcl::is
        itcl::local itcl::scope
        common component delegate inherit itk_component itk_initialize
        private protected public
    } {
        dict set commands $command 1
    }
}

proc ::tcl_highlight::html_escape {text} {
    return [string map {& &amp; < &lt; > &gt; \" &quot;} $text]
}

proc ::tcl_highlight::span {class body} {
    return "<span class=\"$class\">$body</span>"
}

proc ::tcl_highlight::is_space {character} {
    return [expr {$character eq " "  || $character eq "\t" ||
                  $character eq "\r" || $character eq "\f" || $character eq "\v"}]
}

proc ::tcl_highlight::is_bare_delimiter {character} {
    return [expr {$character eq ""   || $character eq "\n" ||
                  $character eq ";"  || [is_space $character] ||
                  $character eq "\{" || $character eq "\}" ||
                  $character eq "\[" || $character eq "\]" ||
                  $character eq "\""}]
}

proc ::tcl_highlight::namespace_prefix_end {text} {
    set last [string last :: $text]
    if {$last < 0} {
        return -1
    }
    return [expr {$last + 1}]
}

proc ::tcl_highlight::highlight_qualified_name {text} {
    set escaped [html_escape $text]
    set end [namespace_prefix_end $text]
    if {$end < 0} { return $escaped }

    set namespace [html_escape [string range $text 0 $end]]
    set tail [html_escape [string range $text [expr {$end + 1}] end]]
    return "[span tcl-namespace $namespace]$tail"
}

proc ::tcl_highlight::highlight_word {word command_position} {
    variable commands

    set body [highlight_qualified_name $word]
    if {$command_position && [dict exists $commands $word]} {
        return [span tcl-command $body]
    }
    if {[namespace_prefix_end $word] >= 0} {
        return [span tcl-name $body]
    }
    return [html_escape $word]
}

proc ::tcl_highlight::variable_end {source start} {
    set length [string length $source]
    set index [expr {$start + 1}]
    if {$index >= $length} {
        return $start
    }

    if {[string index $source $index] eq "\{"} {
        set close [string first \} $source [expr {$index + 1}]]
        if {$close < 0} {
            return [expr {$length - 1}]
        }
        return $close
    }

    while {$index < $length} {
        set character [string index $source $index]
        if {![regexp {[[:alnum:]_:]} $character]} {
            break
        }
        incr index
    }

    if {$index < $length && [string index $source $index] eq "("} {
        set close [string first ")" $source [expr {$index + 1}]]
        if {$close >= 0} {
            set index [expr {$close + 1}]
        }
    }

    return [expr {$index - 1}]
}

proc ::tcl_highlight::highlight_variable {source start} {
    set end [variable_end $source $start]
    set variable [string range $source $start $end]

    if {[regexp {^\$\{(.+)\}$} $variable -> name]} {
        set body "\$\{[highlight_qualified_name $name]\}"
    } elseif {[regexp {^\$(.+)$} $variable -> name]} {
        set body "\$[highlight_qualified_name $name]"
    } else {
        set body [html_escape $variable]
    }

    return [list [span tcl-variable $body] $end]
}

proc ::tcl_highlight::highlight_string {source start} {
    set length [string length $source]
    set index [expr {$start + 1}]
    set output [span tcl-string {&quot;}]

    while {$index < $length} {
        set character [string index $source $index]
        if {$character eq "\\"} {
            if {$index + 1 < $length} {
                append output [span tcl-string \
                    [html_escape [string range $source $index [expr {$index + 1}]]]]
                incr index 2
            } else {
                append output [span tcl-string "\\"]
                incr index
            }
            continue
        }
        if {$character eq "\""} {
            append output [span tcl-string {&quot;}]
            return [list $output $index]
        }
        if {$character eq "\$"} {
            lassign [highlight_variable $source $index] variable end
            append output $variable
            set index [expr {$end + 1}]
            continue
        }

        set literal_start $index
        while {$index < $length} {
            set character [string index $source $index]
            if {$character eq "\\" || $character eq "\"" ||
                    $character eq "\$"} {
                break
            }
            incr index
        }
        append output [span tcl-string \
            [html_escape [string range $source $literal_start \
                [expr {$index - 1}]]]]
    }

    return [list $output [expr {$length - 1}]]
}

proc ::tcl_highlight::highlight {source} {
    set length [string length $source]
    set index 0
    set output {}
    set command_start 1
    set command_word_pending 1

    while {$index < $length} {
        set character [string index $source $index]

        if {$character eq "\n"} {
            append output "\n"
            set command_start 1
            set command_word_pending 1
            incr index
            continue
        }
        if {[is_space $character]} {
            append output [html_escape $character]
            incr index
            continue
        }
        if {$character eq ";"} {
            append output [span tcl-punctuation {;}]
            set command_start 1
            set command_word_pending 1
            incr index
            continue
        }
        if {$character eq "#" && $command_start} {
            set newline [string first "\n" $source $index]
            if {$newline < 0} {
                set newline $length
            }
            append output [span tcl-comment \
                [html_escape [string range $source $index [expr {$newline - 1}]]]]
            set index $newline
            continue
        }
        if {$character eq "\$"} {
            lassign [highlight_variable $source $index] variable end
            append output $variable
            set command_start 0
            set index [expr {$end + 1}]
            continue
        }
        if {$character eq "\""} {
            lassign [highlight_string $source $index] string end
            append output $string
            set command_start 0
            set command_word_pending 0
            set index [expr {$end + 1}]
            continue
        }
        if {$character eq "\{" || $character eq "\}" ||
                $character eq "\[" || $character eq "\]"} {
            append output [span tcl-punctuation [html_escape $character]]
            set command_start [expr {$character eq "\["}]
            set command_word_pending [expr {$character eq "\["}]
            incr index
            continue
        }

        set start $index
        while {$index < $length &&
                ![is_bare_delimiter [string index $source $index]]} {
            incr index
        }
        set word [string range $source $start [expr {$index - 1}]]
        append output [highlight_word $word $command_word_pending]
        set command_start 0
        set command_word_pending 0
    }

    return $output
}

proc ::tcl_highlight::stylesheet {} {
    return {
.tcl-command { color: var(--syntax-command); font-weight: 600; }
.tcl-variable { color: var(--syntax-variable); }
.tcl-namespace { color: var(--syntax-namespace); }
.tcl-name { color: var(--syntax-name); }
.tcl-comment { color: var(--syntax-comment); font-style: italic; }
.tcl-string { color: var(--syntax-string); }
.tcl-punctuation { color: var(--syntax-punctuation); }
}
}

if {[info exists ::argv0] && [file normalize $::argv0] eq
        [file normalize [info script]]} {
    set source [read stdin]
    puts -nonewline [::tcl_highlight::highlight $source]
}
