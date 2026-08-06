# parse_validate_cli.tcl --
#
# Command-line argument parsing and validation for the TclWire runtime.

namespace eval ::tclwire::cli {
    # Write the command-line help text.  This does not build configuration; it
    # documents the CLI layer that later overrides defaults and TOML values.
    proc usage {{channel stdout}} {
        puts $channel "Usage: tclsh tcl/tclwire.tcl ?options?"
        puts $channel ""
        puts $channel "Options:"
        puts $channel "  --help"
        puts $channel "      Show this help message."
        puts $channel "  --config <path>     Default: . (no configuration file)"
        puts $channel "  --bind-address <address>"
        puts $channel "      Local address used by service listeners. Default: 127.0.0.1"
        puts $channel "  --listen-address <address>"
        puts $channel "      Alias for --bind-address."
        puts $channel "  --host <address>"
        puts $channel "      Legacy alias for --bind-address."
        puts $channel "  --startservers <list>"
        puts $channel "      Comma-separated protocols to prepare, or 'all'."
        puts $channel "  --httpport <port>   Default: 8990"
        puts $channel "  --httpsport <port>  Default: 9443"
        puts $channel "  --ftpport <port>    Default: 8991"
        puts $channel "  --ftpsport <port>   Default: 990"
        puts $channel "  --proxyport <port>  Default: 8992"
        puts $channel "  --service <protocol:port>"
        puts $channel "      Add a service. TLS overrides may follow as"
        puts $channel "      ';certfile=<path>;keyfile=<path>;upload_area=<path>'."
        puts $channel "  --docroot <path>"
        puts $channel "  --force-docroot-seeding"
        puts $channel "      Seed docroot even when the directory already exists. Default: off"
        puts $channel "  --upload-area <path>"
        puts $channel "      Store HTTP multipart file parts in this directory."
        puts $channel "  --max-request-bytes <count>"
        puts $channel "      Maximum buffered HTTP request size. Default: 16777216"
        puts $channel "  --max-header-bytes <count>"
        puts $channel "      Maximum buffered HTTP request header size. Default: 65536"
        puts $channel "  --request-memory-threshold <count>"
        puts $channel "      Spool larger HTTP request bodies to disk. Default: 1048576"
        puts $channel "  --dump-multipart-requests"
        puts $channel "      Dump complete multipart HTTP requests to stderr. Default: off"
        puts $channel "  --ftproot <path>"
        puts $channel "  --certfile <path>"
        puts $channel "  --keyfile <path>"
        puts $channel "  --noftp-user-check"
        puts $channel "  --logfile <path>    Access log. Default: /tmp/tclwire.log"
        puts $channel "  --logerr <path>     Error log. Default: /tmp/tclwire-err.log"
        puts $channel "  --log-level <level> Global logging threshold. Default: info"
        puts $channel "  --conn-max-wait <ms>"
        puts $channel "      Maximum accepted-socket wait for a connection worker. Default: 1000"
        puts $channel "  --conn-max-workers <count>"
        puts $channel "      Maximum connection-agent workers per service. Default: 100"
        puts $channel "  --conn-max-per-thread <count>"
        puts $channel "      Maximum connections per connection-agent worker. Default: 5"
        puts $channel "  --unix-socket <path> Console socket. Default: /tmp/tclwire.sock"
        puts $channel "  --enable-chores"
        puts $channel "      Start the chore scheduler. Diagnostics enable it automatically."
        puts $channel "  --chore-interval-ms <ms>"
        puts $channel "      Chore scheduler wakeup interval. Default: 5000"
        puts $channel "  --diagnostics"
        puts $channel "      Periodically log runtime diagnostic snapshots. Default: off"
        puts $channel "  --diagnostics-interval-ms <ms>"
        puts $channel "      Diagnostic snapshot interval. Default: 5000"
        puts $channel "  --diagnostics-watchdog-max-age-ms <ms>"
        puts $channel "      Event-loop heartbeat age before watchdog alert. Default: 2 intervals"
        puts $channel "  --quiet"
        puts $channel "  --debug"
        return
    }

