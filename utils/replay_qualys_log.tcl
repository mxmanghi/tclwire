#!/usr/bin/env tclsh
#
# replay_qualys_log.tcl --
#
# Replay HTTP request targets extracted from a TclWire access log.

namespace eval ::tclwire::qualys_replay {
    variable default_hostname localhost:8990
    variable default_delay_ms 100
    variable default_concurrency 1
    variable script_path [file normalize [info script]]
}

proc ::tclwire::qualys_replay::usage {{channel stdout}} {
    variable default_hostname
    variable default_delay_ms
    variable default_concurrency

    puts $channel "Usage: [file tail $::argv0] ?options? LOGFILE"
    puts $channel ""
    puts $channel "Options:"
    puts $channel "  --hostname <authority>  Target authority. Default: $default_hostname"
    puts $channel "  --delay-ms <ms>         Delay between requests. Default: $default_delay_ms"
    puts $channel "  --concurrency <count>   Maximum concurrent requests. Default: $default_concurrency"
    puts $channel "  -h, --help              Show this help."
}

proc ::tclwire::qualys_replay::parse_delay {value} {
    if {![string is integer -strict $value] || $value < 0} {
        error "--delay-ms must be an integer greater than or equal to 0"
    }
    return $value
}

proc ::tclwire::qualys_replay::parse_concurrency {value} {
    if {![string is integer -strict $value] || $value < 1} {
        error "--concurrency must be an integer greater than or equal to 1"
    }
    return $value
}

proc ::tclwire::qualys_replay::parse_arguments {arguments} {
    variable default_hostname
    variable default_delay_ms
    variable default_concurrency

    set hostname $default_hostname
    set delay_ms $default_delay_ms
    set concurrency $default_concurrency
    set logfile {}

    for {set index 0} {$index < [llength $arguments]} {incr index} {
        set argument [lindex $arguments $index]
        switch -exact -- $argument {
            --hostname {
                incr index
                if {$index >= [llength $arguments]} {
                    error "--hostname requires a value"
                }
                set hostname [lindex $arguments $index]
            }
            --delay-ms {
                incr index
                if {$index >= [llength $arguments]} {
                    error "--delay-ms requires a value"
                }
                set delay_ms [parse_delay [lindex $arguments $index]]
            }
            --concurrency {
                incr index
                if {$index >= [llength $arguments]} {
                    error "--concurrency requires a value"
                }
                set concurrency [parse_concurrency [lindex $arguments $index]]
            }
            -h -
            --help {
                usage
                exit 0
            }
            default {
                if {[string match --* $argument]} {
                    error "unknown option: $argument"
                }
                if {$logfile ne {}} {
                    error "exactly one LOGFILE argument is required"
                }
                set logfile $argument
            }
        }
    }

    if {$logfile eq {}} {
        error "missing LOGFILE argument"
    }
    if {[string trim $hostname] eq {}} {
        error "--hostname must not be empty"
    }
    return [dict create \
        hostname $hostname \
        delay_ms $delay_ms \
        concurrency $concurrency \
        logfile [file normalize $logfile]]
}

proc ::tclwire::qualys_replay::read_text_file {path} {
    if {![file isfile $path]} {
        error "log file does not exist: $path"
    }
    set channel [open $path r]
    try {
        chan configure $channel -encoding utf-8 -translation lf
        return [read $channel]
    } finally {
        close $channel
    }
}

proc ::tclwire::qualys_replay::field_value {line field} {
    set start [string first "${field}=" $line]
    if {$start < 0} {
        return {}
    }
    set start [expr {$start + [string length $field] + 1}]
    set end [string first " " $line $start]
    if {$end < 0} {
        return [string range $line $start end]
    }
    return [string range $line $start [expr {$end - 1}]]
}

proc ::tclwire::qualys_replay::request_records {log_text} {
    set records {}
    set line_number 0
    foreach line [split $log_text \n] {
        incr line_number
        if {![regexp {^[0-9-]+ [0-9:]+ (http|https) } $line]} {
            continue
        }
        set method [field_value $line method]
        set path [field_value $line path]
        if {$method eq {} || $path eq {}} {
            continue
        }
        lappend records [dict create \
            line $line_number \
            method $method \
            path $path]
    }
    return $records
}

