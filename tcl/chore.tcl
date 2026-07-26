# chore.tcl --
#
# Generic periodic chore runner.

package require TclOO
package require Thread
package require tclwire::constants 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::Chore {
    variable name

    constructor args {
        array set options {
            -name {}
        }
        foreach {option value} $args {
            if {![info exists options($option)]} {
                error "unknown option: $option"
            }
            set options($option) $value
        }
        set name $options(-name)
        if {$name eq {}} {
            set name [namespace tail [self class]]
        }
    }

    method name {} {
        return $name
    }

    method should_run {wakeup} {
        return 1
    }

    method run {wakeup} {
        return {}
    }

    method wakeup {wakeup} {
        if {![my should_run $wakeup]} {
            return [dict create skipped 1]
        }
        return [my run $wakeup]
    }
}

oo::class create ::tclwire::TsvRecordingChore {
    superclass ::tclwire::Chore

    variable key every

    constructor args {
        array set options {
            -name tsv_recording_chore
            -key chore_events
            -every 1
        }
        foreach {option value} $args {
            if {![info exists options($option)]} {
                error "unknown option: $option"
            }
            set options($option) $value
        }
        set key $options(-key)
        set every $options(-every)
        next -name $options(-name)
    }

    method should_run {wakeup} {
        return [expr {[dict get $wakeup sequence] % $every == 0}]
    }

    method run {wakeup} {
        set record [dict create name        [my name] \
                                sequence    [dict get $wakeup sequence] \
                                thread_id   [::thread::id]]
        ::tsv::lappend tclwire $key $record
        return $record
    }
}

namespace eval ::tclwire::chore {
    variable runner_thread_id {}
    variable project_root [file dirname [file dirname [file normalize [info script]]]]

    proc validate_interval {name value minimum} {
        if {![string is integer -strict $value] || $value < $minimum} {
            error "$name must be an integer greater than or equal to $minimum"
        }
        return $value
    }

    # Chore descriptor dictionary:
    #
    #   name    Stable chore id used in status output and passed as -name to
    #           the chore object constructor. Required.
    #   package Package to require before constructing the chore. Optional for
    #           sync chores, but async chores normally need it because worker
    #           threads start with a fresh interpreter.
    #   class   TclOO class derived from ::tclwire::Chore. Required.
    #   args    Extra constructor option list appended after "-name $name".
    #   mode    "sync" runs the chore in the scheduler thread; "async" gives
    #           the chore its own worker thread and sends wakeups asynchronously.
    #
    # Runtime-only fields are added after registration: sync chores receive an
    # object handle, async chores receive a worker thread id, and every wakeup
    # stores last_status/last_wakeup for inspection.
    proc normalize_chore_spec {spec} {
        if {[catch {dict size $spec}]} {
            error "chore spec must be a dictionary"
        }
        set spec [dict merge [dict create \
            name {} package {} class {} args {} mode sync] $spec]
        foreach field {name class} {
            if {[string trim [dict get $spec $field]] eq {}} {
                error "chore spec is missing $field"
            }
        }
        set mode [string tolower [string trim [dict get $spec mode]]]
        if {$mode ni {sync async}} {
            error "chore mode must be sync or async"
        }
        dict set spec mode $mode
        return $spec
    }

    proc thread_id {} {
        variable runner_thread_id
        return $runner_thread_id
    }

    proc is_running {} {
        set tid [thread_id]
        return [expr {$tid ne {} && [::thread::exists $tid]}]
    }

    proc start {config {chore_specs {}}} {
        variable runner_thread_id
        variable project_root

        if {[is_running]} {
            error "chore runner is already running: $runner_thread_id"
        }
        set interval_ms 5000
        if {[dict exists $config chore_interval_ms]} {
            set interval_ms [validate_interval chore_interval_ms \
                [dict get $config chore_interval_ms] 100]
        }
        set normalized_specs {}
        foreach spec $chore_specs {
            lappend normalized_specs [normalize_chore_spec $spec]
        }

        set tid [::thread::create {
            package require Thread
            ::thread::wait
        }]

        try {
            ::thread::send $tid [list lappend auto_path $project_root]
            ::thread::send $tid {package require tclwire::chore 0.1}
            ::thread::send $tid [list ::tclwire::chore::agent_initialize \
                $interval_ms $normalized_specs]
        } on error {message options} {
            catch {::thread::send -async $tid [list ::thread::release $tid]}
            return -options $options $message
        }

        set runner_thread_id $tid
        return $tid
    }

