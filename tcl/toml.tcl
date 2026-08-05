# toml.tcl --
#     Rudimentary start of a parser for TOML configuration files
#     See https:/github.com/toml-lang/toml for more information on this type of files
#
#     TOML is supposed to be easy to parse, but there are tricky bits :(
#
#     For the moment:
#     - Tricky comments are ignored
#     - Tricky names are ignored, like 'a "bc"' = "xxx"
#
#     TODO:
#     - arrays of tables
#     - inline tables
#     - substitutions
#     - tricky bits, but they can wait
#
#     Not supported at the moment:
#     - arrays of tables
#     - nested arrays
#     - inline tables
#     - arrays with ' (trickiness in the regular expressions)
#     - arrays with embedded comments
#

# From the Wiki, Donal's implementation
proc pdict {dict {pattern *}} {
   global outfile
   set longest [tcl::mathfunc::max 0 {*}[lmap key [dict keys $dict $pattern] {string length $key}]]
   dict for {key value} [dict filter $dict key $pattern] {
      puts $outfile [format "%-${longest}s = %s" $key $value]
   }
}

package provide tomlfile 0.1

namespace eval ::toml {
    variable infile
}

proc ::toml::multilineQuote {string} {
    set delimiter [string range $string 0 2]
    if {$delimiter eq "\"\"\"" || $delimiter eq "'''"} {
        return $delimiter
    }
    return ""
}

proc ::toml::multilineTerminator {string delimiter} {
    return [string first $delimiter $string 3]
}

# stripComment --
#     Strip off the comment - watch out for embedded "#" characters
#
# Arguments:
#     line            Line to be examined
#
# Returns:
#     Line with the comment removed
#
proc ::toml::stripComment {line} {
    set quote ""
    set quotelen 0
    set escaped 0

    for {set index 0} {$index < [string length $line]} {incr index} {
        set character [string index $line $index]

        if {$quote eq ""} {
            if {$character eq "#"} {
                return [string range $line 0 $index-1]
            }
            set delimiter [string range $line $index $index+2]
            if {$delimiter eq "\"\"\"" || $delimiter eq "'''"} {
                set quote $character
                set quotelen 3
                incr index 2
                continue
            }
            if {$character eq "\"" || $character eq "'"} {
                set quote $character
                set quotelen 1
            }
            continue
        }

        if {$quotelen == 3} {
            if {[string range $line $index $index+2] eq [string repeat $quote 3]} {
                set quote ""
                set quotelen 0
                incr index 2
            }
            continue
        }

        if {$quote eq "\""} {
            if {$escaped} {
                set escaped 0
                continue
            }
            if {$character eq "\\"} {
                set escaped 1
                continue
            }
        }

        if {$character eq $quote} {
            set quote ""
            set quotelen 0
        }
    }

    return $line
}

# stripQuotes --
#     Strip off the quoting characters (' and ")
#
# Arguments:
#     string          String to be examined
#
# Returns:
#     String with the outer quoting characters removed
#
proc ::toml::stripQuotes {string} {

    if { [string index $string 0] eq "'" && [string index $string end] eq "'" } {
        set string [string range $string 1 end-1]
    } elseif { [string index $string 0] eq "\"" && [string index $string end] eq "\"" } {
        set string [string range $string 1 end-1]
    }

    return $string
}

# loadAllLines --
#     Load all lines up to the end for literal strings
#
# Arguments:
#     string          The first part of the value
#
# Returns:
#     String with the outer quoting characters removed
#
proc ::toml::loadAllLines {string} {
    variable infile

    set quoting [multilineQuote $string]
    if {$quoting eq ""} {
        return -code error "Syntax error in multiline string: $string"
    }

    #
    # Do we need to load more?
    #
    set terminator [multilineTerminator $string $quoting]

    if { $terminator < 0 } {
        while { [gets $infile line] >= 0 } {
            append string "\n$line"
            set terminator [multilineTerminator $string $quoting]

            if { $terminator >= 0 } {
                break
            }
        }
    }

    if { $terminator < 0 } {
        return -code error "Unterminated multiline string"
    }

    set value [string range $string 3 $terminator-1]
    if { [string index $value 0] eq "\n" } {
        set value [string range $value 1 end]
    }
    return $value
}

# makeList --
#     Turn a string of comma-separated values into a proper list
#
# Arguments:
#     string          String to be converted
#
# Returns:
#     List of values
#
proc ::toml::makeList {string} {
    set newlist {}

    if { [string first "\"" $string] < 0 && [string first "'" $string] < 0 } {
        set newlist [split $string ,]
    } else {
        #
        # Possibility of embedding commas, use the code from the CSV package
        #

        set sepChar ,
        set delChar "\""
        set sepRE \[\[.${sepChar}.]]
        set delRE \[\[.${delChar}.]]

        set line $string
        if { [string index $string end] eq "," } {
            set line [string range $string 0 end-1]
        }

        regsub -- "$sepRE${delRE}${delRE}$" $line $sepChar\0${delChar}${delChar}\0 line
        regsub -- "^${delRE}${delRE}$sepRE" $line \0${delChar}${delChar}\0$sepChar line
        regsub -all -- {(^${delChar}|${delChar}$)} $line \0 line

        set line [string map [list \
                $sepChar${delChar}${delChar}${delChar} $sepChar\0${delChar} \
                ${delChar}${delChar}${delChar}$sepChar ${delChar}\0$sepChar \
                ${delChar}${delChar}           ${delChar} \
                ${delChar}             \0 \
                ] $line]

        set end 0
        while {[regexp -indices -start $end -- {(\0)[^\0]*(\0)} $line \
                -> start end]} {
            set start [lindex $start 0]
            set end   [lindex $end 0]
            set range [string range $line $start $end]
            if {[string first $sepChar $range] >= 0} {
                set line [string replace $line $start $end \
                        [string map [list $sepChar \1] $range]]
            }
            incr end
        }
        set line [string map [list $sepChar \0 \1 $sepChar \0 {} ] $line]

        set newlist [::split $line \0]
    }

    return $newlist
}

