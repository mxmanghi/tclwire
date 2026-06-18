# ftp_connection_agent.tcl --
#
# FTP specialization of the protocol-independent ConnectionAgent.

package require TclOO
package require tclwire::connection_agent 0.1
package require tclwire::ftp::protocol 0.1
package require tclwire::logger::client 0.1
package require fileutil

namespace eval ::tclwire {}

oo::class create ::tclwire::FtpConnectionAgent {
    superclass ::tclwire::ConnectionAgent

    variable channel closed protocol_session command_buffer ftp_root connection_key
    variable ftp_user_check bind_host session secure_transport
    variable tls_certfile tls_keyfile log_protocol timeout_id

    constructor {conn_channel id host port args} {
        array set options {
            -config {}
            -connectionkey {}
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        if {$options(-config) eq {}} {
            error "FTP connection agent requires configuration"
        }
        if {$options(-connectionkey) eq {}} {
            error "FTP connection agent requires connection key"
        }

        set config $options(-config)
        foreach field {ftproot ftp_user_check host} {
            if {![dict exists $config $field]} {
                error "FTP configuration is missing $field"
            }
        }

        next $conn_channel $id $host $port $options(-connectionkey)
        set protocol_session [::tclwire::FtpProtocolSession new]
        set command_buffer {}
        set ftp_root [::fileutil::fullnormalize [dict get $config ftproot]]
        set ftp_user_check [expr {[dict get $config ftp_user_check] ? 1 : 0}]
        set bind_host [dict get $config host]
        set log_protocol [dict get $config protocol]
        set secure_transport [expr {
            [dict exists $config secure] && [dict get $config secure]
        }]
        set tls_certfile {}
        set tls_keyfile {}
        if {$secure_transport} {
            set tls_certfile [dict get $config certfile]
            set tls_keyfile [dict get $config keyfile]
        }
        set session [dict create \
            cwd / \
            type A \
            passive_listener {} \
            data_channel {} \
            pending_action {} \
            upload_file_channel {} \
            upload_action {} \
            upload_argument {} \
            upload_bytes 0 \
            restart_offset 0 \
            rename_from {} \
            username {} \
            authenticated 0 \
            data_protection [expr {$secure_transport ? "P" : "C"}]]
        catch {
            ::tclwire::accounting update_connection $connection_key \
                [dict create request_count 0 current_command {}]
        }

        my send_reply 220 "TclWire FTP server ready"
        my start
    }

    destructor {
        my reset_passive_state
        catch {$protocol_session destroy}
        next
    }

    method readable {} {
        set chunk [my read_available]
        if {$chunk eq {} || $closed} {
            return
        }
        my clear_input_buffer
        append command_buffer $chunk

        if {[catch {
            set parsed [$protocol_session extract_commands $command_buffer]
        }]} {
            my send_reply 500 "Invalid command"
            set command_buffer {}
            return
        }
        set command_buffer [dict get $parsed remainder]
        foreach command_descriptor [dict get $parsed commands] {
            if {$closed} {
                break
            }
            dict set session current_command \
                [dict get $command_descriptor command]
            dict set session current_argument \
                [dict get $command_descriptor argument]
            catch {
                ::tclwire::accounting increment_connection_request_count \
                    $connection_key \
                    [dict create \
                        current_command [dict get $command_descriptor command]]
            }
            if {[catch {
                my execute_command \
                    [dict get $command_descriptor command] \
                    [dict get $command_descriptor argument]
            }]} {
                my send_reply 550 "Command failed"
            }
        }
        return
    }

    method send_control {data} {
        if {$closed} {
            return
        }
        if {[catch {
            puts -nonewline $channel [encoding convertto utf-8 $data]
            flush $channel
        }]} {
            my close
        }
        return
    }

    method send_reply {code message} {
        my send_control [$protocol_session format_reply $code $message]
        my log_command $code
    }

    method send_feature_reply {} {
        my send_control \
            "211-Features\r\n EPSV\r\n PASV\r\n SIZE\r\n MDTM\r\n REST STREAM\r\n211 End\r\n"
        my log_command 211
    }

    method refresh_timeout {} {
        if {$timeout_id ne {}} {
            after cancel $timeout_id
        }
        set timeout_id [after 900000 [list [self] timeout]]
        return
    }

    method timeout {} {
        set timeout_id {}
        my send_control [$protocol_session format_reply 421 \
            "Control connection timed out"]
        my close
        return
    }

    method command_requires_login {command} {
        return [expr {$command ni {USER PASS QUIT SYST FEAT NOOP PBSZ PROT}}]
    }

    method execute_command {command argument} {
        if {[my command_requires_login $command] &&
                ![dict get $session authenticated]} {
            my send_reply 530 "Please login with USER and PASS"
            return
        }

        switch -exact -- $command {
            USER {
                if {$argument eq {}} {
                    my send_reply 501 "Missing user name"
                    return
                }
                dict set session username $argument
                dict set session authenticated 0
                my send_reply 331 "User name ok, send password"
            }
            PASS {
                set username [dict get $session username]
                if {$username eq {}} {
                    my send_reply 503 "Login with USER first"
                } elseif {![my authenticate_user $username $argument]} {
                    my send_reply 530 "Login incorrect"
                } else {
                    dict set session authenticated 1
                    my send_reply 230 "Login successful"
                }
            }
            SYST {
                my send_reply 215 "UNIX Type: L8"
            }
            FEAT {
                my send_feature_reply
            }
            PWD -
            XPWD {
                my send_reply 257 "\"[dict get $session cwd]\" is the current directory"
            }
            TYPE {
                set type [string toupper $argument]
                if {$type ni {A I L8}} {
                    my send_reply 504 "Unsupported transfer type"
                    return
                }
                dict set session type $type
                my send_reply 200 "Type set to $type"
            }
            PBSZ {
                if {!$secure_transport} {
                    my send_reply 503 "PBSZ requires a secure control channel"
                } elseif {$argument ne "0"} {
                    my send_reply 501 "PBSZ must be zero"
                } else {
                    my send_reply 200 "PBSZ=0"
                }
            }
            PROT {
                set protection [string toupper $argument]
                if {!$secure_transport} {
                    my send_reply 503 "PROT requires a secure control channel"
                } elseif {$protection ni {C P}} {
                    my send_reply 536 "Unsupported protection level"
                } else {
                    dict set session data_protection $protection
                    my send_reply 200 "Data protection set to $protection"
                }
            }
            CWD {
                set virtual_path [my normalize_virtual_path \
                    [dict get $session cwd] $argument]
                if {![file isdirectory [my virtual_to_fs $virtual_path]]} {
                    my send_reply 550 "Failed to change directory"
                    return
                }
                dict set session cwd $virtual_path
                my send_reply 250 "Directory changed to $virtual_path"
            }
            CDUP {
                my execute_command CWD ..
            }
            MKD {
                if {[catch {
                    set virtual_path [my normalize_virtual_path \
                        [dict get $session cwd] $argument]
                    file mkdir [my virtual_to_fs $virtual_path]
                }]} {
                    my send_reply 550 "Directory creation failed"
                    return
                }
                my send_reply 257 "\"$virtual_path\" created"
            }
            NOOP {
                my send_reply 200 "NOOP ok"
            }
            EPSV {
                if {[string toupper $argument] eq "ALL"} {
                    my send_reply 200 "EPSV ALL ok"
                    return
                }
                if {[catch {set port [my open_passive_listener]}]} {
                    my send_reply 425 "Cannot open passive connection"
                    return
                }
                my send_reply 229 "Entering Extended Passive Mode (|||$port|)"
            }
            PASV {
                if {[catch {set port [my open_passive_listener]}]} {
                    my send_reply 425 "Cannot open passive connection"
                    return
                }
                set address $bind_host
                if {![regexp {^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$} \
                        $address -> h1 h2 h3 h4]} {
                    set address 127.0.0.1
                    lassign [split $address .] h1 h2 h3 h4
                }
                my send_reply 227 "Entering Passive Mode ($h1,$h2,$h3,$h4,[expr {$port / 256}],[expr {$port % 256}])"
            }
            SIZE {
                set fs_path [my resolve_path $argument]
                if {![file isfile $fs_path]} {
                    my send_reply 550 "Could not get file size"
                } else {
                    my send_reply 213 [file size $fs_path]
                }
            }
            MDTM {
                set fs_path [my resolve_path $argument]
                if {![file isfile $fs_path]} {
                    my send_reply 550 "Could not get file modification time"
                } else {
                    my send_reply 213 [clock format [file mtime $fs_path] \
                        -gmt 1 -format "%Y%m%d%H%M%S"]
                }
            }
            REST {
                if {![string is integer -strict $argument] || $argument < 0} {
                    my send_reply 501 "Invalid restart position"
                    return
                }
                dict set session restart_offset $argument
                my send_reply 350 "Restarting at $argument"
            }
            DELE {
                set fs_path [my resolve_path $argument]
                if {![file isfile $fs_path] || [catch {file delete -force $fs_path}]} {
                    my send_reply 550 "File unavailable"
                } else {
                    my send_reply 250 "File deleted"
                }
            }
            RNFR {
                set fs_path [my resolve_path $argument]
                if {![file exists $fs_path]} {
                    my send_reply 550 "File unavailable"
                } else {
                    dict set session rename_from $fs_path
                    my send_reply 350 "Ready for RNTO"
                }
            }
            RNTO {
                set from_path [dict get $session rename_from]
                if {$from_path eq {}} {
                    my send_reply 503 "Bad sequence of commands"
                    return
                }
                set to_path [my resolve_path $argument]
                if {[catch {
                    file mkdir [file dirname $to_path]
                    file rename -force $from_path $to_path
                }]} {
                    my send_reply 550 "Rename failed"
                } else {
                    dict set session rename_from {}
                    my send_reply 250 "Rename successful"
                }
            }
            SITE {
                my execute_site_command $argument
            }
            LIST -
            NLST -
            RETR -
            STOR {
                my begin_transfer $command $argument
            }
            QUIT {
                my send_reply 221 "Goodbye"
                my close
            }
            default {
                my send_reply 502 "Command not implemented"
            }
        }
        return
    }

    method authenticate_user {username password} {
        if {!$ftp_user_check} {
            return 1
        }
        if {$username eq {} || $password eq {}} {
            return 0
        }
        if {[catch {exec id -u -- $username}]} {
            return 0
        }
        return 0
    }

    method normalize_virtual_path {cwd path} {
        if {$path eq {}} {
            return $cwd
        }
        if {[string first "\\" $path] >= 0} {
            error "invalid FTP path"
        }
        set candidate [expr {[string match "/*" $path] \
            ? $path : [file join $cwd $path]}]
        set parts {}
        foreach element [split $candidate /] {
            switch -exact -- $element {
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
        return [expr {[llength $parts] == 0 ? "/" : "/[join $parts /]"}]
    }

    method virtual_to_fs {virtual_path} {
        set relative [string trimleft $virtual_path /]
        if {$relative eq {}} {
            return $ftp_root
        }
        set candidate [::fileutil::fullnormalize \
            [file join $ftp_root {*}[split $relative /]]]
        if {$candidate ne $ftp_root &&
                ![string match "${ftp_root}[file separator]*" $candidate]} {
            error "FTP path resolves outside the configured root"
        }
        return $candidate
    }

    method resolve_path {path} {
        return [my virtual_to_fs [my normalize_virtual_path \
            [dict get $session cwd] $path]]
    }

    method transfer_path {argument} {
        foreach token [split $argument] {
            if {$token ne {} && ![string match "-*" $token]} {
                return $token
            }
        }
        return {}
    }

    method open_passive_listener {} {
        my reset_passive_state
        set listener [socket -server [list [self] accept_data] \
            -myaddr $bind_host 0]
        dict set session passive_listener $listener
        return [lindex [fconfigure $listener -sockname] end]
    }

    method accept_data {data_channel host port} {
        if {$secure_transport &&
                [dict get $session data_protection] eq "P"} {
            if {[catch {
                set data_channel [::tclwire::prepare_connection_channel \
                    $data_channel [dict create \
                        secure 1 \
                        certfile $tls_certfile \
                        keyfile $tls_keyfile]]
            }]} {
                catch {close $data_channel}
                my reset_passive_state
                my send_reply 425 "Cannot secure data connection"
                return
            }
        }
        chan configure $data_channel \
            -blocking 1 -buffering none -translation binary
        set listener [dict get $session passive_listener]
        if {$listener ne {}} {
            catch {close $listener}
        }
        dict set session passive_listener {}
        dict set session data_channel $data_channel
        if {[dict get $session pending_action] ne {}} {
            my perform_pending_action
        }
        return
    }

    method begin_transfer {action argument} {
        if {$action in {LIST NLST}} {
            set argument [my transfer_path $argument]
        }
        dict set session pending_action \
            [dict create action $action argument $argument]
        my send_reply 150 "Opening data connection"
        if {[dict get $session data_channel] ne {}} {
            my perform_pending_action
        }
        return
    }

    method perform_pending_action {} {
        set pending [dict get $session pending_action]
        set data_channel [dict get $session data_channel]
        if {$pending eq {} || $data_channel eq {}} {
            return
        }

        set action [dict get $pending action]
        set argument [dict get $pending argument]
        set restart_offset [dict get $session restart_offset]
        set transferred_bytes 0
        set async_transfer 0
        dict set session pending_action {}
        dict set session restart_offset 0

        set status [catch {
            switch -exact -- $action {
                LIST {
                    set payload [encoding convertto utf-8 \
                        [my directory_listing $argument 0]]
                    set transferred_bytes [string length $payload]
                    puts -nonewline $data_channel $payload
                }
                NLST {
                    set payload [encoding convertto utf-8 \
                        [my directory_listing $argument 1]]
                    set transferred_bytes [string length $payload]
                    puts -nonewline $data_channel $payload
                }
                RETR {
                    set fs_path [my resolve_path $argument]
                    if {![file isfile $fs_path]} {
                        error "missing file"
                    }
                    set file_channel [open $fs_path rb]
                    try {
                        if {$restart_offset > 0} {
                            chan seek $file_channel $restart_offset start
                        }
                        set payload [read $file_channel]
                        set transferred_bytes [string length $payload]
                        puts -nonewline $data_channel $payload
                    } finally {
                        close $file_channel
                    }
                }
                STOR {
                    my start_upload $action $argument $data_channel
                    set async_transfer 1
                }
            }
            if {!$async_transfer} {
                flush $data_channel
            }
        }]

        if {!$status && $async_transfer} {
            return
        }
        my reset_passive_state
        if {$status} {
            my send_reply 550 "Transfer failed"
            my log_transfer $action $argument 550 0
        } else {
            my send_reply 226 "Transfer complete"
            my log_transfer $action $argument 226 $transferred_bytes
        }
        return
    }

    method start_upload {action argument data_channel} {
        set fs_path [my resolve_path $argument]
        if {![file isdirectory [file dirname $fs_path]]} {
            error "missing directory"
        }

        set file_channel [open $fs_path wb]
        chan configure $file_channel \
            -buffering none -translation binary
        chan configure $data_channel \
            -blocking 0 -buffering none -translation binary
        dict set session upload_file_channel $file_channel
        dict set session upload_action $action
        dict set session upload_argument $argument
        dict set session upload_bytes 0
        chan event $data_channel readable [list [self] upload_readable]
        my upload_readable
        return
    }

    method upload_readable {} {
        set data_channel [dict get $session data_channel]
        set file_channel [dict get $session upload_file_channel]
        if {$data_channel eq {} || $file_channel eq {}} {
            return
        }

        if {[catch {set chunk [read $data_channel]} error]} {
            my finish_upload 0 $error
            return
        }
        if {$chunk ne {}} {
            if {[catch {
                puts -nonewline $file_channel $chunk
            } error]} {
                my finish_upload 0 $error
                return
            }
            dict set session upload_bytes [expr {
                [dict get $session upload_bytes] + [string length $chunk]
            }]
            my refresh_timeout
        }
        if {[eof $data_channel]} {
            my finish_upload 1
        }
        return
    }

    method finish_upload {ok {error {}}} {
        set action [dict get $session upload_action]
        set argument [dict get $session upload_argument]
        set transferred_bytes [dict get $session upload_bytes]
        set file_channel [dict get $session upload_file_channel]
        set data_channel [dict get $session data_channel]

        if {$data_channel ne {}} {
            catch {chan event $data_channel readable {}}
        }
        if {$file_channel ne {}} {
            if {$ok && [catch {flush $file_channel} error]} {
                set ok 0
            }
            catch {close $file_channel}
        }
        dict set session upload_file_channel {}
        dict set session upload_action {}
        dict set session upload_argument {}
        dict set session upload_bytes 0

        my reset_passive_state
        if {$ok} {
            my send_reply 226 "Transfer complete"
            my log_transfer $action $argument 226 $transferred_bytes
        } else {
            my send_reply 550 "Transfer failed"
            my log_transfer $action $argument 550 0
        }
        return
    }

    method log_command {status} {
        if {![dict exists $session current_command]} {
            return
        }
        set command [dict get $session current_command]
        if {$command eq {}} {
            return
        }
        set argument [dict get $session current_argument]
        if {$command eq "PASS"} {
            set argument "<redacted>"
        }
        set remote_host [dict get [my peer] host]
        catch {
            ::tclwire::logger log $log_protocol \
                "command=$command argument=[::tclwire::logger log_value $argument] status=$status remote=[::tclwire::logger log_value $remote_host]"
        }
        return
    }

    method log_transfer {action path status bytes} {
        set remote_host [dict get [my peer] host]
        catch {
            ::tclwire::logger log $log_protocol \
                "transfer=$action path=[::tclwire::logger log_value $path] status=$status bytes=$bytes remote=[::tclwire::logger log_value $remote_host]"
        }
        return
    }

    method directory_listing {argument names_only} {
        set fs_path [my resolve_path $argument]
        if {![file exists $fs_path]} {
            error "missing path"
        }
        set entries [expr {[file isdirectory $fs_path] \
            ? [lsort [glob -nocomplain -directory $fs_path *]] \
            : [list $fs_path]}]
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
            set timestamp [clock format [file mtime $entry] \
                -format "%b %d %H:%M"]
            append listing [format "%s 1 owner group %8d %s %s\r\n" \
                $mode $size $timestamp $name]
        }
        return $listing
    }

    method execute_site_command {argument} {
        # Parse SITE arguments in two stages while preserving spaces in the
        # target path. The first expression captures the first non-whitespace
        # word as the subcommand and, when present, everything after its
        # separating whitespace as the operands.
        #
        # For CHMOD, the second expression requires a three- or four-digit
        # octal mode, followed by whitespace and a non-empty target. Capturing
        # the target as the complete remainder allows paths containing spaces.
        if {![regexp {^([^[:space:]]+)(?:[[:space:]]+(.*))?$} \
                $argument -> subcommand operands]} {
            my send_reply 502 "SITE command not implemented"
            return
        }
        if {[string toupper $subcommand] ne "CHMOD"} {
            my send_reply 502 "SITE command not implemented"
            return
        }
        if {![info exists operands] ||
                ![regexp {^([0-7]{3,4})[[:space:]]+(.+)$} \
                    $operands -> mode target]} {
            my send_reply 501 "Missing or invalid SITE CHMOD arguments"
            return
        }
        set fs_path [my resolve_path [string trim $target]]
        if {![file exists $fs_path]} {
            my send_reply 550 "SITE CHMOD target does not exist"
            return
        }
        if {[catch {
            file attributes $fs_path -permissions "0$mode"
        }]} {
            my send_reply 550 "SITE CHMOD failed"
            return
        }
        my send_reply 200 "SITE CHMOD command successful"
    }

    method reset_passive_state {} {
        if {![info exists session] || $session eq {}} {
            return
        }
        set upload_file_channel [dict get $session upload_file_channel]
        if {$upload_file_channel ne {}} {
            catch {close $upload_file_channel}
        }
        dict set session upload_file_channel {}
        dict set session upload_action {}
        dict set session upload_argument {}
        dict set session upload_bytes 0

        foreach field {passive_listener data_channel} {
            set data [dict get $session $field]
            if {$data ne {}} {
                catch {chan event $data readable {}}
                catch {close $data}
            }
            dict set session $field {}
        }
        dict set session pending_action {}
        return
    }

    method close {} {
        my reset_passive_state
        next
    }

    unexport authenticate_user begin_transfer command_requires_login \
        execute_site_command finish_upload open_passive_listener \
        perform_pending_action reset_passive_state resolve_path send_control \
        start_upload transfer_path virtual_to_fs log_command \
        log_transfer
}

package provide tclwire::ftp::connection_agent 0.1