    # Fetch the value following a CLI option and fail with a usage error if the
    # option is dangling.  CLI parsers call this before inserting values into the
    # command-line override dictionary.
    proc value {argv index option} {
        if {$index >= [llength $argv]} {
            ::tclwire::config::usage_error "missing value after $option"
        }
        return [lindex $argv $index]
    }

    # Parse one CLI --service endpoint into a service descriptor.  This creates
    # the same normalized dictionary shape later produced from protocol TOML
    # tables: protocol, port, and optional per-service path overrides.
    proc service_spec {spec} {
        set fields [split $spec \;]
        set endpoint [lindex $fields 0]
        if {![regexp {^([a-z0-9_+-]+):([0-9]+)$} \
                $endpoint -> protocol port]} {
            ::tclwire::config::usage_error "invalid service spec: $spec"
        }
        if {$protocol ni [::tclwire::runtime::implemented_protocols]} {
            ::tclwire::config::usage_error \
                "unsupported protocol in service spec: $protocol"
        }
        set service [dict create protocol $protocol \
                                 port     [::tclwire::config::parse_port_value \
                                               --service $port]]

        foreach field [lrange $fields 1 end] {
            if {![regexp {^(certfile|keyfile)=(.+)$|^(upload_area)=(.*)$} \
                    $field -> tls_name tls_value upload_name upload_value]} {
                ::tclwire::config::usage_error "invalid service option: $field"
            }
            if {$upload_name ne {}} {
                set name $upload_name
                set value $upload_value
            } else {
                set name $tls_name
                set value $tls_value
            }
            dict set service $name \
                [expr {$value eq {} ? {} : [file normalize $value]}]
        }
        return $service
    }

    # Parse --startservers into an ordered list of implemented protocols.  This
    # list is later used to select or synthesize service descriptors.
    proc protocol_list {raw_value} {
        set raw_value [string trim $raw_value]
        if {$raw_value eq {}} {
            ::tclwire::config::usage_error \
                "invalid value for --startservers: empty list"
        }
        if {$raw_value eq "all"} {
            return [::tclwire::runtime::implemented_protocols]
        }

        set protocols {}
        foreach protocol [split $raw_value ,] {
            set protocol [string trim $protocol]
            if {$protocol eq {}} {
                ::tclwire::config::usage_error \
                    "invalid value for --startservers: empty protocol"
            }
            if {$protocol ni [::tclwire::runtime::implemented_protocols]} {
                ::tclwire::config::usage_error \
                    "unsupported server in --startservers: $protocol"
            }
            if {$protocol ni $protocols} {
                lappend protocols $protocol
            }
        }
        return $protocols
    }

    # Validate argv and convert it into structured CLI data.  This pass does not
    # build the runtime configuration tree; it only records the requested config
    # file, scalar overrides, service-selection state, and explicit service
    # descriptors that will be applied after TOML has been loaded.

