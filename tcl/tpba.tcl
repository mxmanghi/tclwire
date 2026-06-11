# tpba.tcl --
#
# Thread-Pool Broker Agent prototype.

package require TclOO
package require tclwire::accounting 1.2
package require tclwire::threadpool 2.0

namespace eval ::tclwire {}

if {![::tclwire::accounting is_initialized]} {
    ::tclwire::accounting initialize
}

oo::class create ::tclwire::ThreadPoolsBrokerAgent {
    variable pools
    variable thread_master_factory

    constructor args {
        ::tclwire::accounting initialize

        array set options {
            -threadmasterfactory ::tclwire::ThreadMaster
        }

        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }

        set pools [dict create]
        set thread_master_factory $options(-threadmasterfactory)
    }

    destructor {
        my shutdown_all
    }

    method normalize_pool_key {pool_key} {
        set pool_key [string trim $pool_key]
        if {$pool_key eq {}} {
            error "pool key must not be empty"
        }
        return $pool_key
    }

    method pool_key {descriptor} {
        if {[catch {dict size $descriptor}]} {
            error "pool descriptor must be a dictionary"
        }

        if {[dict exists $descriptor kind]} {
            set kind [string tolower [string trim [dict get $descriptor kind]]]
        } elseif {[dict exists $descriptor role]} {
            set kind [string tolower [string trim [dict get $descriptor role]]]
        } else {
            error "pool descriptor must define kind or role"
        }

        set prefixes [dict create \
            application app \
            connection connection \
            connection_agent connection \
            protocol protocol \
            transport transport]
        if {[dict exists $prefixes $kind]} {
            set prefix [dict get $prefixes $kind]
        } else {
            set prefix $kind
        }

        switch -exact -- $prefix {
            app {
                set identity_fields {application name protocol family endpoint}
            }
            connection -
            protocol {
                set identity_fields {protocol name family endpoint application}
            }
            transport {
                set identity_fields {endpoint protocol name family application}
            }
            default {
                set identity_fields {name protocol application endpoint family}
            }
        }

        set identity {}
        foreach field $identity_fields {
            if {[dict exists $descriptor $field]} {
                set identity [string tolower [string trim \
                    [dict get $descriptor $field]]]
                if {$identity ne {}} {
                    break
                }
            }
        }
        if {$identity eq {}} {
            error "pool descriptor must define a protocol, application, name, endpoint, or family"
        }

        return [my normalize_pool_key "${prefix}:${identity}"]
    }

    method normalize_policy {policy} {
        if {[catch {dict size $policy}]} {
            error "pool policy must be a dictionary"
        }

        set normalized [dict merge [dict create \
            minimum_workers 0 \
            maximum_workers 100 \
            restart_policy none] $policy]

        set minimum_workers [dict get $normalized minimum_workers]
        set maximum_workers [dict get $normalized maximum_workers]
        foreach {name value minimum} [list minimum_workers $minimum_workers 0 \
                                           maximum_workers $maximum_workers 1] {
            if {![string is integer -strict $value] || $value < $minimum} {
                error "$name must be an integer greater than or equal to $minimum"
            }
        }
        if {$minimum_workers > $maximum_workers} {
            error "minimum_workers must not exceed maximum_workers"
        }

        return $normalized
    }

    method require_pool {pool_key} {
        set pool_key [my normalize_pool_key $pool_key]
        if {![dict exists $pools $pool_key]} {
            error "unknown thread pool: $pool_key"
        }
        return [dict get $pools $pool_key]
    }

    method pool_family {descriptor} {
        if {[dict exists $descriptor family]} {
            return [string tolower [string trim [dict get $descriptor family]]]
        }
        if {[dict exists $descriptor protocol]} {
            return [string tolower [string trim [dict get $descriptor protocol]]]
        }
        return {}
    }

    method create_pool {pool_key worker_script {policy {}} {descriptor {}}} {
        if {$pool_key eq {}} {
            set pool_key [my pool_key $descriptor]
        } else {
            set pool_key [my normalize_pool_key $pool_key]
        }
        if {[dict exists $pools $pool_key]} {
            error "thread pool already exists: $pool_key"
        }
        if {$worker_script eq {}} {
            error "worker script must not be empty"
        }
        if {[catch {dict size $descriptor}]} {
            error "pool descriptor must be a dictionary"
        }

        set policy [my normalize_policy $policy]
        set maximum_workers [dict get $policy maximum_workers]
        set family [my pool_family $descriptor]
        set master [{*}$thread_master_factory new $worker_script $maximum_workers $family]

        set record [dict create pool_key        $pool_key   \
                                descriptor      $descriptor \
                                policy          $policy     \
                                worker_script   $worker_script \
                                lifecycle_state active      \
                                created_at      [clock seconds] \
                                thread_master   $master]
        dict set pools $pool_key $record

        if {[catch {
            set reserved {}
            for {set i 0} {$i < [dict get $policy minimum_workers]} {incr i} {
                set worker_id [$master acquire_worker]
                if {$worker_id eq {}} {
                    error "unable to create minimum workers for pool: $pool_key"
                }
                lappend reserved $worker_id
            }
            foreach worker_id $reserved {
                $master return_thread $worker_id
            }
        } error options]} {
            catch {$master stop_threads}
            catch {$master destroy}
            dict unset pools $pool_key
            return -options $options $error
        }

        return $pool_key
    }

    method destroy_pool {pool_key} {
        set pool_key [my normalize_pool_key $pool_key]
        set record [my require_pool $pool_key]
        set master [dict get $record thread_master]

        if {$master ne {}} {
            catch {$master stop_threads}
            catch {$master destroy}
        }
        dict unset pools $pool_key
        return $pool_key
    }

    method acquire_worker {pool_key} {
        set record [my require_pool $pool_key]
        if {[dict get $record lifecycle_state] ne "active"} {
            error "thread pool is not active: [dict get $record pool_key]"
        }
        return [[dict get $record thread_master] acquire_worker]
    }

    method release_worker {pool_key worker_id} {
        set record [my require_pool $pool_key]
        if {[dict get $record lifecycle_state] ne "active"} {
            error "thread pool is not active: [dict get $record pool_key]"
        }
        return [[dict get $record thread_master] return_thread $worker_id]
    }

    method resize_pool {pool_key limits} {
        set pool_key [my normalize_pool_key $pool_key]
        set record [my require_pool $pool_key]
        if {[dict get $record lifecycle_state] ne "active"} {
            error "thread pool is not active: $pool_key"
        }
        set policy [dict get $record policy]

        if {[string is integer -strict $limits]} {
            set limits [dict create maximum_workers $limits]
        }
        set policy [my normalize_policy [dict merge $policy $limits]]
        set master [dict get $record thread_master]
        $master resize [dict get $policy maximum_workers]

        dict set record policy $policy
        dict set pools $pool_key $record
        return $policy
    }

    method pool_status {pool_key} {
        set record [my require_pool $pool_key]
        set master [dict get $record thread_master]
        set stats [dict create \
            max_threads_number 0 \
            live_threads_number 0 \
            per_status_lists {}]
        if {$master ne {}} {
            set stats [$master stats]
        }

        return [dict merge $record [dict create \
            thread_master {} \
            stats $stats]]
    }

    method list_pools {} {
        return [lsort [dict keys $pools]]
    }

    method shutdown_pool {pool_key} {
        set pool_key [my normalize_pool_key $pool_key]
        set record [my require_pool $pool_key]
        set master [dict get $record thread_master]

        if {$master ne {}} {
            catch {$master stop_threads}
            catch {$master destroy}
        }
        dict set record thread_master {}
        dict set record lifecycle_state stopped
        dict set record stopped_at [clock seconds]
        dict set pools $pool_key $record
        return $pool_key
    }

    method shutdown_all {} {
        foreach pool_key [dict keys $pools] {
            catch {my shutdown_pool $pool_key}
        }
        return
    }

    method command_value {command name {default_marker __TPBA_REQUIRED__}} {
        if {[dict exists $command $name]} {
            return [dict get $command $name]
        }
        if {$default_marker ne "__TPBA_REQUIRED__"} {
            return $default_marker
        }
        error "missing TPBA command field: $name"
    }

    method execute_command {command} {
        if {[catch {dict size $command}]} {
            error "TPBA command must be a dictionary"
        }

        set correlation_id [my command_value $command correlation_id {}]
        if {[catch {
            set operation [my command_value $command operation]
            switch -exact -- $operation {
                create_pool {
                    set result [my create_pool  [my command_value $command pool_key {}]     \
                                                [my command_value $command worker_script]   \
                                                [my command_value $command policy {}]       \
                                                [my command_value $command descriptor {}]]
                }
                pool_key {
                    set result [my pool_key [my command_value $command descriptor]]
                }
                destroy_pool {
                    set result [my destroy_pool [my command_value $command pool_key]]
                }
                acquire_worker {
                    set result [my acquire_worker [my command_value $command pool_key]]
                }
                release_worker {
                    set result [my release_worker [my command_value $command pool_key] \
                                                  [my command_value $command worker_id]]
                }
                resize_pool {
                    set result [my resize_pool [my command_value $command pool_key] \
                                               [my command_value $command limits]]
                }
                pool_status {
                    set result [my pool_status [my command_value $command pool_key]]
                }
                list_pools {
                    set result [my list_pools]
                }
                shutdown_pool {
                    set result [my shutdown_pool [my command_value $command pool_key]]
                }
                shutdown_all {
                    my shutdown_all
                    set result {}
                }
                default {
                    error "unknown TPBA operation: $operation"
                }
            }
        } error options]} {
            return [dict create ok              0 \
                                correlation_id  $correlation_id \
                                error           $error \
                                errorcode       [dict get $options -errorcode]]
        }

        return [dict create ok              1 \
                            correlation_id  $correlation_id \
                            result          $result]
    }

    unexport command_value normalize_pool_key normalize_policy pool_family require_pool
}

if {[info commands ::tclwire::TPBA] eq {}} {
    interp alias {} ::tclwire::TPBA {} ::tclwire::ThreadPoolsBrokerAgent
}

package provide tclwire::tpba 0.1
