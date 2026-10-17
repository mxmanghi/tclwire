# Known-length, connection-thread-owned binary transfers. HTTP framing belongs
# to the caller; this object exclusively owns source reads and sink writes.
package require TclOO

namespace eval ::tclwire::transfer {
    proc validate {descriptor} {
        set file_source [dict exists $descriptor filename]
        set channel_source [dict exists $descriptor channel]
        if {$file_source == $channel_source} {
            error "download requires exactly one of filename or channel"
        }
        foreach key [dict keys $descriptor] {
            if {$key ni {filename filesize range channel length blocksize}} {
                error "unknown download field: $key"
            }
        }
        if {$file_source} {
            if {[file pathtype [dict get $descriptor filename]] ne "absolute"} {
                error "download filename must be absolute"
            }
            if {[dict exists $descriptor length]} {
                error "file downloads use filesize and range, not length"
            }
            set size [dict get $descriptor filesize]
            nonnegative filesize $size
            dict set descriptor filesize [expr {$size + 0}]
            if {[dict exists $descriptor range]} {
                set range [dict get $descriptor range]
                if {[llength $range] != 2} {
                    error "download range requires first and last byte offsets"
                }
                lassign $range first last
                nonnegative first $first
                nonnegative last $last
                if {$last < $first || $last >= $size} {
                    error "download range is outside the file"
                }
                dict set descriptor range [list [expr {$first + 0}] [expr {$last + 0}]]
            }
        } else {
            if {[dict exists $descriptor filesize] || [dict exists $descriptor range]} {
                error "channel downloads use length, not filesize or range"
            }
            nonnegative length [dict get $descriptor length]
            dict set descriptor length [expr {[dict get $descriptor length] + 0}]
        }
        if {![dict exists $descriptor blocksize]} {
            dict set descriptor blocksize 65536
        }
        nonnegative blocksize [dict get $descriptor blocksize]
        dict set descriptor blocksize [expr {[dict get $descriptor blocksize] + 0}]
        return $descriptor
    }

    proc nonnegative {name value} {
        if {![string is entier -strict $value] || $value < 0} {
            error "download $name must be a non-negative integer"
        }
    }
}

oo::class create ::tclwire::BodyTransfer {
    variable source sink length blocksize callback copied state failure scheduled

    # Ownership of source passes to this object only after construction succeeds.
    # blocksize=0 selects one asynchronous copy; otherwise callbacks checkpoint
    # bounded copies. The sink remains owned by the connection agent.
    constructor {input output size block command} {
        ::tclwire::transfer::nonnegative length $size
        ::tclwire::transfer::nonnegative blocksize $block
        chan configure $input -translation binary -encoding binary -blocking 0
        chan event $input readable {}
        set source      $input
        set sink        $output
        set length      $size
        set blocksize   $block
        set callback    $command
        set copied      0
        set state       ready
        set failure     {}
        set scheduled   {}
    }

    destructor { my cancel }

    method status {} {
        return [dict create state           $state  \
                            length          $length \
                            copied_bytes    $copied \
                            error           $failure]
    }

    method start {} {
        if {$state ne "ready"} { error "transfer has already started" }
        set state copying
        set scheduled [after 0 [namespace code {my copy_next}]]
    }

    method release_source {} {
        if {$source ne {}} {
            catch {close $source}
            set source {}
        }
    }

    method cancel {} {
        if {[info exists scheduled] && $scheduled ne {}} {
            after cancel $scheduled
            set scheduled {}
        }
        if {[info exists source]} { my release_source }
        if {[info exists state] && $state ni {completed failed cancelled}} {
            set state cancelled
        }
    }

    method notify {} { {*}$callback [my status] }

    method fail {message} {
        set state failed
        set failure $message
        my release_source
        my notify
    }

    method copy_next {} {
        set scheduled {}
        if {$state ne "copying"} { return }
        set remaining [expr {$length - $copied}]
        if {$remaining == 0} {
            my release_source
            set state draining
            my drain
            return
        }
        set count $remaining
        if {$blocksize > 0} { set count [expr {min($count, $blocksize)}] }
        if {[catch {
            fcopy $source $sink -size    $count \
                                -command [namespace code [list my copied $count]]
        } message]} {
            my fail $message
        }
    }

    method copied {requested count {message {}}} {
        if {$state ne "copying"} { return }
        incr copied $count
        if {$message ne {}} {
            my fail $message
        } elseif {$count != $requested} {
            my fail "download source ended before the declared length"
        } else {
            # Schedule before notifying: cancellation from the callback can
            # remove this continuation safely.
            set scheduled [after 0 [namespace code {my copy_next}]]
            my notify
        }
    }

    method drain {} {
        set scheduled {}
        if {$state ne "draining"} { return }
        if {[catch {chan pending output $sink} pending]} {
            my fail $pending
        } elseif {$pending > 0} {
            set scheduled [after 10 [namespace code {my drain}]]
        } else {
            set state completed
            my notify
        }
    }

    unexport release_source notify fail copy_next copied drain
}

package provide tclwire::body_transfer 0.1
