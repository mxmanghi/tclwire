#!/usr/bin/env tclsh

package require Tcl 8.6

namespace eval ::mk2html {
    variable default_input doc
    variable default_output /tmp/tclwire
}

proc ::mk2html::usage {{channel stdout}} {
    variable default_input
    variable default_output

    puts $channel "Usage: [file tail $::argv0] ?--input PATH? ?--output DIR?"
    puts $channel ""
    puts $channel "Convert Markdown files to standalone HTML pages."
    puts $channel ""
    puts $channel "Options:"
    puts $channel "  --input PATH   Read a Markdown file or directory (default: $default_input)"
    puts $channel "  --output DIR   Write generated files to DIR (default: $default_output)"
    puts $channel "  -h, --help     Show this help"
}

proc ::mk2html::parse_arguments {arguments} {
    variable default_input
    variable default_output
    set input $default_input
    set output $default_output

    for {set index 0} {$index < [llength $arguments]} {incr index} {
        set argument [lindex $arguments $index]
        switch -glob -- $argument {
            --input {
                incr index
                if {$index >= [llength $arguments]} {
                    error "option --input requires a path"
                }
                set input [lindex $arguments $index]
            }
            --input=* {
                set input [string range $argument [string length "--input="] end]
                if {$input eq ""} {
                    error "option --input requires a path"
                }
            }
            --output {
                incr index
                if {$index >= [llength $arguments]} {
                    error "option --output requires a directory"
                }
                set output [lindex $arguments $index]
            }
            --output=* {
                set output [string range $argument [string length "--output="] end]
                if {$output eq ""} {
                    error "option --output requires a directory"
                }
            }
            -h -
            --help {
                usage
                exit 0
            }
            default {
                error "unknown option: $argument"
            }
        }
    }

    return [dict create input $input output [file normalize $output]]
}

proc ::mk2html::read_text_file {path} {
    set channel [open $path r]
    try {
        chan configure $channel -encoding utf-8 -translation lf
        return [read $channel]
    } finally {
        close $channel
    }
}

proc ::mk2html::write_text_file {path content} {
    set channel [open $path w]
    try {
        chan configure $channel -encoding utf-8 -translation lf
        puts -nonewline $channel $content
    } finally {
        close $channel
    }
}

