# runtime_config.tcl --
#
# Runtime configuration parsing and normalization.
#
# This module turns command-line options and TOML configuration into one
# normalized runtime configuration dictionary. The main data structures are:
#
#   config: global runtime settings, service descriptors, and application
#           descriptors after path/log-level/boolean/integer normalization.
#   service descriptor: protocol endpoint settings later consumed by
#           TransportReactor construction.
#   application descriptor: effective per-application settings later validated
#           by ::tclwire::ApplicationConfiguration.
#   server chore spec: singleton runtime chore descriptor derived from the
#           [tclwire] stanza.

namespace eval ::tclwire::config {
    # Raise a configuration/CLI usage error with a stable error code.  Parsers
    # use this for bad user input before a runtime configuration tree is usable.
    proc usage_error {message} {
        return -code error -errorcode {TCLWIRE USAGE} $message
    }

    # Validate a TCP port from TOML or CLI input.  The returned integer is stored
    # either in the protocol port map or directly in a service descriptor.
    proc parse_port_value {option value} {
        if {![string is integer -strict $value] || $value < 1 || $value > 65535} {
            usage_error "invalid value for $option: $value"
        }
        return $value
    }

    # Validate an integer lower-bounded option.  Shared by counters, byte limits,
    # worker limits, and timing options before those values enter the config tree.
    proc parse_integer_min {option value minimum} {
        if {![string is integer -strict $value] || $value < $minimum} {
            usage_error "invalid value for $option: $value"
        }
        return $value
    }

    # Convert TOML/CLI boolean spelling into Tcl's 0/1 representation before the
    # value is merged into global, protocol, or application configuration.
    proc parse_boolean {name value} {
        switch -exact -- [string tolower [string trim $value]] {
            true - 1 - yes - on {
                return 1
            }
            false - 0 - no - off {
                return 0
            }
            default {
                usage_error "invalid boolean for $name: $value"
            }
        }
    }

    # Normalize a log-level spelling through the logger package.  The name
    # argument is kept for parity with other validators and future diagnostics.
    proc normalize_log_level {name value} {
        return [::tclwire::logger normalize_level $value]
    }

    # Resolve a path from the TOML file's directory, preserving empty values as
    # explicit "unset" values.  This keeps later runtime code from depending on
    # the process working directory for file-based configuration.
    proc resolve_config_path {config_dir value} {
        if {$value eq {}} {
            return {}
        }
        if {[file pathtype $value] eq "absolute"} {
            return [file normalize $value]
        }
        return [file normalize [file join $config_dir $value]]
    }

