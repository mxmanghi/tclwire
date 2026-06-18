# proxy_connection_agent.tcl --
#
# HTTP proxy specialization of the protocol-independent ConnectionAgent.

package require TclOO
package require base64
package require tclwire::connection_agent 0.1
package require tclwire::proxy::protocol 0.1
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::ProxyConnectionAgent {
    superclass ::tclwire::ConnectionAgent

    variable channel closed protocol_session upstream_channel connection_key
    variable tunnel_active tunnel_pending

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
        if {$options(-connectionkey) eq {}} {
            error "proxy connection agent requires connection key"
        }

        next $conn_channel $id $host $port $options(-connectionkey)
        set protocol_session [::tclwire::ProxyProtocolSession new]
        set upstream_channel {}
        set tunnel_active 0
        set tunnel_pending 0
        my start
    }

    destructor {
        my close_upstream
        catch {$protocol_session destroy}
        next
    }

    method initial_read {} {
        if {$tunnel_active || $closed} {
            return
        }
        next
    }

    method readable {} {
        set chunk [my read_available]
        if {$chunk eq {} || $closed} {
            return
        }

        set buffered [my input_buffer]
        if {[catch {
            set request_data [$protocol_session complete_request $buffered]
        }]} {
            my send_generated_response 400 "Bad Request" "bad proxy request\n"
            return
        }
        if {$request_data eq {}} {
            return
        }

        set trailing [string range $buffered [string length $request_data] end]
        my clear_input_buffer
        chan event $channel readable {}
        my handle_proxy_request $request_data $trailing
    }

    method handle_proxy_request {request_data trailing} {
        if {[catch {
            set descriptor [$protocol_session parse_request $request_data]
        }]} {
            my log_request ? ? 400 0
            my send_generated_response 400 "Bad Request" "bad proxy request\n"
            return
        }

        set method [dict get $descriptor method]
        set target [dict get $descriptor target]
        catch {
            ::tclwire::accounting increment_connection_request_count \
                $connection_key [dict create current_command $method]
        }
        if {$method eq "CONNECT"} {
            if {[catch {
                set endpoint [$protocol_session parse_connect_target $target]
            }]} {
                my log_request $method $target 400 0
                my send_generated_response \
                    400 "Bad Request" "bad proxy request\n"
                return
            }
            my start_tunnel $endpoint $trailing
            return
        }

        if {[catch {
            set endpoint [$protocol_session parse_target \
                $target [dict get $descriptor headers]]
        }]} {
            my log_request $method $target 400 0
            my send_generated_response 400 "Bad Request" "bad proxy request\n"
            return
        }

        set origin_path [dict get $endpoint path]
        if {$origin_path eq "/proxy-auth-target"} {
            set auth_status [my validate_proxy_auth \
                [dict get $descriptor headers]]
            if {$auth_status ne "ok"} {
                my log_request $method $origin_path 407 0
                my send_generated_response \
                    407 "Proxy Authentication Required" \
                    "proxy-auth=$auth_status\n" \
                    [list "Proxy-Authenticate: Basic realm=\"TclWire Proxy\""]
                return
            }
        }

        if {[catch {
            set upstream_channel [socket \
                [dict get $endpoint host] [dict get $endpoint port]]
        } message]} {
            my log_request $method $origin_path 502 0
            my send_generated_response \
                502 "Bad Gateway" "proxy-error=$message\n"
            return
        }

        chan configure $upstream_channel \
            -blocking 0 -buffering none -translation binary
        set upstream_request \
            [$protocol_session build_upstream_request $descriptor $endpoint]
        if {[catch {
            puts -nonewline $upstream_channel $upstream_request
            flush $upstream_channel
        } message]} {
            my close_upstream
            my log_request $method $origin_path 502 0
            my send_generated_response \
                502 "Bad Gateway" "proxy-error=$message\n"
            return
        }

        dict set descriptor proxy_path $origin_path
        my begin_transaction 1 $descriptor
        set transaction [my transaction_for 1]
        $transaction set upstream_response {}
        chan event $upstream_channel readable [list [self] upstream_readable]
        my upstream_readable
        return
    }

    method upstream_readable {} {
        if {$upstream_channel eq {} || $closed} {
            return
        }
        set transaction [my transaction_for 1]
        if {$transaction eq {}} {
            return
        }

        set chunk [read $upstream_channel]
        if {$chunk ne {}} {
            $transaction append upstream_response $chunk
        }
        if {![eof $upstream_channel]} {
            return
        }

        set response [$transaction get upstream_response]
        set status ?
        if {[regexp {^HTTP/[0-9.]+\s+([0-9]+)} $response -> parsed_status]} {
            set status $parsed_status
        }
        set descriptor [my finish_transaction 1]
        my close_upstream
        my log_request \
            [dict get $descriptor method] \
            [dict get $descriptor proxy_path] \
            $status \
            [string length $response]
        my write_and_close $response
    }

    method validate_proxy_auth {headers} {
        if {![dict exists $headers proxy-authorization]} {
            return missing
        }
        set authorization [dict get $headers proxy-authorization]
        if {![regexp -nocase {^Basic\s+(.+)$} \
                $authorization -> auth_blob]} {
            return invalid
        }
        if {[catch {set decoded [::base64::decode $auth_blob]}]} {
            return invalid
        }
        return [expr {$decoded eq "proxyuser:proxypass" ? "ok" : "denied"}]
    }

    method start_tunnel {endpoint trailing} {
        set host [dict get $endpoint host]
        set port [dict get $endpoint port]
        set target "$host:$port"
        if {[catch {set upstream_channel [socket $host $port]} message]} {
            my log_request CONNECT $target 502 0
            my send_generated_response \
                502 "Bad Gateway" "proxy-error=$message\n"
            return
        }
        chan configure $upstream_channel \
            -blocking 0 -buffering none -translation binary

        if {[catch {
            puts -nonewline $channel \
                "HTTP/1.1 200 Connection Established\r\n\r\n"
            flush $channel
            if {$trailing ne {}} {
                puts -nonewline $upstream_channel $trailing
                flush $upstream_channel
            }
        }]} {
            my close_upstream
            my close
            return
        }

        set tunnel_active 1
        set tunnel_pending 2
        my log_request CONNECT $target 200 0
        chan copy $channel $upstream_channel -command \
            [list [self] tunnel_copy_done client_to_upstream]
        chan copy $upstream_channel $channel -command \
            [list [self] tunnel_copy_done upstream_to_client]
        return
    }

    method tunnel_copy_done {direction bytes {error {}}} {
        if {!$tunnel_active} {
            return
        }
        if {$error ne {}} {
            my close
            return
        }
        incr tunnel_pending -1
        if {$tunnel_pending <= 0} {
            my close
        }
        return
    }

    method send_generated_response {status reason body {headers {}}} {
        set response [$protocol_session build_response \
            $status $reason $body utf-8 \
            [concat [list "Content-Type: text/plain; charset=utf-8"] $headers]]
        my write_and_close $response
    }

    method log_request {method target status bytes} {
        set remote_host [dict get [my peer] host]
        catch {
            ::tclwire::logger log proxy \
                "method=[::tclwire::logger log_value $method] target=[::tclwire::logger log_value $target] status=$status bytes=$bytes remote=[::tclwire::logger log_value $remote_host]"
        }
        return
    }

    method close_upstream {} {
        if {$upstream_channel ne {}} {
            catch {chan event $upstream_channel readable {}}
            catch {close $upstream_channel}
            set upstream_channel {}
        }
        return
    }

    method close {} {
        set tunnel_active 0
        my close_upstream
        next
    }

    unexport close_upstream handle_proxy_request initial_read log_request \
        send_generated_response start_tunnel validate_proxy_auth
}

package provide tclwire::proxy::connection_agent 0.1
