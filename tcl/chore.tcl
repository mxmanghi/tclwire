# chore.tcl --
#
# Generic periodic chore runner.

package require TclOO
package require Thread
package require tclwire::constants 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::chores {}

oo::class create ::tclwire::Chore {
    variable name status

    constructor args {
        if {[info object class [self]] eq "::tclwire::Chore"} {
            error "::tclwire::Chore is abstract"
        }
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
        set status [dict create state idle runs 0 skips 0 failures 0]
    }

    method name {} {
        return $name
    }

    method should_run {wakeup} {
        return 1
    }

    method run {wakeup} {
        error "[self class] must implement run"
    }

    method wakeup {wakeup} {
        if {![my should_run $wakeup]} {
            dict incr status skips
            dict set status state skipped
            dict set status last_wakeup $wakeup
            return [dict create skipped 1]
        }
        if {[catch {my run $wakeup} result options]} {
            dict incr status failures
            dict set status state failed
            dict set status last_wakeup $wakeup
            dict set status last_error $result
            return -options $options $result
        }
        dict incr status runs
        dict set status state ran
        dict set status last_wakeup $wakeup
        dict set status last_result $result
        return $result
    }

    method status {} {
        return $status
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

oo::class create ::tclwire::ApplicationChore {
    superclass ::tclwire::Chore

    variable application_id application_config pool_key

    constructor args {
        array set options {
            -applicationid {}
            -applicationconfig {}
            -poolkey {}
        }
        set remaining {}
        foreach {option value} $args {
            if {[info exists options($option)]} {
                set options($option) $value
            } else {
                lappend remaining $option $value
            }
        }
        set application_id $options(-applicationid)
        set application_config $options(-applicationconfig)
        set pool_key $options(-poolkey)
        next {*}$remaining
    }

    method application_id {} {
        return $application_id
    }

    method application_config {} {
        return $application_config
    }

    method pool_key {} {
        return $pool_key
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
    #   package Package to require before constructing the chore. Optional.
    #   file    Tcl file to source before constructing the chore. Optional.
    #   class   TclOO class derived from ::tclwire::Chore. Required unless
    #           file defines exactly one new chore subclass.
    #   args    Extra constructor option list appended after "-name $name".
    #   paths   Directories appended to auto_path before package/file loading.
    #
    # Runtime-only fields are added after registration: chore records receive an
    # object handle, and every wakeup stores last_status/last_wakeup for
    # inspection.
    proc normalize_chore_spec {spec} {
        if {[catch {dict size $spec}]} {
            error "chore spec must be a dictionary"
        }
        set spec [dict merge [dict create \
            name {} package {} file {} class {} args {} paths {} \
            application_context {}] $spec]
        foreach field {name} {
            if {[string trim [dict get $spec $field]] eq {}} {
                error "chore spec is missing $field"
            }
        }
        if {[string trim [dict get $spec class]] eq {} &&
                [string trim [dict get $spec file]] eq {}} {
            error "chore spec is missing class or file"
        }
        if {[catch {llength [dict get $spec paths]}]} {
            error "chore spec paths must be a list"
        }
        if {[dict exists $spec mode]} {
            dict unset spec mode
        }
        return $spec
    }

    proc chore_subclasses {{class ::tclwire::Chore}} {
        set classes {}
        foreach subclass [info class subclasses $class] {
            lappend classes $subclass
            lappend classes {*}[chore_subclasses $subclass]
        }
        return $classes
    }

    proc dict_from_list {values} {
        set result [dict create]
        foreach value $values {
            dict set result $value 1
        }
        return $result
    }

    proc chore_namespace_commands {} {
        return [info commands ::tclwire::chores::*]
    }

    proc qualify_chore_class {class} {
        if {$class eq {} || [string match ::* $class]} {
            return $class
        }
        return ::tclwire::chores::$class
    }

    proc infer_loaded_chore_class {file classes} {
        if {[llength $classes] == 1} {
            return [lindex $classes 0]
        }
        if {[llength $classes] == 0} {
            error "chore file '$file' did not define a ::tclwire::Chore subclass"
        }
        error "chore file '$file' defines multiple chore classes: [join $classes {, }]"
    }

    proc chore_class_exists {class} {
        set class [qualify_chore_class $class]
        return [expr {![catch {info class superclasses $class}]}]
    }

    proc validate_chore_class {class} {
        set class [qualify_chore_class $class]
        if {[catch {info class superclasses $class}]} {
            error "chore class does not exist: $class"
        }
        if {$class ni [chore_subclasses]} {
            error "chore class does not inherit from ::tclwire::Chore: $class"
        }
        return $class
    }

    proc is_application_chore_class {class} {
        return [expr {$class eq "::tclwire::ApplicationChore" ||
                $class in [chore_subclasses ::tclwire::ApplicationChore]}]
    }

    proc agent_load_chore_file {file class} {
        variable agent_chore_files

        set file [file normalize $file]
        set class [qualify_chore_class $class]
        if {[dict exists $agent_chore_files $file]} {
            set loaded_classes [dict get $agent_chore_files $file]
            if {$class eq {}} {
                return [infer_loaded_chore_class $file $loaded_classes]
            }
            validate_chore_class $class
            if {$class ni $loaded_classes} {
                error "chore file '$file' did not load chore class: $class"
            }
            return $class
        }

        if {$class ne {} && [chore_class_exists $class]} {
            validate_chore_class $class
            dict set agent_chore_files $file [list $class]
            return $class
        }

        set before_commands [dict_from_list [chore_namespace_commands]]
        set before_classes [chore_subclasses]
        namespace eval ::tclwire::chores [list source $file]
        set before [dict_from_list $before_classes]
        set loaded_classes {}
        foreach command [chore_namespace_commands] {
            if {[dict exists $before_commands $command]} {
                continue
            }
            if {[chore_class_exists $command] &&
                    $command in [chore_subclasses]} {
                lappend loaded_classes $command
            }
        }
        foreach loaded_class [chore_subclasses] {
            if {![dict exists $before $loaded_class] &&
                    $loaded_class ni $loaded_classes} {
                lappend loaded_classes $loaded_class
            }
        }

        if {$class eq {}} {
            set class [infer_loaded_chore_class $file $loaded_classes]
        } else {
            validate_chore_class $class
            if {$class ni $loaded_classes} {
                lappend loaded_classes $class
            }
        }
        dict set agent_chore_files $file $loaded_classes
        return $class
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
            set interval_ms \
                [validate_interval chore_interval_ms [dict get $config chore_interval_ms] 100]
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
            ::thread::send $tid \
                [list ::tclwire::chore::agent_initialize $interval_ms $normalized_specs]
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
        variable agent_chore_files

        set agent_interval_ms   $interval
        set agent_sequence      0
        set agent_timer         {}
        set agent_chores        {}
        set agent_running       1
        set agent_chore_files   {}

        foreach spec $specs {
            lappend agent_chores [agent_create_chore $spec]
        }
        agent_schedule 0
        return [agent_status]
    }

    # Scheduler-thread registration hook.  Subsystems call ::tclwire::chore
    # register from their own start path; the scheduler thread owns construction
    # so chore objects remain local to this interpreter.
    proc agent_register {specs} {
        variable agent_chores

        foreach spec $specs {
            lappend agent_chores [agent_create_chore $spec]
        }
        return [agent_status]
    }

    # Scheduler-thread chore construction. Chores live directly in the
    # scheduler interpreter and own their own run/refusal policy.
    proc agent_create_chore {spec} {
        set package     [dict get $spec package]
        set file        [dict get $spec file]
        set class       [dict get $spec class]
        set args        [dict get $spec args]
        set name        [dict get $spec name]
        set paths       [dict get $spec paths]
        set application_context [dict get $spec application_context]

        foreach directory $paths {
            if {$directory ne {} && $directory ni $::auto_path} {
                lappend ::auto_path $directory
            }
        }

        if {$package ne {}} {
            package require $package
        }
        if {$file ne {}} {
            set class [agent_load_chore_file $file $class]
            dict set spec class $class
        }
        set class [validate_chore_class $class]
        dict set spec class $class
        if {$application_context ne {} && [is_application_chore_class $class]} {
            lappend args \
                -applicationid [dict get $application_context application_id] \
                -applicationconfig [dict get $application_context application_config] \
                -poolkey [dict get $application_context pool_key]
        }
        set object [{*}[list $class new -name $name] {*}$args]
        dict unset spec application_context
        return [dict merge $spec [dict create object $object]]
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
        set wakeup [dict create sequence    $agent_sequence \
                                now_ms      $now \
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

    # Scheduler-thread dispatch boundary. The chore decides whether the wakeup
    # means it has work to do and records its own status internally.
    proc agent_fire_chore {record wakeup} {
        set object [dict get $record object]
        if {[catch {$object wakeup $wakeup} result options]} {
            return [dict create ok 0 error $result errorcode [dict get $options -errorcode]]
        }
        return [dict create ok 1 result $result status [$object status]]
    }

    # Scheduler-thread status snapshot.  Object handles are interpreter-local,
    # so they are stripped before the descriptor records are returned.
    proc agent_status {} {
        variable agent_interval_ms
        variable agent_sequence
        variable agent_chores
        set chores {}
        foreach record $agent_chores {
            if {[dict exists $record object]} {
                dict set record status [[dict get $record object] status]
            }
            dict unset record object
            lappend chores $record
        }
        return [dict create running     1 \
                            thread_id   [::thread::id] \
                            interval_ms $agent_interval_ms \
                            sequence    $agent_sequence \
                            chores      $chores]
    }

    # Scheduler-thread shutdown. Chore objects are destroyed in-place before
    # this interpreter releases itself.
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
            catch {[dict get $record object] destroy}
        }
        set agent_chores {}
        after 0 [list ::thread::release [::thread::id]]
        return
    }

    namespace export start stop register status thread_id is_running
    namespace ensemble create
}

package provide tclwire::chore 0.1
