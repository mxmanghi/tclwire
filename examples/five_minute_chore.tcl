# five_minute_chore.tcl --
#
# Example file-backed chore that writes one error-log line every five minutes.

package require tclwire::chore 0.1
package require tclwire::logger::client 0.1
package require tclwire::tpba::control 0.1

oo::class create FiveMinuteLogChore {
    superclass ::tclwire::Chore

    variable every_ms last_run_ms

    constructor args {
        next {*}$args
        set every_ms 300000
        set last_run_ms 0
    }

    method should_run {wakeup} {
        set now [dict get $wakeup now_ms]
        return [expr {$last_run_ms == 0 || ($now - $last_run_ms) >= $every_ms}]
    }

    method run {wakeup} {
        set last_run_ms [dict get $wakeup now_ms]
        set m [format "five_minute_chore name=%s sequence=%d" [my name] [dict get $wakeup sequence]]
        ::tclwire::logger log_error chore $m info

        if {[catch {
            ::tclwire::tpba request [dict create operation list_pools]
        } response]} {
            ::tclwire::logger log_error chore "list_pools_error=$response" warn
            return [dict create logged 1 at_ms $last_run_ms pools {}]
        }

        if {![dict get $response ok]} {
            ::tclwire::logger log_error chore \
                "list_pools_rejected=[dict get $response error]" warn
            return [dict create logged 1 at_ms $last_run_ms pools {}]
        }

        set pools [dict get $response result]
        ::tclwire::logger log_error chore "pools=[join $pools ,]" info
        foreach pool $pools {
            ::tclwire::logger log_error chore "pool=$pool" info
        }

        return [dict create logged 1 at_ms $last_run_ms pools $pools]
    }
}