    proc register {chore_specs} {
        if {![is_running]} {
            error "chore runner is not running"
        }
        set normalized_specs {}
        foreach spec $chore_specs {
            lappend normalized_specs [normalize_chore_spec $spec]
        }
        return [::thread::send [thread_id] \
            [list ::tclwire::chore::agent_register $normalized_specs]]
    }

    proc stop {} {
        variable runner_thread_id
        set tid $runner_thread_id
        set runner_thread_id {}
        if {$tid eq {} || ![::thread::exists $tid]} {
            return {}
        }
        if {[catch {
            ::thread::send $tid ::tclwire::chore::agent_shutdown
        } message options]} {
            if {[::thread::exists $tid]} {
                return -options $options $message
            }
        }
        set deadline [expr {[clock milliseconds] + 2000}]
        while {[::thread::exists $tid] && [clock milliseconds] < $deadline} {
            after 10
        }
        if {[::thread::exists $tid]} {
            error "chore runner thread did not stop within 2000ms"
        }
        return $tid
    }

    proc status {} {
        if {![is_running]} {
            return [dict create running 0]
        }
        return [::thread::send [thread_id] ::tclwire::chore::agent_status]
    }

    # Scheduler-thread entry point.  The runtime creates this interpreter as an
    # explicit subsystem; optional boot-time specs are loaded here, and later
    # subsystem chores are attached through agent_register.
    proc agent_initialize {interval specs} {
        variable agent_interval_ms
        variable agent_sequence
        variable agent_timer
        variable agent_chores
        variable agent_running

        set agent_interval_ms $interval
        set agent_sequence 0
        set agent_timer {}
        set agent_chores {}
        set agent_running 1

        foreach spec $specs {
            lappend agent_chores [agent_create_chore $spec]
        }
        agent_schedule 0
        return [agent_status]
    }

    # Scheduler-thread registration hook.  Subsystems call ::tclwire::chore
    # register from their own start path; the scheduler thread owns construction
    # so sync chore objects remain local to this interpreter.
    proc agent_register {specs} {
        variable agent_chores

        foreach spec $specs {
            lappend agent_chores [agent_create_chore $spec]
        }
        return [agent_status]
    }

    # Scheduler-thread chore construction.  Sync chores live directly in the
    # scheduler interpreter. Async chores get a fresh worker interpreter so slow
    # or blocking work cannot delay later scheduler ticks.
    proc agent_create_chore {spec} {
        variable project_root
        set package [dict get $spec package]
        set class [dict get $spec class]
        set args [dict get $spec args]
        set mode [dict get $spec mode]
        set name [dict get $spec name]

        if {$mode eq "sync"} {
            if {$package ne {}} {
                package require $package
            }
            set object [{*}[list $class new -name $name] {*}$args]
            return [dict merge $spec [dict create object $object worker {}]]
        }

        set worker [::thread::create {
            package require Thread
            ::thread::wait
        }]
        try {
            ::thread::send $worker [list lappend auto_path $project_root]
            ::thread::send $worker {package require tclwire::chore 0.1}
            if {$package ne {}} {
                ::thread::send $worker [list package require $package]
            }
            ::thread::send $worker [list ::tclwire::chore::worker_initialize \
                $class $name $args]
        } on error {message options} {
            catch {::thread::send -async $worker [list ::thread::release $worker]}
            return -options $options $message
        }
        return [dict merge $spec [dict create object {} worker $worker]]
    }

    # Async worker-thread entry point.  The scheduler sends wakeups to this
    # interpreter after the chore object has been constructed here.
    proc worker_initialize {class name args} {
        variable worker_chore
        set worker_chore [{*}[list $class new -name $name] {*}[lindex $args 0]]
        return $worker_chore
    }