    # Parse an Apache-style Alias block into the application descriptor's list of
    # alias dictionaries.  Global, default-application, and per-application alias
    # lists are all converted to this shape before inheritance is applied.
    proc parse_application_aliases {name value} {
        set aliases {}
        set line_number 0
        foreach line [split $value "\n"] {
            incr line_number
            set line [string trim $line]
            if {$line eq {}} {
                continue
            }
            if {[string match "#*" $line]} {
                continue
            }
            if {[catch {llength $line} count]} {
                usage_error "invalid alias rule in $name line $line_number: $line"
            }
            if {$count == 3 && [string equal -nocase [lindex $line 0] Alias]} {
                set line [lrange $line 1 end]
                set count 2
            }
            if {$count != 2} {
                usage_error "invalid alias rule in $name line $line_number: $line"
            }
            lassign $line url_path local_path
            if {![string match /* $url_path]} {
                usage_error "alias URL path in $name line $line_number must be absolute: $url_path"
            }
            if {$local_path eq {}} {
                usage_error "alias local path in $name line $line_number must not be empty"
            }
            lappend aliases [dict create url_path $url_path local_path $local_path]
        }
        return $aliases
    }

    # Merge inherited aliases into an overriding application descriptor.  The
    # override entries are searched first at runtime, so inherited entries are
    # appended only when they are not already present.
    proc merge_application_aliases {base override} {
        if {![dict exists $base aliases] || ![dict exists $override aliases]} {
            return $override
        }
        set aliases [dict get $override aliases]
        foreach alias [dict get $base aliases] {
            if {$alias ni $aliases} {
                lappend aliases $alias
            }
        }
        dict set override aliases $aliases
        return $override
    }

    # Normalize a directory list, dropping empty entries and duplicates while
    # preserving first-seen order.  Used to build deterministic search paths for
    # server chore files.
    proc unique_directories {directories} {
        set result {}
        foreach directory $directories {
            if {$directory eq {}} {
                continue
            }
            set directory [file normalize $directory]
            if {$directory ni $result} {
                lappend result $directory
            }
        }
        return $result
    }

    # Build the server-chore file search path from the launch directory, config
    # directory, optional runtime libdir, and project root.  The resulting paths
    # are stored in chore specs for child runtime setup.
    proc server_chore_paths {config_dir config} {
        set search_directories [list [pwd] $config_dir]
        if {[dict exists $config libdir]} {
            lappend search_directories [dict get $config libdir]
        }
        lappend search_directories [::tclwire::support project_root]
        return [unique_directories $search_directories]
    }

    # Resolve a configured server chore script.  Absolute paths are accepted
    # directly; relative paths are searched through the chore path list and the
    # resolved path is stored in the server chore spec.
    proc resolve_server_chore_file {config_dir config file} {
        if {[file pathtype $file] eq "absolute"} {
            return [file normalize $file]
        }

        set searched {}
        foreach directory [server_chore_paths $config_dir $config] {
            set candidate [file normalize [file join $directory $file]]
            if {$candidate in $searched} {
                continue
            }
            lappend searched $candidate
            if {[file isfile $candidate]} {
                return $candidate
            }
        }
        error "server chore '$file' was not found; searched: [join $searched {, }]"
    }

    # Merge a nested dictionary field from an inherited descriptor and an
    # overriding descriptor.  This preserves per-class configure blocks and pool
    # sub-dictionaries while allowing the overriding descriptor to replace scalar
    # or non-dictionary entries.
    proc merge_nested_dict_field {base override field} {
        if {![dict exists $base $field] || ![dict exists $override $field]} {
            return $override
        }

        set merged [dict get $base $field]
        dict for {key values} [dict get $override $field] {
            if {[dict exists $merged $key] &&
                    ![catch {dict size [dict get $merged $key]}] &&
                    ![catch {dict size $values}]} {
                dict set merged $key [dict merge [dict get $merged $key] $values]
            } else {
                dict set merged $key $values
            }
        }
        dict set override $field $merged
        return $override
    }

    # Protocol tables contain both service-level options and application
    # subtables.  These keys are consumed while building the listener service
    # and must not be interpreted as application ids.
    proc protocol_application_option {field} {
        return [expr {$field in {
            enabled port certfile keyfile libdir log_level upload_area
            max_request_bytes max_header_bytes request_memory_threshold
        }}]
    }

    # Application subtables are identified by descriptor fields.  The loader
    # uses this to reject ambiguous TOML nesting before a malformed table can
    # enter the normal inheritance and dispatch setup path.
    proc application_descriptor_key {field} {
        return [expr {$field in {
            class package hosts encoding log_level reload_on_request
            retain_uploaded_files configure docroot libdir file environment
            hostname admin errorlog server_path
            aliases minimum_workers maximum_workers
        }}]
    }

    # Reconstruct the dotted application id implied by nested TOML tables so
    # the configuration error can point to the quoted table name that should be
    # used for host-based application resolution.
    proc ambiguous_application_id {application_id field value} {
        set parts [list $application_id $field]
        set table $value
        while {![catch {dict size $table}]} {
            set next_field {}
            dict for {candidate nested_value} $table {
                if {[application_descriptor_key $candidate]} {
                    return [join $parts .]
                }
                if {$next_field eq {} && ![catch {dict size $nested_value}]} {
                    set next_field $candidate
                    set table $nested_value
                }
            }
            if {$next_field eq {}} {
                return [join $parts .]
            }
            lappend parts $next_field
        }
        return [join $parts .]
    }

    # Reject nested tables below an application id unless they are known
    # descriptor fields such as configure.  A table like
    # [http.hello.rivetweb.org] means nested TOML tables, not one host-named
    # application; use [http."hello.rivetweb.org"] for that.
    proc reject_nested_application_tables {protocol application_id descriptor} {
        if {[catch {dict size $descriptor}]} {
            return
        }
        dict for {field value} $descriptor {
            if {[application_descriptor_key $field]} {
                continue
            }
            if {![catch {dict size $value}]} {
                set quoted_id [ambiguous_application_id $application_id $field $value]
                error [join [list "application '$protocol.$application_id'" \
                                  "contains nested table '$field';"         \
                                  "quote dotted application ids,"           \
                                  "for example \[$protocol.\"$quoted_id\"\]"] " "]
            }
        }
        return
    }

    # Extract only the HTTP/HTTPS application tables from a protocol
    # configuration.  The result is the application-id -> descriptor dictionary
    # consumed by the normal inheritance, validation, and dispatch setup path.
    proc protocol_application_tables {protocol protocol_config} {
        set applications [dict create]
        dict for {application_id descriptor} $protocol_config {
            if {[protocol_application_option $application_id]} {
                continue
            }
            reject_nested_application_tables \
                $protocol $application_id $descriptor
            dict set applications $application_id $descriptor
        }
        return $applications
    }

    # Convert an environment command/name into the key used by [env.<name>]
    # configuration tables.  Fully-qualified Tcl namespaces are reduced to their
    # tail so configured environment options can be matched to loaded contracts.
    proc environment_config_name {environment} {
        set environment [string trim $environment]
        if {[string match ::* $environment]} {
            return [namespace tail $environment]
        }
        return $environment
    }

    # Return the environment-owned option dictionary for one [env.<name>] table.
    # The structural "parent" key is consumed by repository resolution and is not
    # passed to application or environment code as an ordinary option.
    proc environment_config_options {environment_id descriptor} {
        if {[catch {dict size $descriptor}]} {
            error "environment configuration '$environment_id' must be a table"
        }
        set options $descriptor
        if {[dict exists $options parent]} {
            dict unset options parent
        }
        return $options
    }

    # Resolve one environment configuration table against its optional parent.
    # This is the recursive worker for the repository pass: it detects cycles,
    # resolves parent options first, and lets the child table override them.
    proc resolve_environment_config_one {repository environment_id stack} {
        if {$environment_id in $stack} {
            error "cyclic environment configuration inheritance involving $environment_id"
        }
        if {![dict exists $repository $environment_id]} {
            return {}
        }

        set descriptor [dict get $repository $environment_id]
        set effective {}
        if {[dict exists $descriptor parent]} {
            set parent [environment_config_name [dict get $descriptor parent]]
            if {$parent eq {}} {
                error "environment configuration '$environment_id' parent must not be empty"
            }
            if {![dict exists $repository $parent]} {
                error "environment configuration '$environment_id' parent does not exist: $parent"
            }
            set effective [resolve_environment_config_one \
                $repository $parent [concat $stack [list $environment_id]]]
        }
        return [dict merge $effective \
            [environment_config_options $environment_id $descriptor]]
    }

    # Build the global environment configuration repository from all [env.*]
    # TOML tables.  The result is a map from environment name to effective option
    # dictionary; application descriptors later copy only the entries they need.
    proc resolve_environment_config_repository {toml_config} {
        if {![dict exists $toml_config env]} {
            return {}
        }
        set repository [dict create]
        dict for {environment_id descriptor} [dict get $toml_config env] {
            set environment_id [environment_config_name $environment_id]
            if {$environment_id eq {}} {
                error "environment configuration name must not be empty"
            }
            dict set repository $environment_id $descriptor
        }

        set resolved [dict create]
        dict for {environment_id descriptor} $repository {
            dict set resolved $environment_id \
                [resolve_environment_config_one $repository $environment_id {}]
        }
        return $resolved
    }

    # Expand an application's declared environment list into configuration
    # repository names.  When an environment package is loadable, its contract can
    # provide the canonical name and required environments; otherwise the literal
    # configured name is retained so config can still be carried forward.
    proc application_environment_config_names {environments} {
        set names {}
        set pending $environments
        while {[llength $pending]} {
            set environment [lindex $pending 0]
            set pending [lrange $pending 1 end]

            set name [environment_config_name $environment]
            if {$name eq {}} {
                continue
            }

            if {[catch {
                set command [::tclwire::environment load $environment]
                set environment_object [::tclwire::environment object $command]
                set name [$environment_object name]
                set required_environments [$environment_object requires]
            }]} {
                if {$name ni $names} {
                    lappend names $name
                }
                continue
            }
            if {$name in $names} {
                continue
            }
            lappend names $name
            foreach required $required_environments {
                if {[environment_config_name $required] ni $names} {
                    lappend pending $required
                }
            }
        }
        return $names
    }

    # Select the subset of the resolved environment repository relevant to one
    # application descriptor.  The selected map becomes the descriptor's
    # environment_config field and is serialized into worker-pool configuration.
    proc application_environment_config {application_id descriptor repository} {
        if {![dict exists $descriptor environment]} {
            return {}
        }
        set environments [dict get $descriptor environment]
        if {[catch {llength $environments}]} {
            error "application '$application_id' environment must be a list"
        }

        set configuration [dict create]
        foreach environment_id [application_environment_config_names $environments] {
            if {[dict exists $repository $environment_id]} {
                dict set configuration $environment_id \
                    [dict get $repository $environment_id]
            }
        }
        return $configuration
    }

    # Construct the seed configuration tree.  This contains built-in global
    # defaults, the default service, the protocol port map, an empty environment
    # repository, and the initial default application descriptor.
    proc default_config {} {
        set host                127.0.0.1
        set quiet               0
        set debug               0
        set debug_connection    0
        set help                0
        set force_docroot_seeding 0
        set docroot             [::tclwire::support default_doc_root]
        set upload_area         [file normalize /tmp]
        set max_request_bytes   16777216
        set max_header_bytes    65536
        set request_memory_threshold 1048576
        set ftproot             [::tclwire::support default_ftp_root]
        set certfile            {}
        set keyfile             {}
        set logfile             [file normalize /tmp/tclwire.log]
        set logerr              [file normalize /tmp/tclwire-err.log]
        set hostname            {}
        set admin               {}
        set server_path         {}
        set aliases             {}
        set log_level           info
        set conn_max_wait       1000
        set conn_max_workers    100
        set conn_max_per_thread 5
        set chores_enabled      0
        set chore_interval_ms   5000
        set server_chores       {}
        set diagnostics_enabled 0
        set diagnostics_interval_ms 5000
        set diagnostics_watchdog_max_age_ms 10000
        set unix_socket         [file normalize /tmp/tclwire.sock]
        set ftp_user_check      1
        set ftproot_follows_docroot [expr {$ftproot eq $docroot}]
        set startservers        [::tclwire::runtime::default_protocols]
        set services            [list [dict create  protocol http \
                                                    port [::tclwire::runtime::protocol_default_port http]]]
        set custom_services     0
        set ports               [::tclwire::runtime::protocol_defaults]
        set default_application default
        set default_encoding    utf-8
        set default_hosts       {}
        set environment_configs {}
        set applications        [dict create default [dict create   class      ::tclwire::CApplication \
                                                                    package    tclwire::application    \
                                                                    hosts      {localhost 127.0.0.1}   \
                                                                    docroot    $docroot                \
                                                                    encoding   $default_encoding       \
                                                                    pool_policy [dict create minimum_workers 0 maximum_workers 20]]]

        return [dict create help                $help \
                            config_file         . \
                            force_docroot_seeding $force_docroot_seeding \
                            host                $host \
                            quiet               $quiet \
                            debug               $debug \
                            debug_connection $debug_connection \
                            encoding            $default_encoding \
                            docroot             $docroot \
                            upload_area         $upload_area \
                            max_request_bytes $max_request_bytes \
                            max_header_bytes $max_header_bytes \
                            request_memory_threshold $request_memory_threshold \
                            ftproot             $ftproot \
                            certfile            $certfile \
                            keyfile             $keyfile \
                            ftp_user_check      $ftp_user_check \
                            logfile             $logfile \
                            logerr              $logerr \
                            hostname            $hostname \
                            admin               $admin \
                            errorlog            $logerr \
                            server_path         $server_path \
                            aliases             $aliases \
                            log_level           $log_level \
                            conn_max_wait       $conn_max_wait \
                            conn_max_workers    $conn_max_workers \
                            conn_max_per_thread $conn_max_per_thread \
                            chores_enabled      $chores_enabled \
                            chore_interval_ms   $chore_interval_ms \
                            server_chores       $server_chores \
                            diagnostics_enabled $diagnostics_enabled \
                            diagnostics_interval_ms         $diagnostics_interval_ms \
                            diagnostics_watchdog_max_age_ms $diagnostics_watchdog_max_age_ms \
                            unix_socket         $unix_socket \
                            startservers        $startservers \
                            services            $services \
                            custom_services     $custom_services \
                            ports               $ports \
                            default_hosts       $default_hosts \
                            ftproot_follows_docroot $ftproot_follows_docroot \
                            environment_configs $environment_configs \
                            default_application $default_application \
                            applications        $applications]
    }

    # Read the TOML file into the parser's dictionary representation.  A path of
    # "." is the sentinel for "no configuration file", so the file pass sees an
    # empty TOML tree.
    proc load_config_file {path} {
        if {$path eq "."} {
            return [dict create]
        }
        set path [file normalize $path]
        if {![file isfile $path]} {
            error "configuration file does not exist: $path"
        }
        return [::toml::tomlParse $path]
    }

    # Merge TOML configuration into the default config tree.
    #
    # This pass resolves
    #   + file-relative paths 
    #   + validates scalar values
    #   + builds the global environment configuration repository
    #   + builds protocol service descriptors
    #   + converts HTTP/HTTPS application tables into normalized application descriptors.

    proc apply_file_config {config toml_config} {
        set config_file [dict get $config config_file]
        if {$config_file eq "."} {
            return $config
        }
        set config_dir  [file dirname $config_file]

        # Environment configuration is resolved before applications so each
        # application can later receive only the effective environment options
        # for the environments it declares or requires.
        set environment_configs [resolve_environment_config_repository $toml_config]
        dict set config environment_configs $environment_configs

        # The [tclwire] table updates global runtime defaults.  Values that need
        # type conversion or path resolution are transformed before the merge so
        # later passes see one normalized representation.
        if {[dict exists $toml_config tclwire]} {
            set global [dict get $toml_config tclwire]

            # These fields need no conversion. Filtering before merging keeps
            # unrelated TOML keys out while letting file values replace the
            # built-in defaults in one dictionary operation.

            set config_keys {host encoding default_application hostname admin server_path aliases}

            set config [dict merge $config [dict filter $global key {*}$config_keys]]
            if {[dict exists $global aliases]} {
                dict set config aliases \
                    [parse_application_aliases tclwire.aliases [dict get $global aliases]]
            }
            if {[dict exists $global errorlog]} {
                dict set config errorlog \
                            [resolve_config_path $config_dir [dict get $global errorlog]]
            }
            foreach alias {listen_address bind_address} {
                if {[dict exists $global $alias]} {
                    dict set config host [dict get $global $alias]
                }
            }
            if {[dict exists $global default_hosts]} {
                dict set config default_hosts [dict get $global default_hosts]
                set default_application [dict get $config default_application]

                if {[dict exists $config applications $default_application]} {
                    dict set config applications $default_application hosts \
                                            [dict get $config default_hosts]
                }
            }
            if {[dict exists $global log_level]} {
                dict set config log_level [normalize_log_level tclwire.log_level \
                                          [dict get $global log_level]]
            }
            # dict filter selects the supported source fields; dict map
            # validates and replaces their values. The later merge applies
            # the transformed values without exposing unrelated TOML keys.
            set booleans [dict map {field value} \
                    [dict filter $global key \
                        quiet debug debug_connection ftp_user_check \
                        dump_multipart_requests chores_enabled \
                        diagnostics_enabled] {
                parse_boolean "tclwire.$field" $value
            }]
            set paths [dict map {field value} \
                    [dict filter $global key \
                        docroot ftproot certfile keyfile logfile logerr libdir upload_area \
                        unix_socket] {
                resolve_config_path $config_dir $value
            }]
            set config [dict merge $config $booleans $paths]
            if {![dict exists $global errorlog] && [dict exists $paths logerr]} {
                dict set config errorlog [dict get $paths logerr]
            }
            foreach {field minimum} {
                conn_max_wait 0
                conn_max_workers 1
                conn_max_per_thread 1
                chore_interval_ms 100
                diagnostics_interval_ms 100
                diagnostics_watchdog_max_age_ms 100
                max_request_bytes 1
                max_header_bytes 1
                request_memory_threshold 0
            } {
                if {[dict exists $global $field]} {
                    dict set config $field [parse_integer_min \
                        "tclwire.$field" [dict get $global $field] $minimum]
                }
            }

            if {[dict exists $global chore]} {
                set chore [string trim [dict get $global chore]]
                if {$chore eq {}} {
                    dict set config server_chores {}
                } else {
                    set server_chore [dict create \
                        name server:default \
                        file [resolve_server_chore_file $config_dir $config $chore] \
                        paths [server_chore_paths $config_dir $config]]
                    if {[dict exists $global chore_class]} {
                        dict set server_chore class [dict get $global chore_class]
                    }
                    dict set config server_chores [list $server_chore]
                }
            } elseif {[dict exists $global chore_class]} {
                error "tclwire.chore_class requires tclwire.chore"
            }

            if {[dict exists $global docroot] &&
                    ![dict exists $global ftproot]} {
                dict set config ftproot [dict get $config docroot]
            }
        }

        # Protocol tables first produce listener service descriptors.  If any
        # protocol table is present, the service list becomes explicit and
        # replaces the built-in default service list.
        set startservers {}
        set services {}
        foreach protocol [::tclwire::runtime::implemented_protocols] {
            if {![dict exists $toml_config $protocol]} {
                continue
            }
            set protocol_config [dict get $toml_config $protocol]
            set port [::tclwire::runtime::protocol_default_port $protocol]
            if {[dict exists $protocol_config port]} {
                set port [parse_port_value "$protocol.port" \
                    [dict get $protocol_config port]]
            }
            dict set config ports $protocol $port

            set enabled 1
            if {[dict exists $protocol_config enabled]} {
                set enabled [parse_boolean "$protocol.enabled" \
                    [dict get $protocol_config enabled]]
            }
            if {!$enabled} {
                continue
            }

            set service [dict create protocol $protocol port $port]
            if {$protocol in {http https}} {
                set http_options [dict filter $protocol_config key \
                    upload_area max_request_bytes max_header_bytes \
                    request_memory_threshold]
                dict with http_options {
                    # Dictionary-backed variables from http_options:
                    # upload_area, max_request_bytes, max_header_bytes,
                    # request_memory_threshold.
                    if {[info exists upload_area]} {
                        set resolved_area [resolve_config_path $config_dir $upload_area]
                        dict set service upload_area $resolved_area
                    }

                    if {[info exists max_request_bytes]} {
                        set parsed_max_req \
                            [parse_integer_min "$protocol.max_request_bytes" \
                                                $max_request_bytes 1]
                        dict set service max_request_bytes $parsed_max_req
                    }

                    if {[info exists max_header_bytes]} {
                        set parsed_max_header [parse_integer_min \
                                                    "$protocol.max_header_bytes" \
                                                    $max_header_bytes 1]
                        dict set service max_header_bytes $parsed_max_header
                    }

                    if {[info exists request_memory_threshold]} {
                        set parsed_mem_threshold \
                                [parse_integer_min "$protocol.request_memory_threshold" \
                                                    $request_memory_threshold 0]
                        dict set service request_memory_threshold $parsed_mem_threshold
                    }
                }
            }

            if {[dict exists $protocol_config log_level]} {
                dict set service log_level \
                    [normalize_log_level "$protocol.log_level" \
                        [dict get $protocol_config log_level]]
            }

            # The script form is useful here because inclusion depends on
            # both the key and its value. It still preserves original values;
            # dict map performs the subsequent path transformation.
            set tls_paths [dict filter $protocol_config script {field value} {
                expr {$field in {certfile keyfile} && $value ne {}}
            }]
            set tls_paths [dict map {field value} $tls_paths {
                resolve_config_path $config_dir $value
            }]
            set service [dict merge $service $tls_paths]

            lappend startservers $protocol
            lappend services $service

            if {$protocol in {ftp ftps}} {
                if {[dict exists $protocol_config root]} {
                    dict set config ftproot [resolve_config_path \
                        $config_dir [dict get $protocol_config root]]
                }
                if {[dict exists $protocol_config user_check]} {
                    dict set config ftp_user_check \
                        [parse_boolean "$protocol.user_check" \
                            [dict get $protocol_config user_check]]
                }
            }
        }
        dict set config startservers $startservers
        dict set config services $services
        dict set config custom_services 1

        # HTTP and HTTPS protocol tables also contain application subtables.  At
        # this stage each application table is converted into descriptor shape,
        # with file-relative paths resolved and local scalar values normalized.
        set applications [dict create]
        foreach protocol {http https} {
            if {![dict exists $toml_config $protocol]} {
                continue
            }
            set protocol_config [dict get $toml_config $protocol]
            set protocol_libdir {}
            if {[dict exists $protocol_config libdir]} {
                set protocol_libdir [resolve_config_path \
                    $config_dir [dict get $protocol_config libdir]]
            }
            dict for {application_id descriptor} \
                    [protocol_application_tables $protocol $protocol_config] {
                if {[catch {dict size $descriptor}]} {
                    error "application '$protocol.$application_id' must be a table"
                }

                # Copy only descriptor values that already have the runtime's
                # representation. Paths and worker limits are normalized
                # separately below.
                set application [dict filter $descriptor key \
                    class package hosts encoding log_level reload_on_request \
                    retain_uploaded_files chore chore_class environment \
                    hostname admin server_path aliases]
                if {[dict exists $descriptor aliases]} {
                    dict set application aliases \
                        [parse_application_aliases "$protocol.$application_id.aliases" \
                                                    [dict get $descriptor aliases]]
                }
                if {[dict exists $descriptor configure]} {
                    dict set application configure [dict get $descriptor configure]
                }
                if {[dict exists $application log_level]} {
                    dict set application log_level \
                        [normalize_log_level "$protocol.$application_id.log_level" \
                            [dict get $application log_level]]
                }
                foreach option {reload_on_request retain_uploaded_files} {
                    if {[dict exists $application $option]} {
                        dict set application $option [parse_boolean \
                            "$protocol.$application_id.$option" \
                            [dict get $application $option]]
                    }
                }
                if {![dict exists $application hosts] &&
                        $application_id eq [dict get $config default_application] &&
                        [dict get $config default_hosts] ne {}} {
                    dict set application hosts [dict get $config default_hosts]
                }
                if {![dict exists $application hosts]} {
                    dict set application hosts [list $application_id]
                }
                set application_paths [dict map {field value} \
                        [dict filter $descriptor key docroot libdir errorlog] {
                    resolve_config_path $config_dir $value
                }]
                set application [dict merge $application $application_paths]
                if {![dict exists $application libdir] &&
                        $protocol_libdir ne {}} {
                    dict set application libdir $protocol_libdir
                }
                if {[dict exists $descriptor file]} {
                    set application_file [dict get $descriptor file]
                    if {[file pathtype $application_file] eq "absolute"} {
                        set application_file [file normalize $application_file]
                    }
                    dict set application file $application_file
                }

                set pool_policy [dict filter $descriptor key \
                    minimum_workers maximum_workers]
                if {[dict size $pool_policy]} {
                    dict set application pool_policy $pool_policy
                }
                set application \
                    [::tclwire::normalize_application_descriptor_classes \
                        $application]
                if {[dict exists $applications $application_id] &&
                        [dict get $applications $application_id] ne $application} {
                    error "application '$application_id' differs between HTTP and HTTPS"
                }
                dict set applications $application_id $application
            }
        }
        if {[dict size $applications]} {
            # Application tables override the current default-application
            # template.  Nested descriptor fields need field-aware merging before
            # the final dict merge flattens inherited defaults into each app.
            set merged_applications [dict create]
            set default_application [dict get $config default_application]
            if {[dict exists $config applications $default_application]} {
                dict set merged_applications $default_application \
                    [dict get $config applications $default_application]
            }
            dict for {application_id descriptor} $applications {
                set explicit_class [dict exists $descriptor class]
                set explicit_package [dict exists $descriptor package]
                set explicit_file [dict exists $descriptor file]
                set explicit_chore [dict exists $descriptor chore]
                set explicit_chore_class [dict exists $descriptor chore_class]
                if {[dict exists $merged_applications $application_id]} {
                    set inherited [dict get $merged_applications $application_id]
                    if {[dict exists $inherited pool_policy] &&
                            [dict exists $descriptor pool_policy]} {
                        dict set descriptor pool_policy [dict merge \
                            [dict get $inherited pool_policy] \
                            [dict get $descriptor pool_policy]]
                    }
                    set descriptor [merge_nested_dict_field \
                        $inherited $descriptor configure]
                    set descriptor [merge_application_aliases \
                        $inherited $descriptor]
                    set descriptor [dict merge $inherited $descriptor]
                    if {!$explicit_chore && [dict exists $descriptor chore]} {
                        dict unset descriptor chore
                    }
                    if {!$explicit_chore_class &&
                            [dict exists $descriptor chore_class]} {
                        dict unset descriptor chore_class
                    }
                }
                if {!$explicit_class} {
                    # Environment contracts may supply the application class and
                    # reload file.  Explicit package/file options are preserved;
                    # inherited loader options are removed when the environment
                    # selected the concrete application implementation.
                    set environment_class \
                        [::tclwire::environment application_class \
                            $application_id $descriptor]
                    if {$environment_class ne {}} {
                        dict set descriptor class $environment_class
                        dict set descriptor class_from_environment 1
                        if {!$explicit_package && [dict exists $descriptor package]} {
                            dict unset descriptor package
                        }
                        if {!$explicit_file && [dict exists $descriptor file]} {
                            dict unset descriptor file
                        }
                        if {!$explicit_file &&
                                [dict exists $descriptor reload_on_request] &&
                                [dict get $descriptor reload_on_request]} {
                            set environment_file \
                                [::tclwire::environment application_file \
                                    $application_id $descriptor]
                            if {$environment_file ne {}} {
                                dict set descriptor file $environment_file
                            } else {
                                dict set descriptor reload_on_request 0
                            }
                        }
                    }
                }
                # Attach the per-application slice of the environment repository
                # after inherited defaults and environment contracts are known.
                set environment_config [application_environment_config \
                    $application_id $descriptor $environment_configs]
                if {[dict size $environment_config]} {
                    dict set descriptor environment_config $environment_config
                } elseif {[dict exists $descriptor environment_config]} {
                    dict unset descriptor environment_config
                }
                dict set merged_applications $application_id $descriptor
            }
            dict set config applications $merged_applications
        }
        return $config
    }

    proc apply_cli_config_file {config cli} {
        set config_file [dict get $cli config_file]

        if {$config_file ne "."} {
            dict set config config_file [file normalize $config_file]
        }
        return $config
    }

    # Apply parsed CLI data on top of defaults and TOML.  This stage mutates the
    # configuration tree: scalar overrides are merged, docroot cascades into
    # application descriptors, and service-selection data is materialized.
    proc apply_cli_config {config cli} {
        set config [apply_cli_config_file $config $cli]
        dict with cli {
            # Dictionary-backed variables from cli:
            # overrides, custom_services, services, startservers_set,
            # port_overrides, ftproot_set.
            if {[dict exists $overrides host]} {
                dict set config host [dict get $overrides host]
                if {[dict get $config hostname] eq {}} {
                    dict set config hostname [dict get $config host]
                }
                dict unset overrides host
            }

            if {[dict exists $overrides docroot]} {
                set docroot [dict get $overrides docroot]
                dict set config docroot $docroot
                set applications [dict get $config applications]
                dict for {application_id descriptor} $applications {
                    dict set descriptor docroot $docroot
                    dict set applications $application_id $descriptor
                }
                dict set config applications $applications
                if {!$ftproot_set} {
                    dict set config ftproot $docroot
                }
                dict unset overrides docroot
            }

            set config [dict merge $config $overrides]

            if {$custom_services} {
                dict set config services $services
            } else {
                set services [dict get $config services]
                if {$startservers_set} {
                    set selected {}
                    foreach protocol [dict get $config startservers] {
                        set found 0
                        foreach service $services {
                            if {[dict get $service protocol] eq $protocol} {
                                lappend selected $service
                                set found 1
                            }
                        }
                        if {!$found} {
                            lappend selected [dict create protocol $protocol \
                                port [dict get [dict get $config ports] $protocol]]
                        }
                    }
                    set services $selected
                }
                set updated {}
                foreach service $services {
                    set protocol [dict get $service protocol]
                    if {[dict exists $port_overrides $protocol]} {
                        dict set service port [dict get $port_overrides $protocol]
                    }
                    lappend updated $service
                }
                dict set config services $updated
            }
        }
        return $config
    }

    # Complete the normalized configuration tree after defaults, TOML, and CLI
    # have all been applied.  This expands application inheritance from global
    # and default-application values, fills service defaults, normalizes service
    # descriptors, and removes construction-only helper fields.
    proc finalize_config {config} {
        set applications [dict get $config applications]
        set default_application [dict get $config default_application]
        if {![dict exists $applications $default_application]} {
            error "default application is not registered: $default_application"
        }
        set default_descriptor \
            [::tclwire::normalize_application_descriptor_classes \
                [dict get $applications $default_application]]

        dict for {application_id descriptor} $applications {
            set application_hosts {}
            if {[dict exists $descriptor hosts]} {
                set application_hosts [dict get $descriptor hosts]
            }
            set class_from_environment [expr {
                [dict exists $descriptor class_from_environment] &&
                [dict get $descriptor class_from_environment]
            }]
            set explicit_package [dict exists $descriptor package]
            set explicit_file [dict exists $descriptor file]
            set descriptor \
                [::tclwire::normalize_application_descriptor_classes \
                    $descriptor]
            set explicit_chore [dict exists $descriptor chore]
            set explicit_chore_class [dict exists $descriptor chore_class]

            # The named default application is the template for every
            # host-specific application. Global runtime values remain the
            # fallback for fields omitted by the default itself.
            set global_defaults [dict create \
                docroot [dict get $config docroot] \
                encoding [dict get $config encoding] \
                hostname [expr {[dict get $config hostname] ne {} ? \
                    [dict get $config hostname] : [dict get $config host]}] \
                admin [dict get $config admin] \
                errorlog [dict get $config errorlog] \
                server_path [dict get $config server_path] \
                aliases [dict get $config aliases]]
            set inherited [merge_application_aliases \
                $global_defaults $default_descriptor]
            set inherited [dict merge $global_defaults $inherited]
            if {$application_id eq $default_application} {
                set descriptor $inherited
            } else {
                if {[dict exists $inherited pool_policy] &&
                        [dict exists $descriptor pool_policy]} {
                    dict set descriptor pool_policy [dict merge \
                        [dict get $inherited pool_policy] \
                        [dict get $descriptor pool_policy]]
                }
                set descriptor [merge_nested_dict_field \
                    $inherited $descriptor configure]
                set descriptor [merge_application_aliases \
                    $inherited $descriptor]
                set descriptor [dict merge $inherited $descriptor]
                if {!$explicit_chore && [dict exists $descriptor chore]} {
                    dict unset descriptor chore
                }
                if {!$explicit_chore_class &&
                        [dict exists $descriptor chore_class]} {
                    dict unset descriptor chore_class
                }
                if {$application_hosts ne {}} {
                    dict set descriptor hosts $application_hosts
                }
            }
            if {$class_from_environment} {
                if {!$explicit_package && [dict exists $descriptor package]} {
                    dict unset descriptor package
                }
                if {!$explicit_file && [dict exists $descriptor file]} {
                    dict unset descriptor file
                }
                if {!$explicit_file &&
                        [dict exists $descriptor reload_on_request] &&
                        [dict get $descriptor reload_on_request]} {
                    set environment_file \
                        [::tclwire::environment application_file \
                            $application_id $descriptor]
                    if {$environment_file ne {}} {
                        dict set descriptor file $environment_file
                    } else {
                        dict set descriptor reload_on_request 0
                    }
                }
                dict unset descriptor class_from_environment
            }
            if {[dict exists $config libdir] &&
                    ![dict exists $descriptor libdir]} {
                dict set descriptor libdir [dict get $config libdir]
            }
            dict set applications $application_id $descriptor
        }
        dict set config applications $applications

        # Service descriptors inherit HTTP body limits and upload area from the
        # global config when the service did not specify an override.  TLS
        # defaults are applied by normalize_service.
        set services [dict get $config services]
        set service_defaults [dict filter $config key \
            upload_area max_request_bytes max_header_bytes \
            request_memory_threshold certfile keyfile]
        set normalized_services {}
        dict with service_defaults {
            # Dictionary-backed variables from service_defaults:
            # upload_area, max_request_bytes, max_header_bytes,
            # request_memory_threshold, certfile, keyfile.
            foreach service $services {
                set protocol [dict get $service protocol]
                if {$protocol in {http https}} {
                    foreach field {
                        upload_area max_request_bytes max_header_bytes
                        request_memory_threshold
                    } {
                        if {![dict exists $service $field]} {
                            dict set service $field [set $field]
                        }
                    }
                }
                lappend normalized_services [::tclwire::runtime::normalize_service \
                    $service $certfile $keyfile]
            }
        }
        dict set config services $normalized_services
        dict set config startservers [lmap service $normalized_services {
            dict get $service protocol
        }]
        foreach internal {custom_services ports default_hosts ftproot_follows_docroot} {
            if {[dict exists $config $internal]} {
                dict unset config $internal
            }
        }
        return $config
    }

    # Public preparation entry point used by the runtime.  It builds a complete
    # runtime configuration dictionary from argv, then applies debug/console side
    # effects needed before services and agents start.

    proc prepare_config {argv} {

        # The CLI parser validates argv before the TOML file is loaded and
        # returns a dictionary with these construction inputs:
        #
        #   config_file:      TOML file path, or "." when no file was selected.
        #   overrides:        normalized global option values set by CLI flags.
        #   custom_services:  true when --service supplied the service list.
        #   services:         service descriptors built from --service options.
        #   startservers_set: true when --startservers selected protocols.
        #   port_overrides:   protocol -> port map from --httpport, --ftpport,
        #                     and related legacy port options.
        #   ftproot_set:      true when --ftproot explicitly set the FTP root.

        set cli [::tclwire::cli::arguments $argv]
        set config [apply_cli_config_file [default_config] $cli]
        set config_file [dict get $config config_file]

        set configuration [load_config_file $config_file]
        set config [apply_file_config $config $configuration]
        set config [apply_cli_config $config $cli]
        set config [finalize_config $config]

        ::tclwire::support configure_debug [dict get $config debug]
        ::tclwire::accounting configure_debug_connection [dict get $config debug_connection]
        ::tclwire::console configure $config
        return $config
    }
}

namespace eval ::tclwire::runtime {
    proc prepare_config {argv} {
        tailcall ::tclwire::config::prepare_config $argv
    }
}
