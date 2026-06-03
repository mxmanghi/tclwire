# ftp_server.tcl --
#
# Implementation of a simple FTP server for TclWire.
#
# Copyright (c) 2024-2026 Massimo Manghi
#
# SPDX-License-Identifier: TCL
#
# See the file "license.terms" at the top level of this distribution
# for information on usage and redistribution of this file, and for the
# complete disclaimer of warranties and limitation of liability.

namespace eval ::tclwire {}

package require Thread

oo::class create ::tclwire::ftp_service {
    superclass ::tclwire::service

    variable ftp_root ftp_user_check sessions connection_ids

    constructor args {
        array set sessions {}
        array set connection_ids {}
        next {*}$args

        set ftp_root [::tclwire::ftp_root]
        set ftp_user_check 1
        set config [my service_config]
        if {[dict exists $config ftproot] && [dict get $config ftproot] ne {}} {
            set ftp_root [file normalize [dict get $config ftproot]]
        }
        if {[dict exists $config ftp_user_check]} {
            set ftp_user_check [expr {[dict get $config ftp_user_check] ? 1 : 0}]
        }
    }

    destructor {
        foreach chan [array names sessions] {
            my close_session $chan
        }
        next
    }

    method start {} {
        if {[file exists $ftp_root] && ![file isdirectory $ftp_root]} {
            error "FTP root exists but is not a directory: $ftp_root"
        }
        if {![file exists $ftp_root]} {
            file mkdir $ftp_root
            ::tclwire::seed_ftp_root $ftp_root
        }

        set listener [my open_listener_socket]
        if {$listener eq {}} {
            return {}
        }
        my set_listener $listener
        my log [my listening_message]
        return $listener
    }

    method description {} {
        return "FTP server"
    }

    method accept {chan host port} {
        after idle [list [self] dispatch_accept $chan $host $port]
    }

    method dispatch_accept {chan host port} {
        set thread_master [my thread_master]
        if {$thread_master eq {}} {
            ::tclwire::msgoutput "no FTP thread master available for chan=$chan"
            catch {close $chan}
            return
        }

        set worker_thread_id [$thread_master acquire_worker]
        if {$worker_thread_id eq {}} {
            ::tclwire::msgoutput "no idle FTP worker available for chan=$chan"
            catch {close $chan}
            return
        }

        set connection_id [::tclwire::record_connection_opened \
            [my protocol] $chan $host $port [my endpoint] $worker_thread_id]

        if {[catch {thread::transfer $worker_thread_id $chan} transfer_error]} {
            ::tclwire::record_connection_closed $connection_id $transfer_error
            ::tclwire::msgoutput "FTP channel transfer failed chan=$chan worker=$worker_thread_id error=$transfer_error"
            catch {$thread_master return_thread $worker_thread_id}
            catch {close $chan}
            return
        }

        set config [my service_config]
        dict set config protocol [my protocol]
        dict set config connection_class [my connection_class]
        dict set config secure [my secure]
        dict set config host [my host]
        dict set config port [my port]
        ::tclwire::msgoutput "dispatch FTP connection id=$connection_id chan=$chan worker=$worker_thread_id"
        thread::send -async $worker_thread_id \
            [list ::tclwire::serve_transferred_ftp_connection $chan $connection_id $host $port $config]
    }

    method serve_connection {chan connection_id host port} {
        ::tclwire::msgoutput "worker serve FTP connection id=$connection_id chan=$chan"
        set connection_ids($chan) $connection_id
        chan configure $chan -blocking 0 \
                             -buffering line \
                             -translation crlf \
                             -encoding utf-8
        set sessions($chan) [dict create cwd / \
                                         type A \
                                         passive_listener {} \
                                         data_chan {} \
                                         pending_action {} \
                                         restart_offset 0 \
                                         rename_from {} \
                                         username {} \
                                         authenticated 0 \
                                         last_command {} \
                                         last_argument {}]
        my send_reply $chan 220 "TclWire FTP server ready"
        chan event $chan readable [list [self] read_command $chan]
    }

    method read_command {chan} {
        if {[eof $chan]} {
            my close_session $chan
            return
        }

        set line [gets $chan]
        if {$line eq {} && [chan pending input $chan] == 0} {
            return
        }
        if {$line eq {} && [eof $chan]} {
            my close_session $chan
            return
        }

        ::tclwire::msgoutput "ftp command chan=$chan line=$line"

        set command [string toupper [lindex [split $line] 0]]
        set argument [string trim [string range $line [string length $command] end]]
        dict set sessions($chan) last_command $command
        dict set sessions($chan) last_argument $argument

        if {[my command_requires_login $command] && ![dict get $sessions($chan) authenticated]} {
            my send_reply $chan 530 "Please login with USER and PASS"
            return
        }

        my handle_command $chan $command $argument
    }

    method command_requires_login {command} {
        return [expr {$command ni {USER PASS QUIT SYST FEAT NOOP}}]
    }

    method handle_command {chan command argument} {
        if {![info exists sessions($chan)]} {
            return
        }

        ::tclwire::msgoutput "TclWire FTP server: command '$command' received"
        switch -- $command {
            USER {
                dict set sessions($chan) username $argument
                dict set sessions($chan) authenticated 0
                if {$argument eq {}} {
                    my send_reply $chan 501 "Missing user name"
                    return
                }
                my send_reply $chan 331 "User name ok, send password"
            }
            PASS {
                set username [dict get $sessions($chan) username]
                if {$username eq {}} {
                    my send_reply $chan 503 "Login with USER first"
                    return
                }
                if {![my authenticate_user $username $argument]} {
                    my send_reply $chan 530 "Login incorrect"
                    return
                }

                dict set sessions($chan) authenticated 1
                my send_reply $chan 230 "Login successful"
            }
            SYST {
                my send_reply $chan 215 "UNIX Type: L8"
            }
            FEAT {
                puts $chan "211-Features"
                puts $chan " EPSV"
                puts $chan " PASV"
                puts $chan " SIZE"
                puts $chan " MDTM"
                puts $chan "211 End"
                flush $chan
                my log_request "command=FEAT status=211 path=[dict get $sessions($chan) cwd]"
            }
            PWD -
            XPWD {
                my send_reply $chan 257 "\"[dict get $sessions($chan) cwd]\" is the current directory"
            }
            TYPE {
                dict set sessions($chan) type [string toupper $argument]
                my send_reply $chan 200 "Type set to [dict get $sessions($chan) type]"
            }
            SITE {
                my handle_site_command $chan $argument
            }
            MKD {
                set virtual_path [my normalize_virtual_path [dict get $sessions($chan) cwd] $argument]
                file mkdir [my virtual_to_fs $virtual_path]
                my send_reply $chan 257 "\"$virtual_path\" created"
            }
            CWD {
                set virtual_path [my normalize_virtual_path [dict get $sessions($chan) cwd] $argument]
                set fs_path [my virtual_to_fs $virtual_path]
                if {![file isdirectory $fs_path]} {
                    my send_reply $chan 550 "Failed to change directory"
                    return
                }
                dict set sessions($chan) cwd $virtual_path
                my send_reply $chan 250 "Directory changed to $virtual_path"
            }
            CDUP {
                my handle_command $chan CWD ..
            }
            NOOP {
                my send_reply $chan 200 "NOOP ok"
            }
            EPSV {
                if {[string toupper $argument] eq "ALL"} {
                    my send_reply $chan 200 "EPSV ALL ok"
                    return
                }
                set port [my open_passive_listener $chan]
                my send_reply $chan 229 \
                    "Entering Extended Passive Mode ([my passive_triplet $port])"
            }
            PASV {
                set port [my open_passive_listener $chan]
                lassign [split [my host] .] h1 h2 h3 h4
                set p1 [expr {$port / 256}]
                set p2 [expr {$port % 256}]
                my send_reply $chan 227 "Entering Passive Mode ($h1,$h2,$h3,$h4,$p1,$p2)"
            }
            SIZE {
                set fs_path [my resolve_path $chan $argument]
                if {![file exists $fs_path] || [file isdirectory $fs_path]} {
                    my send_reply $chan 550 "Could not get file size"
                    return
                }
                my send_reply $chan 213 [file size $fs_path]
            }
            MDTM {
                set fs_path [my resolve_path $chan $argument]
                if {![file exists $fs_path] || [file isdirectory $fs_path]} {
                    my send_reply $chan 550 "Could not get file modification time"
                    return
                }
                set mtime [file mtime $fs_path]
                set timestamp [clock format $mtime -gmt 1 -format "%Y%m%d%H%M%S"]
                my send_reply $chan 213 $timestamp
            }
            REST {
                if {![string is entier -strict $argument] || $argument < 0} {
                    my send_reply $chan 501 "Invalid restart position"
                    return
                }
                dict set sessions($chan) restart_offset $argument
                my send_reply $chan 350 "Restarting at $argument"
            }
            DELE {
                set fs_path [my resolve_path $chan $argument]
                if {![file exists $fs_path] || [file isdirectory $fs_path]} {
                    my send_reply $chan 550 "File unavailable"
                    return
                }
                file delete -force $fs_path
                my send_reply $chan 250 "File deleted"
            }
            RNFR {
                set fs_path [my resolve_path $chan $argument]
                if {![file exists $fs_path]} {
                    my send_reply $chan 550 "File unavailable"
                    return
                }
                dict set sessions($chan) rename_from $fs_path
                my send_reply $chan 350 "Ready for RNTO"
            }
            RNTO {
                set from_path [dict get $sessions($chan) rename_from]
                if {$from_path eq {}} {
                    my send_reply $chan 503 "Bad sequence of commands"
                    return
                }
                set to_path [my resolve_path $chan $argument]
                file mkdir [file dirname $to_path]
                file rename -force $from_path $to_path
                dict set sessions($chan) rename_from {}
                my send_reply $chan 250 "Rename successful"
            }
            LIST {
                my begin_transfer $chan LIST $argument
            }
            NLST {
                my begin_transfer $chan NLST $argument
            }
            RETR {
                my begin_transfer $chan RETR $argument
            }
            STOR {
                my begin_transfer $chan STOR $argument
            }
            QUIT {
                my send_reply $chan 221 "Goodbye"
                my close_session $chan
            }
            default {
                my send_reply $chan 502 "Command not implemented"
            }
        }
    }

    method authenticate_user {username password} {
        if {!$ftp_user_check} {
            return 1
        }

        return [my authenticate_system_user $username $password]
    }

    method authenticate_system_user {username password} {
        if {$username eq {} || $password eq {}} {
            return 0
        }

        if {[catch {exec id -u -- $username}]} {
            return 0
        }

        # Pure Tcl cannot validate Unix shadow/PAM passwords safely. Keep this
        # path fail-closed until TclWire grows a native PAM/system-auth helper.
        ::tclwire::msgoutput \
            "FTP system password verification is unavailable in pure Tcl; use --noftp-user-check for local test sessions"
        return 0
    }

    method send_reply {chan code message} {
        if {[catch {
            puts $chan "$code $message"
            flush $chan
        }]} {
            my close_session $chan
            return
        }

        if {[info exists sessions($chan)]} {
            set command [dict get $sessions($chan) last_command]
            if {$command eq {}} {
                return
            }
            set argument [dict get $sessions($chan) last_argument]
            set path [expr {$argument eq {} ? [dict get $sessions($chan) cwd] : $argument}]
            my log_request \
                "command=$command status=$code path=[::tclwire::log_value $path]"
        }
    }

    method handle_site_command {chan argument} {
        set subcommand [string toupper [lindex [split $argument] 0]]

        switch -- $subcommand {
            CHMOD {
                set mode [lindex [split $argument] 1]
                set target [lindex [split $argument] 2]
                if {$mode eq {} || $target eq {}} {
                    my send_reply $chan 501 "Missing SITE CHMOD arguments"
                    return
                }

                set fs_path [my resolve_path $chan $target]
                if {![file exists $fs_path]} {
                    my send_reply $chan 550 "SITE CHMOD target does not exist"
                    return
                }

                if {[catch {file attributes $fs_path -permissions $mode}]} {
                    # Keep the test server lenient on platforms that do not
                    # honor POSIX mode changes the same way.
                }
                my send_reply $chan 200 "SITE CHMOD command successful"
            }
            default {
                my send_reply $chan 502 "SITE command not implemented"
            }
        }
    }

    method passive_triplet {port {delimiter |}} {
        return "${delimiter}${delimiter}${delimiter}${port}${delimiter}"
    }

    method normalize_virtual_path {cwd path} {
        if {$path eq {}} {
            return $cwd
        }

        if {[string match "/*" $path]} {
            set candidate $path
        } else {
            set candidate [file join $cwd $path]
        }

        set parts {}
        foreach element [split $candidate /] {
            switch -- $element {
                {} -
                . {
                    continue
                }
                .. {
                    if {[llength $parts] > 0} {
                        set parts [lrange $parts 0 end-1]
                    }
                }
                default {
                    lappend parts $element
                }
            }
        }

        if {[llength $parts] == 0} {
            return /
        }
        return /[join $parts /]
    }

    method virtual_to_fs {virtual_path} {
        set relative [string trimleft $virtual_path /]
        if {$relative eq {}} {
            return $ftp_root
        }
        return [file join $ftp_root {*}[split $relative /]]
    }

    method resolve_path {chan path} {
        return [my virtual_to_fs [my normalize_virtual_path [dict get $sessions($chan) cwd] $path]]
    }

    method transfer_path {argument} {
        set path {}
        foreach token [split $argument] {
            if {$token eq {}} {
                continue
            }
            if {[string match "-*" $token]} {
                continue
            }
            set path $token
            break
        }
        return $path
    }

    method open_passive_listener {chan} {
        my reset_passive_state $chan
        set listener [socket -server [list [self] accept_data $chan] -myaddr [my host] 0]
        dict set sessions($chan) passive_listener $listener
        return [lindex [fconfigure $listener -sockname] end]
    }

    method accept_data {control_chan data_chan host port} {
        if {![info exists sessions($control_chan)]} {
            catch {close $data_chan}
            return
        }

        chan configure $data_chan -blocking 1 -buffering none -translation binary
        set listener [dict get $sessions($control_chan) passive_listener]
        if {$listener ne {}} {
            catch {close $listener}
        }
        dict set sessions($control_chan) passive_listener {}
        dict set sessions($control_chan) data_chan $data_chan

        if {[dict get $sessions($control_chan) pending_action] ne {}} {
            my perform_pending_action $control_chan
        }
    }

    method begin_transfer {chan action argument} {
        if {$action in {LIST NLST}} {
            set argument [my transfer_path $argument]
        }
        dict set sessions($chan) pending_action [dict create action $action argument $argument]
        my send_reply $chan 150 "Opening data connection"

        if {[dict get $sessions($chan) data_chan] ne {}} {
            my perform_pending_action $chan
        }
    }

    method perform_pending_action {chan} {
        if {![info exists sessions($chan)]} {
            return
        }

        set pending [dict get $sessions($chan) pending_action]
        if {$pending eq {}} {
            return
        }

        set data_chan [dict get $sessions($chan) data_chan]
        if {$data_chan eq {}} {
            return
        }

        set action [dict get $pending action]
        set argument [dict get $pending argument]
        set restart_offset [dict get $sessions($chan) restart_offset]
        dict set sessions($chan) pending_action {}
        dict set sessions($chan) restart_offset 0

        set status [catch {
            switch -- $action {
                LIST {
                    puts -nonewline $data_chan [my directory_listing $chan $argument 0]
                }
                NLST {
                    puts -nonewline $data_chan [my directory_listing $chan $argument 1]
                }
                RETR {
                    set fs_path [my resolve_path $chan $argument]
                    if {![file exists $fs_path] || [file isdirectory $fs_path]} {
                        error "missing file"
                    }
                    set fh [open $fs_path rb]
                    try {
                        if {$restart_offset > 0} {
                            chan seek $fh $restart_offset start
                        }
                        puts -nonewline $data_chan [read $fh]
                    } finally {
                        close $fh
                    }
                }
                STOR {
                    set fs_path [my resolve_path $chan $argument]
                    if {![file isdirectory [file dirname $fs_path]]} {
                        error "missing directory"
                    }
                    set fh [open $fs_path wb]
                    fconfigure $fh -translation binary
                    try {
                        puts -nonewline $fh [read $data_chan]
                    } finally {
                        close $fh
                    }
                }
            }
            flush $data_chan
        }]

        my reset_passive_state $chan
        if {$status} {
            my send_reply $chan 550 "Transfer failed"
            return
        }

        my send_reply $chan 226 "Transfer complete"
    }

    method directory_listing {chan argument names_only} {
        set fs_path [my resolve_path $chan $argument]
        if {![file exists $fs_path]} {
            error "missing path"
        }

        if {[file isdirectory $fs_path]} {
            set entries [lsort [glob -nocomplain -directory $fs_path *]]
        } else {
            set entries [list $fs_path]
        }

        set listing {}
        foreach entry $entries {
            set name [file tail $entry]
            if {$names_only} {
                append listing "$name\r\n"
                continue
            }

            if {[file isdirectory $entry]} {
                set mode drwxr-xr-x
                set size 0
            } else {
                set mode -rw-r--r--
                set size [file size $entry]
            }
            set timestamp [clock format [file mtime $entry] -format "%b %d %H:%M"]
            append listing [format "%s 1 owner group %8d %s %s\r\n" \
                $mode $size $timestamp $name]
        }

        return $listing
    }

    method reset_passive_state {chan} {
        if {![info exists sessions($chan)]} {
            return
        }

        set listener [dict get $sessions($chan) passive_listener]
        if {$listener ne {}} {
            catch {close $listener}
        }
        set data_chan [dict get $sessions($chan) data_chan]
        if {$data_chan ne {}} {
            catch {close $data_chan}
        }
        dict set sessions($chan) passive_listener {}
        dict set sessions($chan) data_chan {}
    }

    method close_session {chan} {
        if {![info exists sessions($chan)]} {
            return
        }

        set connection_id {}
        if {[info exists connection_ids($chan)]} {
            set connection_id $connection_ids($chan)
            unset connection_ids($chan)
        }

        my reset_passive_state $chan
        catch {close $chan}
        unset sessions($chan)

        if {$connection_id ne {} && [info exists ::master_thread_id] && $::master_thread_id ne {}} {
            thread::send -async $::master_thread_id \
                [list ::tclwire::record_connection_closed $connection_id]
        }

        if {[info commands ::tclwire::accounting] ne {}} {
            catch {::tclwire::accounting change_thread_status [thread::id] idle}
        }
    }
}

::tclwire register_service_class ftp ::tclwire::ftp_service