    proc worker_wakeup {wakeup} {
        variable worker_chore
        return [$worker_chore wakeup $wakeup]
    }

    proc worker_shutdown {} {
        variable worker_chore
        catch {$worker_chore destroy}
        set worker_chore {}
        after 0 [list ::thread::release [::thread::id]]
        return
    }

    # Scheduler-thread timer arm.  Keeping one outstanding after token prevents
    # duplicated wakeup streams if start/stop paths overlap with a pending tick.
    proc agent_schedule {delay_ms} {
        variable agent_timer
        variable agent_running
        if {!$agent_running || $agent_timer ne {}} {
            return
        }
        set agent_timer [after $delay_ms ::tclwire::chore::agent_tick]
        return
    }

    # Central scheduler tick.  Every wakeup carries a monotonically increasing
    # sequence number plus the scheduler clock; each chore decides in
    # should_run/run whether that wakeup means it has work to do.
    proc agent_tick {} {
        variable agent_timer
        variable agent_running
        variable agent_interval_ms
        variable agent_sequence
        variable agent_chores

        set agent_timer {}
        if {!$agent_running} {
            return
        }
        incr agent_sequence
        set now [clock milliseconds]
        set wakeup [dict create \
            sequence $agent_sequence \
            now_ms $now \
            interval_ms $agent_interval_ms \
            scheduler_thread_id [::thread::id]]
        set updated {}
        foreach record $agent_chores {
            set status [agent_fire_chore $record $wakeup]
            dict set record last_status $status
            dict set record last_wakeup $wakeup
            lappend updated $record
        }
        set agent_chores $updated
        agent_schedule $agent_interval_ms
        return
    }

    # Scheduler-thread dispatch boundary.  Sync mode executes and records the
    # result immediately. Async mode queues work to the chore's worker and only
    # records whether the send succeeded.
    proc agent_fire_chore {record wakeup} {
        set mode [dict get $record mode]
        if {$mode eq "sync"} {
            if {[catch {[dict get $record object] wakeup $wakeup} result options]} {
                return [dict create ok 0 error $result errorcode [dict get $options -errorcode]]
            }
            return [dict create ok 1 result $result]
        }
        set worker [dict get $record worker]
        if {$worker eq {} || ![::thread::exists $worker]} {
            return [dict create ok 0 error worker_not_running]
        }
        if {[catch {
            ::thread::send -async $worker [list ::tclwire::chore::worker_wakeup $wakeup]
        } result options]} {
            return [dict create ok 0 error $result errorcode [dict get $options -errorcode]]
        }
        return [dict create ok 1 async 1]
    }

    # Scheduler-thread status snapshot.  Object handles are interpreter-local,
    # so they are stripped before the descriptor records are returned.
    proc agent_status {} {
        variable agent_interval_ms
        variable agent_sequence
        variable agent_chores
        set chores {}
        foreach record $agent_chores {
            dict unset record object
            lappend chores $record
        }
        return [dict create \
            running 1 \
            thread_id [::thread::id] \
            interval_ms $agent_interval_ms \
            sequence $agent_sequence \
            chores $chores]
    }

    # Scheduler-thread shutdown.  Sync chore objects are destroyed in-place;
    # async workers receive their own shutdown command before this interpreter
    # releases itself.
    proc agent_shutdown {} {
        variable agent_timer
        variable agent_running
        variable agent_chores

        set agent_running 0
        if {$agent_timer ne {}} {
            after cancel $agent_timer
            set agent_timer {}
        }
        foreach record $agent_chores {
            if {[dict get $record mode] eq "sync"} {
                catch {[dict get $record object] destroy}
            } else {
                set worker [dict get $record worker]
                if {$worker ne {} && [::thread::exists $worker]} {
                    catch {::thread::send $worker ::tclwire::chore::worker_shutdown}
                }
            }
        }
        set agent_chores {}
        after 0 [list ::thread::release [::thread::id]]
        return
    }

    namespace export start stop register status thread_id is_running
    namespace ensemble create
}

package provide tclwire::chore 0.1
