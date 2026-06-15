#!/usr/bin/env tclsh

package require Tcl 8.6

namespace eval ::mk2html {
    variable default_output /tmp/tclwire
}

proc ::mk2html::usage {{channel stdout}} {
    variable default_output

    puts $channel "Usage: [file tail $::argv0] ?--output DIR?"
    puts $channel ""
    puts $channel "Convert the Markdown files in doc/ to standalone HTML pages."
    puts $channel ""
    puts $channel "Options:"
    puts $channel "  --output DIR   Write generated files to DIR (default: $default_output)"
    puts $channel "  -h, --help     Show this help"
}

proc ::mk2html::parse_arguments {arguments} {
    variable default_output
    set output $default_output

    for {set index 0} {$index < [llength $arguments]} {incr index} {
        set argument [lindex $arguments $index]
        switch -glob -- $argument {
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

    return [file normalize $output]
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

proc ::mk2html::rewrite_markdown_links {html} {
    # Converted pages live together, so relative Markdown links should point
    # at their generated HTML counterparts.
    return [regsub -all -nocase \
        {href="((?:\./|\.\./)?[^":?#]+)\.md(#[^"]*)?"} \
        $html {href="\1.html\2"}]
}

proc ::mk2html::page_template {title body} {
    set escaped_title [html_escape $title]
    set template {<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>@TITLE@</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --fg: #1f2328;
      --muted: #59636e;
      --border: #d1d9e0;
      --link: #0969da;
      --code-bg: #f6f8fa;
      --quote: #656d76;
      --table-alt: #f6f8fa;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --fg: #e6edf3;
        --muted: #9198a1;
        --border: #3d444d;
        --link: #4493f8;
        --code-bg: #151b23;
        --quote: #9198a1;
        --table-alt: #151b23;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--fg);
      font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      max-width: 1012px;
      margin: 0 auto;
      padding: 32px;
      overflow-wrap: break-word;
    }
    h1, h2, h3, h4, h5, h6 {
      margin-top: 24px;
      margin-bottom: 16px;
      line-height: 1.25;
      font-weight: 600;
    }
    h1, h2 {
      padding-bottom: .3em;
      border-bottom: 1px solid var(--border);
    }
    h1 { font-size: 2em; }
    h2 { font-size: 1.5em; }
    h3 { font-size: 1.25em; }
    p, blockquote, ul, ol, dl, table, pre { margin: 0 0 16px; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    blockquote {
      padding: 0 1em;
      color: var(--quote);
      border-left: .25em solid var(--border);
    }
    code, kbd, pre {
      font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
    }
    code {
      padding: .2em .4em;
      margin: 0;
      font-size: 85%;
      background: var(--code-bg);
      border-radius: 6px;
    }
    pre {
      padding: 16px;
      overflow: auto;
      font-size: 85%;
      line-height: 1.45;
      background: var(--code-bg);
      border-radius: 6px;
    }
    pre code { padding: 0; background: transparent; border-radius: 0; }
    table {
      display: block;
      width: max-content;
      max-width: 100%;
      overflow: auto;
      border-spacing: 0;
      border-collapse: collapse;
    }
    th, td { padding: 6px 13px; border: 1px solid var(--border); }
    tr:nth-child(2n) { background: var(--table-alt); }
    img { max-width: 100%; }
    hr {
      height: .25em;
      padding: 0;
      margin: 24px 0;
      background: var(--border);
      border: 0;
    }
    @media (max-width: 767px) {
      main { padding: 16px; }
    }
  </style>
</head>
<body>
  <main class="markdown-body">
@BODY@
  </main>
</body>
</html>
}
    return [string map [list @TITLE@ $escaped_title @BODY@ $body] $template]
}

proc ::mk2html::run {arguments} {
    if {[catch {package require Markdown 1.2} message]} {
        error "the Tcllib Markdown package is required: $message"
    }

    set output [parse_arguments $arguments]
    set script_directory [file dirname [file normalize [info script]]]
    set repository [file dirname $script_directory]
    set source_directory [file join $repository doc]
    set sources [lsort -dictionary [glob -nocomplain \
        -directory $source_directory -types f *.md]]

    if {![llength $sources]} {
        error "no Markdown files found in $source_directory"
    }

    file mkdir $output
    foreach source $sources {
        set markdown [read_text_file $source]
        set title [document_title $markdown $source]
        set body [rewrite_markdown_links [::Markdown::convert $markdown]]
        set target [file join $output \
            "[file rootname [file tail $source]].html"]
        write_text_file $target [page_template $title $body]
        puts "generated $target"
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
