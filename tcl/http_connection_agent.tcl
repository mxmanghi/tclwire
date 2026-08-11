# http_connection_agent.tcl --
#
# HTTP specialization of the protocol-independent ConnectionAgent.

package require TclOO
package require tclwire::connection_agent 0.1
package require tclwire::http::protocol 0.1
package require tclwire::http::errors 0.1
package require tclwire::http::multipart 0.1
package require tclwire::application_dispatcher 0.1
package require tclwire::logger::client 0.1

namespace eval ::tclwire {}

oo::class create ::tclwire::HttpConnectionAgent {
    superclass ::tclwire::ConnectionAgent

    variable protocol_session application_dispatcher closed channel connection_key
    variable next_transaction_id default_encoding log_protocol log_service_id
    variable upload_area max_request_bytes max_header_bytes
    variable dump_multipart_requests
    variable request_memory_threshold request_bytes
    variable request_head
    variable request_prefix
    variable continue_response_sent
    variable loggers

    constructor {conn_channel id host port args} {
        array set options {
            -applicationconfig          {}
            -connectionkey              {}
            -protocol                   http
            -serviceid                  {}
            -uploadarea                 /tmp
            -maxrequestbytes            16777216
            -maxheaderbytes             65536
            -requestmemorythreshold     1048576
            -dumpmultipartrequests      0
        }
        foreach {name value} $args {
            if {![info exists options($name)]} {
                error "unknown option: $name"
            }
            set options($name) $value
        }
        if {$options(-applicationconfig) eq {}} {
            error "HTTP connection agent requires application configuration"
        }
        if {$options(-connectionkey) eq {}} {
            error "HTTP connection agent requires connection key"
        }

        next $conn_channel $id $host $port $options(-connectionkey)
        set protocol_threshold $options(-requestmemorythreshold)
        if {$options(-uploadarea) eq {}} {
            set protocol_threshold $options(-maxrequestbytes)
        }
        set protocol_session [::tclwire::HttpProtocolSession new -bodythreshold  $protocol_threshold \
                                                                 -spooldirectory $options(-uploadarea) \
                                                                 -maxbodybytes   $options(-maxrequestbytes) \
                                                                 -secure         [expr {$options(-protocol) eq "https"}]]

        # Pivotal object: it selects the HTTP application based on the Host: header

        set application_dispatcher [::tclwire::ApplicationDispatcher new $options(-applicationconfig)]
        set default_application [dict get $options(-applicationconfig) default_application]
        set default_encoding [dict get [$application_dispatcher application $default_application] encoding]
        set log_protocol $options(-protocol)
        set log_service_id [expr {
            $options(-serviceid) eq {} ? $options(-protocol) : $options(-serviceid)
        }]
        set loggers [dict create \
            $log_service_id [::tclwire::logger::Client new $log_service_id]]
        set upload_area $options(-uploadarea)
        if {![string is boolean -strict $options(-dumpmultipartrequests)]} {
            error "-dumpmultipartrequests must be a boolean"
        }
        set dump_multipart_requests [expr {!!$options(-dumpmultipartrequests)}]
        foreach {option variable_name} {
            -maxrequestbytes max_request_bytes
            -maxheaderbytes  max_header_bytes
        } {
            if {![string is integer -strict $options($option)] ||
                    $options($option) < 1} {
                error "$option must be a positive integer"
            }
            set $variable_name $options($option)
        }
        if {![string is integer -strict $options(-requestmemorythreshold)] ||
                $options(-requestmemorythreshold) < 0} {
            error "-requestmemorythreshold must be a non-negative integer"
        }
        set request_memory_threshold $options(-requestmemorythreshold)
        set next_transaction_id 0
        set request_bytes 0
        set request_head 0
        set request_prefix {}
        set continue_response_sent 0
        my start
    }

    destructor {
        catch {$application_dispatcher destroy}
        catch {$protocol_session destroy}
        dict for {client logger} $loggers {
            catch {$logger destroy}
        }
        next
    }

    method logger_for_client {client} {
        if {![dict exists $loggers $client]} {
            dict set loggers $client [::tclwire::logger::Client new $client]
        }
        return [dict get $loggers $client]
    }

    method readable {} {
        set read_limit [expr {$max_request_bytes - $request_bytes + 1}]
        set chunk [my read_available [expr {max(1, min(65536, $read_limit))}]]
        if {$chunk eq {} || $closed} {
            return
        }
        my clear_input_buffer
        if {([string first " " $request_prefix]) < 0 &&
            ([string length $request_prefix] < 16)} {
            append request_prefix \
                [string range $chunk 0 15-[string length $request_prefix]]
            set request_head [regexp {^HEAD[ \t]} $request_prefix]
        }
        incr request_bytes [string length $chunk]
        if {$request_bytes > $max_request_bytes} {
            my send_error 413 {} $request_head
            return
        }
        if {[catch {
            set result [$protocol_session feed $chunk]
        } message options]} {
            if {[dict exists $options -errorcode] &&
                [dict get $options -errorcode] eq {TCLWIRE HTTP BODY_TOO_LARGE}} {
                my send_error 413 {} $request_head
            } else {
                my send_error 400 {} $request_head
            }
            return
        }
        if {[dict get $result method] ne {}} {
            set request_head [expr {[dict get $result method] eq "HEAD"}]
        }

        # we protect the server from malformed abnormal headers by
        # establishing a reasonable headers max length (max_header_bytes)

        if {[dict get $result header_size] > $max_header_bytes} {
            my send_error 431 {} $request_head
            return
        }

        if {[dict get $result status] eq "need_more"} {

            # Again we protect the server from resource depletion by
            # establishing a maximum message size (max_request_bytes)

            if {[dict get $result declared_request_size] > $max_request_bytes} {
                my send_error 413 {} $request_head
                return
            }
            if {[dict get $result phase] eq "headers" && ($request_bytes > $max_header_bytes)} {
                my send_error 431 {} $request_head
            }
            if {[dict get $result phase] eq "body"} {
                my send_continue_response_if_needed
            }
            return
        }

        set request_d [dict get $result descriptor]
        chan event $channel readable {}
        my handle_request_descriptor $request_d
    }

    method build_request_descriptor {request_data} {
        if {[catch {dict get $request_data method}]} {
            set descriptor [$protocol_session parse_request $request_data]
        } else {
            set descriptor $request_data
        }

        if {([dict get $descriptor body_storage] eq "in_memory") && ($upload_area ne {}) && 
            [dict exists $descriptor headers content-type]} {

            set content_type [dict get $descriptor headers content-type]
            set content_info [::tclwire::http::message parse_content_type $content_type]

            if {[string match multipart/* [dict get $content_info media_type]]} {
                set parts [::tclwire::http::multipart parse $content_type [dict get $descriptor body]]
                set parts [::tclwire::http::multipart store_files $parts $upload_area]

                dict set descriptor multipart_parts $parts
                if {[dict exists $descriptor body]} {
                    dict unset descriptor body
                }
                dict set descriptor body_media multipart
                dict set descriptor body_storage decomposed
            }
        }
        set peer [my peer]
        dict set descriptor protocol $log_protocol
        dict set descriptor connection_id [my connection_id]
        dict set descriptor remote_host [dict get $peer host]
        dict set descriptor remote_port [dict get $peer port]
        return $descriptor
    }

    method request_host {request_descriptor} {
        if {![dict exists $request_descriptor headers host]} {
            return {}
        }
        set host [string tolower [string trim [dict get $request_descriptor headers host]]]
        if {[regexp {^\[([^\]]+)\](?::[0-9]+)?$} $host -> address]} {
            return $address
        }
        regsub {:[0-9]+$} $host {} host
        return $host
    }

    method cleanup_request_body {request_d} {
        if {[dict exists $request_d body_storage] &&
                [dict get $request_d body_storage] eq "spooled_file" &&
                [dict exists $request_d body_path]} {
            catch {file delete [dict get $request_d body_path]}
        }
        return
    }

    method dispatch_request_descriptor {request_d} {
        my clear_input_buffer
        catch {
            ::tclwire::accounting set_thread_http_host \
                [::thread::id] [my request_host $request_d]
        }

        set transaction_id [incr next_transaction_id]
        dict set request_d transaction_id       $transaction_id
        dict set request_d connection_thread_id [::thread::id]
        dict set request_d connection_agent_id  [self]
        catch {
            ::tclwire::accounting increment_connection_request_count \
                $connection_key \
                [dict create \
                    current_transaction_id $transaction_id \
                    current_command [dict get $request_d method]]
        }

        my begin_transaction $transaction_id $request_d
        set transaction [my transaction_for $transaction_id]
        $transaction set response_body      {}
        $transaction set response_status    200
        $transaction set response_reason    OK
        $transaction set response_headers   {}
        $transaction set response_body_mode text
        $transaction set response_body_mode_explicit 0
        $transaction set response_state     preparing
        $transaction set response_bytes     0
        $transaction set output_sequence    0
        if {[catch {
            set dispatch_info [$application_dispatcher dispatch [$transaction snapshot]]
        } message]} {
            set request_d [my finish_transaction $transaction_id]
            if {[dict exists $request_d multipart_parts]} {
                ::tclwire::http::multipart cleanup_files \
                    [dict get $request_d multipart_parts]
            }
            my cleanup_request_body $request_d
            if {[string match "no application is configured for Host *" $message]} {
                my log_request $request_d 404 0
                my send_error 404 [dict create path [dict get $request_d path]] \
                                  [my head_only $request_d]
            } else {
                my log_request $request_d 503 0
                my send_error 503 {} [my head_only $request_d]
            }
            return {}
        }
        $transaction set application_id       [dict get $dispatch_info application_id]
        $transaction set application_pool_key [dict get $dispatch_info pool_key]
        $transaction set response_encoding    [dict get $dispatch_info encoding]
        return [$transaction snapshot]
    }

    method handle_request_descriptor {request_d} {
        my dump_multipart_descriptor $request_d
        if {[catch {
            set request_d [my build_request_descriptor $request_d]
        }]} {
            my cleanup_request_body $request_d
            my log_request {} 400 0
            my send_error 400 {} [expr {[dict get $request_d method] eq "HEAD"}]
            return {}
        }
        return [my dispatch_request_descriptor $request_d]
    }

    method dump_multipart_descriptor {request_d} {
        if {!$dump_multipart_requests ||
                ![dict exists $request_d headers content-type]} {
            return
        }
        if {[catch {
            set content_info [::tclwire::http::message parse_content_type \
                [dict get $request_d headers content-type]]
            set is_multipart [string match multipart/* \
                [dict get $content_info media_type]]
        }] || !$is_multipart} {
            return
        }
        catch {
            puts stderr "--- TclWire HTTP multipart request dump ([dict get $request_d body_size] body bytes) ---"
            puts stderr "[dict get $request_d method] [dict get $request_d target] HTTP/[dict get $request_d version]"
            dict for {name value} [dict get $request_d headers] {
                puts stderr "$name: $value"
            }
            puts stderr {}
            if {[dict get $request_d body_storage] eq "in_memory"} {
                puts -nonewline stderr [dict get $request_d body]
            } elseif {[dict get $request_d body_storage] eq "spooled_file"} {
                set dump_channel [open [dict get $request_d body_path] rb]
                try { fcopy $dump_channel stderr } finally { close $dump_channel }
            } else {
                puts stderr "<multipart body decomposed into parts>"
            }
            puts stderr "\n--- end TclWire HTTP multipart request dump ---"
            flush stderr
        }
        return
    }

    method header_name {header} {
        if {![regexp {^([^:]+):} $header -> name]} {
            error "invalid HTTP response header"
        }
        return [string trim $name]
    }

    method header_value {header} {
        if {![regexp {^[^:]+:\s*(.*)$} $header -> value]} {
            error "invalid HTTP response header"
        }
        return $value
    }

    method response_header_values {transaction name} {
        set values {}
        foreach header [$transaction get response_headers] {
            if {[string equal -nocase [my header_name $header] $name]} {
                lappend values [my header_value $header]
            }
        }
        return $values
    }

    method chunked_response {transaction} {
        set values [my response_header_values $transaction Transfer-Encoding]
        if {[llength $values] == 0} {
            return 0
        }
        if {[llength $values] != 1 ||
                ![string equal -nocase [string trim [lindex $values 0]] chunked]} {
            error "unsupported response Transfer-Encoding"
        }
        if {[llength [my response_header_values \
                $transaction Content-Length]] > 0} {
            error "response contains both Transfer-Encoding and Content-Length"
        }
        if {[$transaction get version] ne "1.1"} {
            error "chunked responses require HTTP/1.1"
        }
        return 1
    }

    method head_only {request_state} {
        if {[info object isa typeof \
                $request_state ::tclwire::TransactionDescriptor]} {
            set method [$request_state get method]
        } else {
            set method [dict get $request_state method]
        }
        return [expr {$method eq "HEAD"}]
    }

    method apply_header_event {transaction flags} {
        if {[$transaction get response_state] ne "preparing"} {
            error "HTTP response headers have already been sent"
        }

        set action [dict get $flags action]
        set name [dict get $flags name]
        set value {}
        if {[dict exists $flags value]} {
            set value [dict get $flags value]
        }
        if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name] ||
                [string first "\r" $value] >= 0 ||
                [string first "\n" $value] >= 0} {
            error "invalid HTTP response header"
        }

        set headers {}
        foreach header [$transaction get response_headers] {
            if {$action in {set remove} &&
                    [string equal -nocase [my header_name $header] $name]} {
                continue
            }
            lappend headers $header
        }
        switch -exact -- $action {
            set -
            add {
                lappend headers "$name: $value"
            }
            remove {}
            default {
                error "unknown HTTP header operation: $action"
            }
        }
        $transaction set response_headers $headers
        my chunked_response $transaction
        return
    }

    method commit_chunked_response {transaction} {
        if {[$transaction get response_state] eq "committed"} {
            return
        }
        if {![my chunked_response $transaction]} {
            error "response is not configured for chunked transfer"
        }
        set response_head [$protocol_session build_chunked_response_head \
            [$transaction get response_status] \
            [$transaction get response_reason] \
            [$transaction get response_encoding] \
            [$transaction get response_headers] \
            [$transaction get response_body_mode]]
        if {![my write_output $response_head]} {
            error "failed to write HTTP response headers"
        }
        $transaction set response_state committed
        return
    }

    method enable_chunked_response_for_flush {transaction} {
        if {[$transaction get response_state] ne "preparing"} {
            return [my chunked_response $transaction]
        }
        if {[llength [my response_header_values \
                $transaction Transfer-Encoding]] > 0} {
            return [my chunked_response $transaction]
        }
        if {[llength [my response_header_values \
                $transaction Content-Length]] > 0} {
            return 0
        }
        if {[$transaction get version] ne "1.1"} {
            return 0
        }

        set headers [$transaction get response_headers]
        lappend headers "Transfer-Encoding: chunked"
        $transaction set response_headers $headers
        return [my chunked_response $transaction]
    }

    method write_chunked_response_body {transaction body body_mode} {
        my commit_chunked_response $transaction
        if {[my head_only $transaction]} {
            return
        }
        set body_bytes [$protocol_session encode_response_body \
            $body \
            [$transaction get response_encoding] \
            $body_mode]
        set frame [$protocol_session chunk_frame $body_bytes]
        if {$frame ne {} && ![my write_output $frame]} {
            error "failed to write HTTP response chunk"
        }
        $transaction incr response_bytes [string length $body_bytes]
        return
    }

    method log_application_response_abort {transaction reason options} {
        if {$reason eq {}} {
            return
        }
        set descriptor {}
        if {[info object isa object $transaction]} {
            set descriptor [$transaction snapshot]
        }

        set client $log_service_id
        set context [dict create service_id $log_service_id]
        if {$descriptor ne {} && [dict exists $descriptor application_id]} {
            set client [dict get $descriptor application_id]
            dict set context application_id $client
        }
        if {$descriptor ne {} && [dict exists $descriptor headers host]} {
            dict set context host [dict get $descriptor headers host]
        }

        set fields [list \
            "reason=[::tclwire::logger::log_value $reason]"]
        foreach field {application_id transaction_id method path response_state response_body_mode} {
            if {$descriptor ne {} && [dict exists $descriptor $field]} {
                lappend fields \
                    "$field=[::tclwire::logger::log_value [dict get $descriptor $field]]"
            }
        }
        foreach {option label} {-errorcode errorcode -errorinfo errorinfo} {
            if {[dict exists $options $option]} {
                lappend fields \
                    "$label=[::tclwire::logger::log_value [dict get $options $option]]"
            }
        }

        if {[catch {
            set logger [my logger_for_client $client]
            $logger log_error application_output [join $fields " "] error $context
        }]} {
            catch {puts stderr "application_output level=error [join $fields " "]"}
        }
        return
    }

    method abort_application_response {transaction_id transaction {reason {}} {options {}}} {
        set transaction [my transaction_for $transaction_id]
        if {![info object isa object $transaction]} {
            return
        }
        my log_application_response_abort $transaction $reason $options
        set response_state [$transaction get response_state]
        set head_only [my head_only $transaction]
        my finish_transaction $transaction_id
        if {$response_state eq "preparing"} {
            my send_error 500 {} $head_only
        } else {
            my close
        }
        return
    }

    method application_output {transaction_id event} {
        set transaction [my transaction_for $transaction_id]
        if {![info object isa object $transaction]} {
            return
        }

        set expected [expr {[$transaction get output_sequence] + 1}]
        if {[dict get $event output_sequence] != $expected} {
            my log_application_response_abort $transaction \
                "application output event sequence mismatch: expected $expected, received [dict get $event output_sequence]" \
                {}
            set head_only [my head_only $transaction]
            my finish_transaction $transaction_id
            my send_error 500 {} $head_only
            return
        }
        $transaction set output_sequence $expected

        switch -exact -- [dict get $event type] {
            response {
                if {[$transaction get response_state] ne "preparing" ||
                        [$transaction get response_body] ne {}} {
                    my abort_application_response $transaction_id $transaction \
                        "response event arrived after response output started"
                    return
                }
                set flags [dict get $event flags]
                foreach field {status reason headers body_mode} {
                    $transaction set response_$field [dict get $flags $field]
                }
                $transaction set response_body_mode_explicit 1
                if {[dict get $flags encoding] ne {}} {
                    $transaction set response_encoding \
                        [dict get $flags encoding]
                }
                if {[catch {my chunked_response $transaction} message options]} {
                    my abort_application_response $transaction_id $transaction \
                        $message $options
                    return
                }
            }
            http_header {
                if {[catch {
                    my apply_header_event $transaction [dict get $event flags]
                } message options]} {
                    my abort_application_response $transaction_id $transaction \
                        $message $options
                    return
                }
            }
            output {
                set body_mode [$transaction get response_body_mode]
                if {[dict exists $event flags body_mode]} {
                    set body_mode [dict get $event flags body_mode]
                }
                if {$body_mode ne [$transaction get response_body_mode]} {
                    if {[$transaction get response_state] eq "preparing" &&
                            ![$transaction get response_body_mode_explicit] &&
                            [$transaction get response_body] eq {} &&
                            [$transaction get response_bytes] == 0} {
                        $transaction set response_body_mode $body_mode
                    } else {
                        my abort_application_response $transaction_id $transaction \
                            "application output body mode changed from [$transaction get response_body_mode] to $body_mode"
                        return
                    }
                }
                if {[catch {set chunked [my chunked_response $transaction]} message options]} {
                    my abort_application_response $transaction_id $transaction \
                        $message $options
                    return
                }
                if {$chunked} {
                    if {[catch {
                        my write_chunked_response_body \
                            $transaction [dict get $event data] $body_mode
                    } message options]} {
                        my abort_application_response $transaction_id $transaction \
                            $message $options
                        return
                    }
                } else {
                    $transaction append response_body [dict get $event data]
                }
            }
            no_body {
                if {[$transaction get response_bytes] > 0} {
                    my abort_application_response $transaction_id $transaction \
                        "no_body event arrived after response bytes were sent"
                    return
                }
                set response_headers {}
                foreach response_header [$transaction get response_headers] {
                    if {![string equal -nocase \
                            [my header_name $response_header] Content-Length]} {
                        lappend response_headers $response_header
                    }
                }
                $transaction set response_headers $response_headers
                $transaction set response_body {}
            }
            flush {
                if {[catch {
                    set channel_event_flags [dict get $event flags]
                    if {[dict get $channel_event_flags auto_chunked_on_flush]} {
                        set chunked [my enable_chunked_response_for_flush \
                            $transaction]
                    } else {
                        set chunked [my chunked_response $transaction]
                    }
                    if {$chunked} {
                        set body [$transaction get response_body]
                        if {$body ne {}} {
                            my write_chunked_response_body \
                                $transaction $body \
                                [$transaction get response_body_mode]
                            $transaction set response_body {}
                        }
                        my commit_chunked_response $transaction
                        if {![my write_output {} 1]} {
                            error "failed to flush HTTP response"
                        }
                    }
                } message options]} {
                    my abort_application_response $transaction_id $transaction \
                        $message $options
                    return
                }
            }
            complete {
                if {[catch {set chunked [my chunked_response $transaction]} message options]} {
                    my abort_application_response $transaction_id $transaction \
                        $message $options
                    return
                }
                if {$chunked} {
                    if {[catch {
                        my commit_chunked_response $transaction
                        if {[my head_only $transaction]} {
                            if {![my write_output {} 1]} {
                                error "failed to complete HTTP HEAD response"
                            }
                        } elseif {![my write_output \
                                [$protocol_session chunk_terminator] 1]} {
                            error "failed to terminate HTTP chunks"
                        }
                    } message options]} {
                        my abort_application_response $transaction_id $transaction \
                            $message $options
                        return
                    }
                    $transaction set response_state complete
                    set descriptor [my finish_transaction $transaction_id]
                    catch {
                        ::tclwire::accounting update_connection $connection_key \
                            [dict create current_transaction_id {} \
                                         current_command {}]
                    }
                    my log_request $descriptor [dict get $descriptor response_status] \
                                               [dict get $descriptor response_bytes]
                    my close
                    return
                }
                set body [$transaction get response_body]
                set content_encoding [$transaction get response_encoding]
                set status [$transaction get response_status]
                set reason [$transaction get response_reason]
                set headers [$transaction get response_headers]
                set body_mode [$transaction get response_body_mode]
                set head_only [my head_only $transaction]
                set descriptor [my finish_transaction $transaction_id]
                catch {
                    ::tclwire::accounting update_connection $connection_key \
                        [dict create current_transaction_id {} \
                                     current_command {}]
                }
                set response [$protocol_session build_response \
                    $status $reason $body $content_encoding $headers $body_mode \
                    $head_only]
                if {$head_only} {
                    set body_bytes 0
                } elseif {$body_mode eq "binary"} {
                    set body_bytes [string length $body]
                } else {
                    set body_bytes [string length \
                        [encoding convertto $content_encoding $body]]
                }
                my log_request $descriptor $status $body_bytes
                my write_and_close $response
            }
            close_connection {
                set descriptor [my finish_transaction $transaction_id]
                catch {
                    ::tclwire::accounting update_connection $connection_key \
                        [dict create current_transaction_id {} \
                                     current_command {}]
                }
                my log_request $descriptor 0 0
                my close
                return
            }
            error {
                my abort_application_response $transaction_id $transaction \
                    [dict get $event data]
            }
            default {
                my abort_application_response $transaction_id $transaction \
                    "unknown application output event type: [dict get $event type]"
            }
        }
        return
    }

    method send_error {status {context {}} {head_only 0}} {
        set error_response [::tclwire::http::errors response $status $context]
        set response [$protocol_session build_response \
            [dict get $error_response status] \
            [dict get $error_response reason] \
            [dict get $error_response body] \
            [dict get $error_response encoding] \
            [dict get $error_response headers] \
            [dict get $error_response body_mode] \
            $head_only]
        my write_and_close_gracefully $response
    }

    method send_continue_response_if_needed {} {
        if {$continue_response_sent || ![$protocol_session expects_continue]} {
            return
        }
        set continue_response_sent 1
        my write_output [encoding convertto ascii "HTTP/1.1 100 Continue\r\n\r\n"] 1
        return
    }

    method log_request {descriptor status bytes} {
        set method ?
        set path ?
        set remote_host [dict get [my peer] host]
        if {$descriptor ne {}} {
            foreach field {method path remote_host} {
                if {[dict exists $descriptor $field]} {
                    set $field [dict get $descriptor $field]
                }
            }
        }
        set client $log_service_id
        set context [dict create service_id $log_service_id]
        if {$descriptor ne {} && [dict exists $descriptor application_id]} {
            set client [dict get $descriptor application_id]
            dict set context application_id $client
        }
        if {$descriptor ne {} && [dict exists $descriptor headers host]} {
            dict set context host [dict get $descriptor headers host]
        }
        catch {
            set logger [my logger_for_client $client]
            $logger log [join \
                [list "method=[::tclwire::logger::log_value $method]"  \
                      "path=[::tclwire::logger::log_value $path]"      \
                      "status=$status" \
                      "bytes=$bytes"   \
                      "remote=[::tclwire::logger::log_value $remote_host]"] " "] \
                info $context
        }
        return
    }

    method request_info {} {
        return [my active_transaction]
    }

    unexport abort_application_response apply_header_event \
        chunked_response cleanup_request_body commit_chunked_response \
        dispatch_request_descriptor dump_multipart_descriptor \
        enable_chunked_response_for_flush \
        handle_request_descriptor head_only header_name header_value \
        log_application_response_abort log_request request_host response_header_values \
        send_continue_response_if_needed write_chunked_response_body
}

package provide tclwire::http::connection_agent 0.1
