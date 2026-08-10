# five_minute_chore.tcl --
#
# Example file-backed chore that writes one error-log line every five minutes.

package require tclwire::chore 0.1
package require tclwire::configuration_tree 0.1
package require tclwire::logger::client 0.1
package require tclwire::tpba::control 0.1

oo::class create FiveMinuteLogChore {
    superclass ::tclwire::ServerChore

    variable every_ms last_run_ms logger

    constructor args {
        next {*}$args
        set every_ms 300000
        set last_run_ms 0
        set logger [::tclwire::logger::Client new chore]
        catch {
            ::tclwire::configuration tree [my server_config] \
                [list [self] log_error %s info]
        }
    }

    destructor {
        if {[info object isa object $logger]} {
            catch {$logger destroy}
        }
    }

    method log_error {message {level info}} {
        $logger log_error chore $message $level
        return
    }

    method should_run {wakeup} {
        set now [dict get $wakeup now_ms]
        return [expr {$last_run_ms == 0 || ($now - $last_run_ms) >= $every_ms}]
    }

    method run {wakeup} {
        set last_run_ms [dict get $wakeup now_ms]
        set m [format "five_minute_chore name=%s sequence=%d" [my name] [dict get $wakeup sequence]]
        my log_error $m info

        if {[catch {
            ::tclwire::tpba request [dict create operation list_pools]
        } response]} {
            my log_error "list_pools_error=$response" warn
            return [dict create logged 1 at_ms $last_run_ms pools {}]
        }

        if {![dict get $response ok]} {
            my log_error "list_pools_rejected=[dict get $response error]" warn
            return [dict create logged 1 at_ms $last_run_ms pools {}]
        }

        set pools [dict get $response result]
        my log_error "pools=[join $pools ,]" info
        foreach pool $pools {
            my log_error "pool=$pool" info
            set n 0
            set thread_response [::tclwire::tpba request [dict create operation pool_thread_ids \
                                                                      pool_key  $pool]]
            if {![dict get $thread_response ok]} {
                my log_error \
                    "pool_thread_ids_rejected pool=$pool error=[dict get $thread_response error]" warn
                continue
            }
            foreach thid [dict get $thread_response result] {
                my log_error "pool=$pool thread=[incr n] thread_id=$thid" info
            }
        }

        return [dict create logged 1 at_ms $last_run_ms pools $pools]
    }
}