# loadArray --
#     Load all lines up to the end for arrays
#
# Arguments:
#     string          The first part of the value
#
# Returns:
#     String with the outer quoting characters removed
#
proc ::toml::loadArray {string} {
    variable infile

    set quoting "\]"

    set arrayValues [makeList [string range $string 1 end]]

    #
    # Do we need to load more?
    #
    if { [string index $string end] ne $quoting } {

        while { [gets $infile line] >= 0 } {
            set valuestring [string trim $line]
            if { [string index $valuestring end] eq "\]" } {
                set valuestring [string trim [string range $string 0 end-1]] ;# Here we possibly strip off too much - nested arrays
            }

            set arrayValues [concat $arrayValues [makeList $valuestring]]

            if { [string index $line end] eq $quoting } {
                break
            }
        }
    }

    return [list $arrayValues]
}

# keyValuePair --
#     Split the line into a key-value pair
#
# Arguments:
#     line            Line to be examined
#
# Returns:
#     List of two elements, the "key" and the (possibly partial) "value"
#
proc ::toml::keyValuePair {line} {
    set poseq [string first "=" $line]
    set key   [string trim [string range $line 0 $poseq-1]]
    set value [string trim [string range $line $poseq+1 end]]

    #
    # Get the actual key and check for emptiness
    #
    set key [stripQuotes [string map {" " ""} $key]]

    if { [string trim $key] eq "" } {
        return -code error "Syntax error in key/value: key is empty - $line"
    }
    if { $value eq "" } {
        return -code error "Syntax error in key/value: value is empty - $line"
    }

    #
    # Is this a value that may span several lines? If so, load all lines
    #
    if { [multilineQuote $value] ne "" } {
        set value [loadAllLines $value]

    } elseif { [string index $value 0] eq "\[" } {
        set value [loadArray $value]
    } else {
        set value [stripQuotes $value]
    }

    return [list $key $value]
}

# tableName --
#     Extract the name of the table
#
# Arguments:
#     line            Line to be examined
#
# Returns:
#     Name of the new table
#
proc ::toml::tableName {line} {
    set posopen  [string first \[ $line]
    set posclose [string first \] $line]

    if { $posopen < -1 || $posclose < -1 || $posclose < $posopen } {
        return -code error "Syntax error in table name: $line"
    }

    set name [string range $line $posopen+1 $posclose-1]
    set components {}
    set component ""
    set quote ""
    set escaped 0

    for {set index 0} {$index < [string length $name]} {incr index} {
        set character [string index $name $index]
        if {$quote eq ""} {
            if {$character eq "."} {
                lappend components [stripQuotes [string trim $component]]
                set component ""
                continue
            }
            if {$character eq "\"" || $character eq "'"} {
                set quote $character
            }
            append component $character
            continue
        }

        append component $character
        if {$quote eq "\""} {
            if {$escaped} {
                set escaped 0
                continue
            }
            if {$character eq "\\"} {
                set escaped 1
                continue
            }
        }
        if {$character eq $quote} {
            set quote ""
        }
    }
    if {$quote ne ""} {
        return -code error "Syntax error in table name: $line"
    }
    lappend components [stripQuotes [string trim $component]]
    if {{} in $components} {
        return -code error "Syntax error in table name: $line"
    }
    return $components
}

# tomlParse --
#     Parse the TOML file and return the contents as a dictionary
#
# Arguments:
#     tomlfile           The name of the TOML file
#
# Result:
#     A dictionary containing the contents of the TOML file
#
# Notes:
#     - If the TOML file contains syntax errors, then an error is raised.
#     - Not all valid TOML files are read correctly. There are a number of limitations.
#
proc ::toml::tomlParse {tomlfile} {
    variable infile

    set infile [open $tomlfile]

    set contents [dict create]
    set table ""

    try {
        while { [gets $::toml::infile line] >= 0 } {
            set line [::toml::stripComment $line]

            if { [string first = $line] >= 0 } {
                set keyvalue [::toml::keyValuePair $line]

                if { [dict exists $contents {*$table} {*}[lindex $keyvalue 0]] } {
                    return -code error "Duplicate key: {*}table [lindex $keyvalue 0]"
                } else {
                    dict set contents {*}$table {*}$keyvalue
                }
            } else {
                if { [string first \[ $line] >= 0 } {
                    set table [::toml::tableName $line]
                } else {
                    if { [string trim $line] ne "" } {
                        return -code error "Unknown syntax: $line"
                    }
                }
            }
        }
    } finally {
        close $infile
    }

    return $contents
}

# test --
#     Quick test of the package's one public command

#set contents [::toml::tomlParse "example.toml"]

#puts $outfile \nResult:"
#puts $outfile $contents

#puts $outfile [dict get $contents servers alpha]
#puts $outfile [dict get $contents servers beta ip]
#pdict $contents
