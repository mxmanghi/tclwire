# service_base.tcl --
#
# Base service class shared by listener-side and worker-side service
# implementations.

namespace eval ::tclwire {}

if {[info commands ::tclwire::service] eq {}} {
    oo::class create ::tclwire::service {
        variable protocol host port quiet listener logfile
        variable thread_master service_config connection_class secure

        constructor args {
            array set options {
                -protocol {}
                -connectionclass {}
                -secure 0
                -host 127.0.0.1
                -port {}
                -quiet 0
                -logfile {}
                -threadmaster {}
                -serviceconfig {}
            }

            foreach {name value} $args {
                if {![info exists options($name)]} {
                    error "unknown option: $name"
                }
                set options($name) $value
            }

            if {$options(-protocol) eq {}} {
                error "missing -protocol"
            }
            if {$options(-port) eq {}} {
                error "missing -port"
            }

            set protocol    $options(-protocol)
            set connection_class $options(-connectionclass)
            set secure      [expr {$options(-secure) ? 1 : 0}]
            set host        $options(-host)
            set port        $options(-port)
            set quiet       $options(-quiet)
            set logfile     $options(-logfile)
            set thread_master $options(-threadmaster)
            set service_config $options(-serviceconfig)
            set listener    {}

            if {$connection_class eq {}} {
                set connection_class $protocol
            }
        }

        destructor {
            my stop
        }

        method protocol {} {
            return $protocol
        }

        method host {} {
            return $host
        }

        method port {} {
            return $port
        }

        method endpoint {} {
            return "[my protocol]://[my host]:[my port]/"
        }

        method connection_class {} {
            return $connection_class
        }

        method secure {} {
            return $secure
        }

        method description {} {
            return "[string toupper [my protocol]] server"
        }

        method listening_message {} {
            return "listening on [my endpoint] ([my description])"
        }

        method log {message} {
            if {!$quiet} {
                puts stderr $message
            }
        }

        method log_request {message} {
            if {$logfile eq {}} {
                return
            }

            if {[catch {
                ::tclwire::write_log_line "[my protocol] $message"
            } log_error]} {
                ::tclwire::msgoutput \
                    "request log failed protocol=$protocol error=$log_error"
            }
        }

        method thread_master {} {
            return $thread_master
        }

        method service_config {} {
            return $service_config
        }

        method set_listener {chan} {
            set listener $chan
            return $listener
        }

        method open_listener_socket {} {
            set accept_callback [list [self] accept]

            if {![my secure]} {
                return [socket -server $accept_callback -myaddr [my host] [my port]]
            }

            if {![::tclwire::https_credentials_available]} {
                my log "TLS credentials not available, skipping [my protocol] listener"
                return {}
            }

            if {[catch {package require tls} tls_error]} {
                my log "TLS package not available, skipping [my protocol] listener: $tls_error"
                return {}
            }

            return [::tls::socket -server $accept_callback \
                -myaddr [my host] \
                -certfile [::tclwire::https_cert_file] \
                -keyfile [::tclwire::https_key_file] \
                -ssl2 0 \
                -ssl3 0 \
                [my port]]
        }

        method stop {} {
            if {$listener ne {}} {
                catch {close $listener}
                set listener {}
            }
        }

        method start {} {
            error "start must be implemented by subclasses"
        }
    }
}
