# http_message.tcl --
#
# Reusable HTTP message syntax helpers.

namespace eval ::tclwire {}

namespace eval ::tclwire::http::message {

    # split_parameters value
    #
    # Split a semicolon-separated HTTP field value while preserving semicolons
    # inside quoted strings. This is intended for structured values such as
    # Content-Type and Content-Disposition.
    #
    # Examples:
    #
    #   split_parameters {text/plain; charset=utf-8}
    #   -> {text/plain charset=utf-8}
    #
    #   split_parameters {form-data; name="a;b"; filename="x.txt"}
    #   -> {form-data {name="a;b"} {filename="x.txt"}}
    #
    # The returned value is a Tcl list of trimmed fields. Quoted values are not
    # unquoted by this procedure.
    proc split_parameters {value} {
        set fields {}
        set current {}
        set in_quote 0
        set escaped 0

        foreach character [split $value {}] {
            if {$escaped} {
                append current $character
                set escaped 0
                continue
            }
            if {$in_quote && $character eq "\\"} {
                append current $character
                set escaped 1
                continue
            }
            if {$character eq "\""} {
                append current $character
                set in_quote [expr {!$in_quote}]
                continue
            }
            if {!$in_quote && $character eq ";"} {
                lappend fields [string trim $current]
                set current {}
                continue
            }
            append current $character
        }

        if {$in_quote || $escaped} {
            error "invalid quoted HTTP header parameter"
        }
        lappend fields [string trim $current]
        return $fields
    }

    # unquote_parameter value
    #
    # Remove surrounding HTTP quoted-string delimiters and process backslash
    # escapes. Unquoted values are returned unchanged after trimming.
    #
    # Examples:
    #
    #   unquote_parameter {"AaB03x"}
    #   -> AaB03x
    #
    #   unquote_parameter {"file \"one\".txt"}
    #   -> {file "one".txt}
    #
    #   unquote_parameter utf-8
    #   -> utf-8
    proc unquote_parameter {value} {
        set value [string trim $value]
        if {[string length $value] < 2 ||
                [string index $value 0] ne {"} ||
                [string index $value end] ne {"}} {
            return $value
        }

        set unquoted {}
        set escaped 0
        foreach character [split [string range $value 1 end-1] {}] {
            if {$escaped} {
                append unquoted $character
                set escaped 0
            } elseif {$character eq "\\"} {
                set escaped 1
            } else {
                append unquoted $character
            }
        }
        if {$escaped} {
            error "invalid quoted HTTP header parameter"
        }
        return $unquoted
    }

    # parse_content_type value
    #
    # Parse a Content-Type field value into a normalized media type and a
    # dictionary of lowercase parameter names. Parameter values are unquoted.
    #
    # Examples:
    #
    #   parse_content_type {Text/Plain; Charset=utf-8}
    #   -> {media_type text/plain parameters {charset utf-8}}
    #
    #   parse_content_type {multipart/form-data; boundary="AaB03x"}
    #   -> {media_type multipart/form-data parameters {boundary AaB03x}}
    #
    # The return value is a dictionary with keys `media_type` and `parameters`.
    proc parse_content_type {value} {
        set fields [split_parameters $value]
        set media_type [string tolower [string trim [lindex $fields 0]]]
        if {$media_type eq {}} {
            error "missing Content-Type media type"
        }

        set parameters [dict create]
        foreach field [lrange $fields 1 end] {
            if {$field eq {}} {
                continue
            }
            set separator [string first = $field]
            if {$separator < 1} {
                error "invalid Content-Type parameter"
            }
            set name [string tolower [string trim \
                [string range $field 0 $separator-1]]]
            set parameter_value [unquote_parameter \
                [string range $field $separator+1 end]]
            if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name]} {
                error "invalid Content-Type parameter name"
            }
            dict set parameters $name $parameter_value
        }

        return [dict create media_type $media_type parameters $parameters]
    }

    # header_value headers name ?default_value?
    #
    # Read one value from a normalized HTTP header dictionary. Header names are
    # matched case-insensitively by lowercasing the requested name; callers pass
    # dictionaries like those produced by HttpProtocolSession parse_request or
    # multipart part parsing.
    #
    # Examples:
    #
    #   header_value {content-type text/plain host example.test} Content-Type
    #   -> text/plain
    #
    #   header_value {host example.test} Content-Type {}
    #   -> {}
    #
    #   header_value {host example.test} Content-Type application/octet-stream
    #   -> application/octet-stream
    proc header_value {headers name {default_value {}}} {
        set name [string tolower $name]
        if {[dict exists $headers $name]} {
            return [dict get $headers $name]
        }
        return $default_value
    }

    namespace export parse_content_type header_value split_parameters \
        unquote_parameter
    namespace ensemble create
}

package provide tclwire::http::message 0.1