proc ::tclwire::qualys_replay::request_url {hostname path} {
    if {[regexp {^https?://} $hostname]} {
        set base [string trimright $hostname /]
    } else {
        set base "http://[string trimright $hostname /]"
    }
    if {![string match /* $path]} {
        set path "/$path"
    }
    return "${base}${path}"
}

proc ::tclwire::qualys_replay::method_options {method} {
    set method [string toupper $method]
    switch -exact -- $method {
        GET {
            return [list -httpget 1 -nobody 0]
        }
        HEAD {
            return [list -nobody 1]
        }
        POST {
            return [list -post 1 -postfields {} -postfieldsize 0 -nobody 0]
        }
        default {
            return [list -httpget 1 -nobody 0 -customrequest $method]
        }
    }
}

proc ::tclwire::qualys_replay::configure_handle {
        handle hostname record body_var response_code_var total_time_var} {
    set method [dict get $record method]
    set url [request_url $hostname [dict get $record path]]
    set $body_var {}

    $handle reset
    $handle configure \
        -url $url \
        -noprogress 1 \
        -bodyvar $body_var \
        {*}[method_options $method]
    return $url
}

proc ::tclwire::qualys_replay::replay_record {handle hostname record} {
    set method [dict get $record method]
    set body_var ::tclwire::qualys_replay::sequential_body
    set response_code_var ::tclwire::qualys_replay::sequential_response_code
    set total_time_var ::tclwire::qualys_replay::sequential_total_time

    set url [configure_handle $handle $hostname $record \
        $body_var $response_code_var $total_time_var]
    set ok [expr {![catch {$handle perform} message options]}]
    set result [dict create \
        ok $ok \
        line [dict get $record line] \
        method $method \
        url $url \
        response_code [$handle getinfo responsecode] \
        total_time [$handle getinfo totaltime]]
    if {!$ok} {
        dict set result error $message
        if {[dict exists $options -errorcode]} {
            dict set result errorcode [dict get $options -errorcode]
        }
    }
    return $result
}

proc ::tclwire::qualys_replay::format_result {sequence result} {
    set fields [list \
        "#$sequence" \
        "line=[dict get $result line]" \
        "method=[dict get $result method]" \
        "status=[dict get $result response_code]" \
        "time=[dict get $result total_time]" \
        "url=[dict get $result url]"]
    if {![dict get $result ok]} {
        lappend fields "error=[dict get $result error]"
    }
    return [join $fields " "]
}

proc ::tclwire::qualys_replay::replay_sequential {records args} {
    set options [dict merge [dict create \
        hostname $::tclwire::qualys_replay::default_hostname \
        delay_ms $::tclwire::qualys_replay::default_delay_ms] $args]
    set handle [curl::init]
    set results {}
    try {
        set sequence 0
        foreach record $records {
            incr sequence
            if {$sequence > 1 && [dict get $options delay_ms] > 0} {
                after [dict get $options delay_ms]
            }
            set result [replay_record $handle [dict get $options hostname] $record]
            lappend results $result
            puts [format_result $sequence $result]
            flush stdout
        }
    } finally {
        $handle cleanup
    }
    return $results
}

proc ::tclwire::qualys_replay::thread_script {} {
    variable script_path

    return [format {
        source %s
        package require TclCurl
        thread::wait
    } [list $script_path]]
}

proc ::tclwire::qualys_replay::start_workers {count} {
    package require Thread

    set workers {}
    set script [thread_script]
    for {set index 0} {$index < $count} {incr index} {
        lappend workers [thread::create $script]
    }
    return $workers
}

proc ::tclwire::qualys_replay::stop_workers {workers} {
    foreach tid $workers {
        catch {thread::send -async $tid [list thread::release $tid]}
    }
    return
}

proc ::tclwire::qualys_replay::worker_replay_record {hostname record} {
    set handle [curl::init]
    try {
        return [replay_record $handle $hostname $record]
    } finally {
        $handle cleanup
    }
}

proc ::tclwire::qualys_replay::dispatch_worker {
        worker hostname record sequence active_var} {
    upvar 1 $active_var active

    dict set active $worker [dict create \
        sequence $sequence \
        record $record \
        done_variable ::tclwire::qualys_replay::done_$sequence]
    thread::send -async $worker \
        [list ::tclwire::qualys_replay::worker_replay_record $hostname $record] \
        ::tclwire::qualys_replay::done_$sequence
    return
}

proc ::tclwire::qualys_replay::collect_thread_done {
        workers_var active_var available_var results_var} {
    upvar 1 $workers_var workers
    upvar 1 $active_var active
    upvar 1 $available_var available
    upvar 1 $results_var results

    foreach worker $workers {
        if {![dict exists $active $worker]} {
            continue
        }
        set slot [dict get $active $worker]
        set done_variable [dict get $slot done_variable]
        if {![info exists $done_variable]} {
            continue
        }
        set result [set $done_variable]
        unset $done_variable
        lappend results $result
        puts [format_result [dict get $slot sequence] $result]
        flush stdout
        dict unset active $worker
        lappend available $worker
    }
    return
}

proc ::tclwire::qualys_replay::replay_concurrent {records args} {
    set options [dict merge [dict create \
        hostname $::tclwire::qualys_replay::default_hostname \
        delay_ms $::tclwire::qualys_replay::default_delay_ms \
        concurrency $::tclwire::qualys_replay::default_concurrency] $args]
    set hostname [dict get $options hostname]
    set delay_ms [dict get $options delay_ms]
    set concurrency [dict get $options concurrency]
    set workers [start_workers $concurrency]
    set available $workers
    set active [dict create]
    set results {}
    set next_index 0
    set next_sequence 1
    set next_start_ms 0

    try {
        while {$next_index < [llength $records] || [dict size $active] > 0} {
            collect_thread_done workers active available results
            set now [clock milliseconds]
            while {$next_index < [llength $records] &&
                    [llength $available] > 0 &&
                    $now >= $next_start_ms} {
                set worker [lindex $available 0]
                set available [lrange $available 1 end]
                set record [lindex $records $next_index]
                dispatch_worker $worker $hostname $record $next_sequence active
                incr next_index
                incr next_sequence
                set next_start_ms [expr {[clock milliseconds] + $delay_ms}]
                set now [clock milliseconds]
                if {$delay_ms > 0} {
                    break
                }
            }

            if {[dict size $active] == 0 && $next_index < [llength $records]} {
                set wait_ms [expr {$next_start_ms - [clock milliseconds]}]
                if {$wait_ms > 0} {
                    after $wait_ms
                } else {
                    after 1
                }
                update
            } elseif {[dict size $active] > 0} {
                after 10
                update
            }
        }
    } finally {
        stop_workers $workers
    }
    return $results
}

proc ::tclwire::qualys_replay::replay {logfile args} {
    package require TclCurl

    set options [dict merge [dict create \
        hostname $::tclwire::qualys_replay::default_hostname \
        delay_ms $::tclwire::qualys_replay::default_delay_ms \
        concurrency $::tclwire::qualys_replay::default_concurrency] $args]
    set records [request_records [read_text_file $logfile]]
    if {[dict get $options concurrency] == 1} {
        return [replay_sequential $records {*}$options]
    }
    return [replay_concurrent $records {*}$options]
}

proc ::tclwire::qualys_replay::main {arguments} {
    if {[catch {
        set options [parse_arguments $arguments]
        replay [dict get $options logfile] \
            hostname [dict get $options hostname] \
            delay_ms [dict get $options delay_ms] \
            concurrency [dict get $options concurrency]
    } message options]} {
        puts stderr $message
        usage stderr
        return -options $options $message
    }
    return
}

if {[info exists ::argv0] &&
        [file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {::tclwire::qualys_replay::main $::argv} message]} {
        exit 1
    }
}