proc ::mk2html::html_escape {text} {
    return [string map {& &amp; < &lt; > &gt; \" &quot;} $text]
}

proc ::mk2html::document_title {markdown path} {
    if {[regexp -line {^#[ \t]+(.+?)[ \t]*$} $markdown -> title]} {
        set title [regsub -all {[*_`]} $title ""]
        return [string trim $title]
    }

    return [string map {_ " " - " "} [file rootname [file tail $path]]]
}

proc ::mk2html::plain_text {markdown} {
    set text [regsub -all {!\[([^]]*)\]\([^)]+\)} $markdown {\1}]
    set text [regsub -all {\[([^]]+)\]\([^)]+\)} $text {\1}]
    set text [regsub -all {[*_`~]} $text ""]
    return [string trim [regsub -all {[ \t\r\n]+} $text " "]]
}

proc ::mk2html::document_summary {markdown} {
    set paragraph {}
    set in_fence 0

    foreach line [split $markdown \n] {
        set trimmed [string trim $line]
        if {[regexp {^(```|~~~)} $trimmed]} {
            set in_fence [expr {!$in_fence}]
            continue
        }
        if {$in_fence} {
            continue
        }
        if {$trimmed eq ""} {
            if {[llength $paragraph]} {
                break
            }
            continue
        }
        if {![llength $paragraph] && (
            [regexp {^#{1,6}[ \t]+} $trimmed] ||
            [regexp {^(Date|Updated):[ \t]+} $trimmed] ||
            [regexp {^([-*+] |[0-9]+\.[ \t]+|>|[|])} $trimmed]
        )} {
            continue
        }
        lappend paragraph $trimmed
    }

    set summary [plain_text [join $paragraph " "]]
    if {[string length $summary] > 180} {
        set summary "[string trimright [string range $summary 0 176]]..."
    }
    return $summary
}

proc ::mk2html::url_path {path} {
    return [string map [list [file separator] /] $path]
}

proc ::mk2html::relative_path {base path} {
    set base [file normalize $base]
    set path [file normalize $path]
    set prefix "${base}[file separator]"
    if {$path eq $base} {
        return {}
    }
    if {[string first $prefix $path] != 0} {
        error "$path is not below $base"
    }
    return [string range $path [string length $prefix] end]
}

proc ::mk2html::output_name {source source_root {preserve_path 1}} {
    if {$preserve_path} {
        set relative [relative_path $source_root $source]
    } else {
        set relative [file tail $source]
    }
    set output "[file rootname $relative].html"
    return [string tolower [url_path $output]]
}

proc ::mk2html::collect_documents {sources source_root {preserve_path 1}} {
    set documents {}
    set outputs [dict create]
    foreach source $sources {
        set markdown [read_text_file $source]
        set output [output_name $source $source_root $preserve_path]
        if {[dict exists $outputs $output]} {
            error "Markdown inputs map to the same output '$output': [dict get $outputs $output] and $source"
        }
        dict set outputs $output $source
        lappend documents [dict create \
            source $source \
            markdown $markdown \
            title [document_title $markdown $source] \
            summary [document_summary $markdown] \
            output $output]
    }
    return $documents
}

proc ::mk2html::relative_url {from_output to_output} {
    set from_parts {}
    foreach part [split [url_path [file dirname $from_output]] /] {
        if {$part ni {{} .}} {
            lappend from_parts $part
        }
    }
    set to_parts {}
    foreach part [split [url_path $to_output] /] {
        if {$part ni {{} .}} {
            lappend to_parts $part
        }
    }

    while {[llength $from_parts] && [llength $to_parts] &&
            [lindex $from_parts 0] eq [lindex $to_parts 0]} {
        set from_parts [lrange $from_parts 1 end]
        set to_parts [lrange $to_parts 1 end]
    }

    set result {}
    foreach ignored $from_parts {
        lappend result ..
    }
    set result [concat $result $to_parts]
    if {![llength $result]} {
        return [file tail $to_output]
    }
    return [join $result /]
}

proc ::mk2html::source_output_map {documents} {
    set mapping [dict create]
    foreach document $documents {
        dict set mapping [file normalize [dict get $document source]] \
            [dict get $document output]
    }
    return $mapping
}

proc ::mk2html::rewrite_markdown_links {
    html source current_output source_mapping
} {
    set pattern {href="([^":?#]+)\.md(#[^"]*)?"}
    set offset 0
    while {[regexp -indices -nocase -start $offset $pattern $html \
        match path fragment]} {
        lassign $match match_start match_end
        lassign $path path_start path_end
        set markdown_path [string range $html $path_start $path_end]
        set linked_source [file normalize \
            [file join [file dirname $source] "${markdown_path}.md"]]
        if {[dict exists $source_mapping $linked_source]} {
            set target [relative_url $current_output \
                [dict get $source_mapping $linked_source]]
        } else {
            set target "[string tolower \
                [file rootname [file tail $markdown_path]]].html"
        }
        if {[lindex $fragment 0] >= 0} {
            append target [string range $html {*}$fragment]
        }
        set replacement "href=\"$target\""
        set html [string replace $html $match_start $match_end $replacement]
        set offset [expr {$match_start + [string length $replacement]}]
    }
    return $html
}

proc ::mk2html::navigation {documents current_output} {
    set navigation {    <nav aria-label="Documentation">
      <a class="site-logo" href="@INDEX_URL@" aria-label="TclWire Documentation">
        <img src="@LOGO_URL@" alt="" width="220" height="132">
      </a>
      <ul>
}
    set index_url [relative_url $current_output index.html]
    set logo_url [relative_url $current_output "tclwire-logo-nav.png"]
    set navigation [string map [list @INDEX_URL@ $index_url @LOGO_URL@ $logo_url] \
        $navigation]
    set index_class [expr {$current_output eq "index.html" \
        ? { class="active"} : ""}]
    append navigation "        <li$index_class>\n"
    append navigation "          <a href=\"$index_url\">Overview</a>\n"
    append navigation {          <span>Documentation contents and summaries.</span>
        </li>
}
    foreach document $documents {
        set output [dict get $document output]
        set output_url [relative_url $current_output $output]
        set title [html_escape [dict get $document title]]
        set summary [html_escape [dict get $document summary]]
        set class [expr {$output eq $current_output ? { class="active"} : ""}]
        append navigation "        <li$class>\n"
        append navigation "          <a href=\"$output_url\""
        if {$summary ne ""} {
            append navigation " title=\"$summary\""
        }
        append navigation ">$title</a>\n"
        if {$summary ne ""} {
            append navigation "          <span>$summary</span>\n"
        }
        append navigation "        </li>\n"
    }
    append navigation {      </ul>
    </nav>}
    return $navigation
}

proc ::mk2html::index_body {documents} {
    set body {<h1>TclWire Documentation</h1>
<p>This documentation set contains the following documents.</p>
<div class="document-index">
}
    foreach document $documents {
        set output [dict get $document output]
        set title [html_escape [dict get $document title]]
        set summary [html_escape [dict get $document summary]]
        append body "  <article>\n"
        append body "    <h2><a href=\"$output\">$title</a></h2>\n"
        if {$summary ne ""} {
            append body "    <p>$summary</p>\n"
        }
        append body "  </article>\n"
    }
    append body "</div>\n"
    return $body
}

proc ::mk2html::empty_navigation {} {
    return {    <nav aria-label="Documentation">
      <a class="site-logo" href="index.html" aria-label="TclWire Documentation">
        <img src="tclwire-logo-nav.png" alt="" width="220" height="132">
      </a>
      <ul>
      </ul>
    </nav>}
}

proc ::mk2html::existing_navigation {output_directory} {
    set index_path [file join $output_directory index.html]
    if {![file isfile $index_path]} {
        return [empty_navigation]
    }

    set index_html [read_text_file $index_path]
    if {![regexp {(?s)(<nav aria-label="Documentation">.*?</nav>)} \
            $index_html -> menu]} {
        return [empty_navigation]
    }
    return [string map [list { class="active"} {}] $menu]
}

proc ::mk2html::find_markdown_files {directory} {
    set sources {}
    foreach path [glob -nocomplain -directory $directory *] {
        if {[file type $path] eq "directory"} {
            set sources [concat $sources [find_markdown_files $path]]
        } elseif {[file isfile $path] &&
                [string equal -nocase [file extension $path] .md]} {
            lappend sources [file normalize $path]
        }
    }
    return [lsort -dictionary $sources]
}

proc ::mk2html::write_page {output_directory output_name content} {
    set target [file join $output_directory \
        [string map [list / [file separator]] $output_name]]
    file mkdir [file dirname $target]
    write_text_file $target $content
    puts "generated $target"
}

proc ::mk2html::copy_logo {repository output_directory} {
    foreach logo_name {
        tclwire-logo.png
        tclwire-logo-nav.png
        tclwire-logo-blue.png
    } {
        set logo [file join $repository doc $logo_name]
        if {![file isfile $logo]} {
            continue
        }

        set target [file join $output_directory $logo_name]
        file mkdir [file dirname $target]
        file copy -force $logo $target
        puts "copied $target"
    }
}

proc ::mk2html::copy_favicons {repository output_directory} {
    set favicon_directory [file join $repository doc favicon]
    if {![file isdirectory $favicon_directory]} {
        return
    }

    foreach favicon [glob -nocomplain -directory $favicon_directory *] {
        if {![file isfile $favicon]} {
            continue
        }

        set target [file join $output_directory [file tail $favicon]]
        file mkdir [file dirname $target]
        file copy -force $favicon $target
        puts "copied $target"
    }
}

proc ::mk2html::copy_stylesheet {repository output_directory} {
    set stylesheet [file join $repository doc tclwire.css]
    if {![file isfile $stylesheet]} {
        return
    }

    set target [file join $output_directory tclwire.css]
    file copy -force $stylesheet $target
    puts "copied $target"
}

proc ::mk2html::copy_assets {repository output_directory} {
    copy_logo $repository $output_directory
    copy_favicons $repository $output_directory
    copy_stylesheet $repository $output_directory
}

proc ::mk2html::favicon_links {current_output} {
    set apple_icon [relative_url $current_output apple-touch-icon.png]
    set favicon_32 [relative_url $current_output favicon-32x32.png]
    set favicon_16 [relative_url $current_output favicon-16x16.png]
    set manifest [relative_url $current_output site.webmanifest]
    set ico [relative_url $current_output favicon.ico]

    return [string map [list \
        @APPLE_ICON@ $apple_icon \
        @FAVICON_32@ $favicon_32 \
        @FAVICON_16@ $favicon_16 \
        @MANIFEST@ $manifest \
        @ICO@ $ico] {  <link rel="apple-touch-icon" sizes="180x180" href="@APPLE_ICON@">
  <link rel="icon" type="image/png" sizes="32x32" href="@FAVICON_32@">
  <link rel="icon" type="image/png" sizes="16x16" href="@FAVICON_16@">
  <link rel="manifest" href="@MANIFEST@">
  <link rel="shortcut icon" href="@ICO@">}]
}

proc ::mk2html::page_template {title body navigation {current_output index.html}} {
    set escaped_title [html_escape $title]
    set favicon_links [favicon_links $current_output]
    set stylesheet [relative_url $current_output tclwire.css]
    set template {<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>@TITLE@</title>
@FAVICON_LINKS@
  <link rel="stylesheet" href="@STYLESHEET@">
</head>
<body>
  <div class="page">
@NAVIGATION@
    <main class="markdown-body">
@BODY@
    </main>
  </div>
</body>
</html>
}
    return [string map [list \
        @TITLE@ $escaped_title \
        @FAVICON_LINKS@ $favicon_links \
        @STYLESHEET@ $stylesheet \
        @NAVIGATION@ $navigation \
        @BODY@ $body] $template]
}

proc ::mk2html::build_directory {source_directory output_directory repository} {
    set sources [find_markdown_files $source_directory]
    if {![llength $sources]} {
        error "no Markdown files found in $source_directory"
    }

    set documents [collect_documents $sources $source_directory]
    set source_mapping [source_output_map $documents]
    file mkdir $output_directory
    copy_assets $repository $output_directory

    write_page $output_directory index.html [page_template \
        "TclWire Documentation" \
        [index_body $documents] \
        [navigation $documents index.html] \
        index.html]

    foreach document $documents {
        set source [dict get $document source]
        set title [dict get $document title]
        set output_name [dict get $document output]
        set body [rewrite_markdown_links \
            [::Markdown::convert [dict get $document markdown]] \
            $source $output_name $source_mapping]
        write_page $output_directory $output_name \
            [page_template $title $body \
                [navigation $documents $output_name] \
                $output_name]
    }
}

proc ::mk2html::build_file {source output_directory repository} {
    if {![string equal -nocase [file extension $source] .md]} {
        error "input file is not Markdown: $source"
    }

    set source_root [file dirname $source]
    set documents [collect_documents [list $source] $source_root 0]
    set document [lindex $documents 0]
    set output_name [dict get $document output]
    set source_mapping [source_output_map $documents]
    set body [rewrite_markdown_links \
        [::Markdown::convert [dict get $document markdown]] \
        $source $output_name $source_mapping]

    file mkdir $output_directory
    copy_assets $repository $output_directory
    write_page $output_directory $output_name [page_template \
        [dict get $document title] \
        $body \
        [existing_navigation $output_directory] \
        $output_name]
}

proc ::mk2html::run {arguments} {
    if {[catch {package require Markdown 1.2} message]} {
        error "the Tcllib Markdown package is required: $message"
    }

    set options [parse_arguments $arguments]
    set script_directory [file dirname [file normalize [info script]]]
    set repository [file dirname $script_directory]
    set input [dict get $options input]
    if {[file pathtype $input] ne "absolute"} {
        set input [file join $repository $input]
    }
    set input [file normalize $input]
    set output [dict get $options output]

    if {[file isdirectory $input]} {
        build_directory $input $output $repository
    } elseif {[file isfile $input]} {
        build_file $input $output $repository
    } else {
        error "input path does not exist: $input"
    }
}

try {
    ::mk2html::run $::argv
} trap {TCL LOOKUP VARNAME} {message options} {
    puts stderr "error: $message"
    exit 1
} on error {message options} {
    puts stderr "error: $message"
    ::mk2html::usage stderr
    exit 1
}