    proc arguments {argv} {

        set cli [dict create config_file     .              \
                             overrides       [dict create]  \
                             custom_services 0              \
                             services        {}             \
                             startservers_set 0             \
                             port_overrides  [dict create]  \
                             ftproot_set     0]

        for {set i 0} {$i < [llength $argv]} {incr i} {
            set option [lindex $argv $i]
            switch -exact -- $option {
                --help {
                    dict set cli overrides help 1
                }
                --config {
                    dict set cli config_file \
                        [value $argv [incr i] $option]
                }
                --bind-address -
                --listen-address -
                --host {
                    dict set cli overrides host \
                        [value $argv [incr i] $option]
                }
                --startservers {
                    dict set cli overrides startservers \
                        [protocol_list [value $argv [incr i] $option]]
                    dict set cli startservers_set 1
                }
                --httpport  -
                --httpsport -
                --ftpport   -
                --ftpsport  -
                --proxyport {
                    set protocol [string range $option 2 end-4]
                    dict set cli port_overrides $protocol \
                        [::tclwire::config::parse_port_value $option \
                            [value $argv [incr i] $option]]
                }
                --service {
                    dict set cli custom_services 1
                    dict lappend cli services \
                        [service_spec [value $argv [incr i] $option]]
                }
                --docroot {
                    dict set cli overrides docroot \
                        [file normalize [value $argv [incr i] $option]]
                }
                --force-docroot-seeding {
                    dict set cli overrides force_docroot_seeding 1
                }
                --upload-area {
                    set path [value $argv [incr i] $option]
                    dict set cli overrides upload_area \
                        [expr {$path eq {} ? {} : [file normalize $path]}]
                }
                --max-request-bytes {
                    dict set cli overrides max_request_bytes \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 1]
                }
                --max-header-bytes -
                --max_header_bytes {
                    dict set cli overrides max_header_bytes \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 1]
                }
                --request-memory-threshold {
                    dict set cli overrides request_memory_threshold \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 0]
                }
                --dump-multipart-requests {
                    dict set cli overrides dump_multipart_requests 1
                }
                --ftproot {
                    dict set cli overrides ftproot \
                        [file normalize [value $argv [incr i] $option]]
                    dict set cli ftproot_set 1
                }
                --certfile {
                    dict set cli overrides certfile \
                        [file normalize [value $argv [incr i] $option]]
                }
                --keyfile {
                    dict set cli overrides keyfile \
                        [file normalize [value $argv [incr i] $option]]
                }
                --noftp-user-check {
                    dict set cli overrides ftp_user_check 0
                }
                --logfile {
                    dict set cli overrides logfile \
                        [file normalize [value $argv [incr i] $option]]
                }
                --logerr {
                    set logerr [file normalize \
                        [value $argv [incr i] $option]]
                    dict set cli overrides logerr $logerr
                    dict set cli overrides errorlog $logerr
                }
                --log-level {
                    dict set cli overrides log_level \
                        [::tclwire::config::normalize_log_level $option \
                            [value $argv [incr i] $option]]
                }
                --conn-max-wait -
                --conn_max_wait {
                    dict set cli overrides conn_max_wait \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 0]
                }
                --conn-max-workers -
                --conn_max_workers {
                    dict set cli overrides conn_max_workers \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 1]
                }
                --conn-max-per-thread -
                --conn_max_per_thread {
                    dict set cli overrides conn_max_per_thread \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 1]
                }
                --unix-socket {
                    dict set cli overrides unix_socket \
                        [file normalize [value $argv [incr i] $option]]
                }
                --enable-chores -
                --chores {
                    dict set cli overrides chores_enabled 1
                }
                --chore-interval-ms -
                --chore_interval_ms {
                    dict set cli overrides chore_interval_ms \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 100]
                }
                --diagnostics {
                    dict set cli overrides diagnostics_enabled 1
                }
                --diagnostics-interval-ms -
                --diagnostics_interval_ms {
                    dict set cli overrides diagnostics_interval_ms \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 100]
                }
                --diagnostics-watchdog-max-age-ms -
                --diagnostics_watchdog_max_age_ms {
                    dict set cli overrides diagnostics_watchdog_max_age_ms \
                        [::tclwire::config::parse_integer_min $option \
                            [value $argv [incr i] $option] 100]
                }
                --quiet {
                    dict set cli overrides quiet 1
                }
                --debug {
                    dict set cli overrides debug 1
                }
                default {
                    ::tclwire::config::usage_error "unknown argument: $option"
                }
            }
        }
        return $cli
    }

    namespace export usage arguments
    namespace ensemble create
}

namespace eval ::tclwire::runtime {
    proc usage {args} {
        tailcall ::tclwire::cli::usage {*}$args
    }

    proc parse_cli_arguments {argv} {
        tailcall ::tclwire::cli::arguments $argv
    }
}
