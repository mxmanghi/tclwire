# application_configuration.tcl --
#
# Immutable, validated application configuration value object.

package require TclOO

namespace eval ::tclwire {}
namespace eval ::tclwire::app {}

proc ::tclwire::qualify_application_class {class_name} {
    if {$class_name eq {} || [string match ::* $class_name]} {
        return $class_name
    }
    return ::tclwire::app::$class_name
}

# Decide whether one key in an application `configure` dictionary is meant to
# name a TclOO class rather than an ordinary application option.
#
# TclWire accepts two related configuration shapes:
#
#   configure {
#       message "hello"
#       timeout 30
#   }
#
# and:
#
#   configure {
#       ::example::Application {
#           message "hello"
#       }
#   }
#
# The first shape is convenient in TOML as `[http.site.configure]`; those
# direct keys apply to the already-resolved application class.  The second
# shape is an explicit class-targeted block, used by nested TOML tables such as
# `[http.site.configure."::example::Application"]`.
#
# This predicate recognizes the second shape's *key*.  A key is class-like when
# it is the resolved application class, when it is namespace-qualified, or when
# its final namespace component starts with an uppercase letter.  The uppercase
# rule lets bare class names such as `Hello` be written without `::tclwire::app`
# in TOML.  The caller still verifies that the value is a dictionary before it
# treats the entry as a class block; that second check is what keeps scalar
# direct options from being reinterpreted as class configuration.

proc ::tclwire::application_configure_class_key {key application_class} {
    if {$application_class ne {} &&
        [::tclwire::qualify_application_class $key] eq $application_class} {
        return 1
    }
    if {[string match ::* $key] || [string first :: $key] >= 0} {
        return 1
    }
    set tail [namespace tail $key]
    return [string is upper -strict [string index $tail 0]]
}

proc ::tclwire::qualify_application_configure {configuration {application_class {}}} {
    if {$configuration eq {}} {
        return $configuration
    }
    if {[catch {dict size $configuration}]} {
        return $configuration
    }
    if {$application_class ne {}} {
        set application_class [::tclwire::qualify_application_class $application_class]
    }
    set qualified [dict create]
    set direct [dict create]
    dict for {key value} $configuration {

        # A class-targeted configure entry must satisfy both conditions:
        #
        # 1. The key must look like a class name, as defined by
        #    application_configure_class_key.
        # 2. The value must itself be a dictionary, because a class block is a
        #    set of option/value pairs for that class.
        #
        # The value test is not just validation; it is part of the
        # classification.  It lets direct scalar entries like
        # `message = "hello"` or `child_init_script = "init.tcl"` remain direct
        # application options.  When an application class is known, those direct
        # options are collected in `direct` and attached to that class after the
        # loop.  If the same class also has an explicit block, the explicit
        # block is merged afterward and therefore overrides direct defaults.

        if {[::tclwire::application_configure_class_key $key $application_class] && ![catch {dict size $value}]} {

            set class_name [::tclwire::qualify_application_class $key]
            if {[dict exists $qualified $class_name] && ![catch {dict size [dict get $qualified $class_name]}]} {
                dict set qualified $class_name [dict merge [dict get $qualified $class_name] $value]
            } else {
                dict set qualified $class_name $value
            }

        } elseif {$application_class ne {}} {
            dict set direct $key $value
        } else {
            dict set qualified $key $value
        }
    }

    if {$application_class ne {} && [dict size $direct]} {
        set class_options $direct
        if {[dict exists $qualified $application_class]} {
            set class_options [dict merge $class_options [dict get $qualified $application_class]]
        }
        dict set qualified $application_class $class_options
    }
    return $qualified
}

proc ::tclwire::normalize_application_descriptor_classes {descriptor} {
    set application_class {}
    if {[dict exists $descriptor class]} {
        dict set descriptor class \
            [::tclwire::qualify_application_class [dict get $descriptor class]]
        set application_class [dict get $descriptor class]
    }
    if {[dict exists $descriptor configure]} {
        dict set descriptor configure \
            [::tclwire::qualify_application_configure \
                [dict get $descriptor configure] $application_class]
    }
    return $descriptor
}

oo::class create ::tclwire::ApplicationConfiguration {
    variable application_id values

    constructor {id descriptor} {
        if {[catch {dict size $descriptor}]} {
            error "application configuration must be a dictionary"
        }
        set application_id $id
        set defaults [dict create package     {} \
                                  file        {} \
                                  chore       {} \
                                  chore_class {} \
                                  libdir      {} \
                                  environment {} \
                                  environment_config {} \
                                  configure   {} \
                                  rewrite_hook {} \
                                  log_level   {} \
                                  hostname    {} \
                                  admin       {} \
                                  logfile     {} \
                                  logerr      {} \
                                  server_path {} \
                                  aliases     {} \
                                  reload_on_request 0 \
                                  retain_uploaded_files 0 \
                                  pool_policy [dict create minimum_workers 0 maximum_workers 20]]

        set values [::tclwire::normalize_application_descriptor_classes [dict merge $defaults $descriptor]]

        foreach property {class hosts docroot encoding application_paths} {
            if {![dict exists $descriptor $property]} {
                error "application '$id' is missing $property"
            }
        }
        if {[dict get $values package] eq {} &&
            [dict get $values file] eq {} &&
            [dict get $values environment] eq {}} {
            error "application '$id' must define package, file, or environment"
        }
        if {[dict get $values file] ne {} && ![file isfile [dict get $values file]]} {
            error "application '$id' file does not exist: [dict get $values file]"
        }
        if {[dict get $values chore] ne {} && ![file isfile [dict get $values chore]]} {
            error "application '$id' chore file does not exist: [dict get $values chore]"
        }
        if {[catch {llength [dict get $values hosts]}] ||
            [catch {llength [dict get $values application_paths]}] ||
            [catch {llength [dict get $values aliases]}] ||
            [catch {llength [dict get $values environment]}]} {
            error "application '$id' hosts, application_paths, aliases, and environment must be lists"
        }
        if {[catch {dict size [dict get $values environment_config]}]} {
            error "application '$id' environment_config must be a dictionary"
        }
        dict for {environment_name environment_options} [dict get $values environment_config] {
            if {$environment_name eq {}} {
                error "application '$id' environment_config names must not be empty"
            }
            if {[catch {dict size $environment_options}]} {
                error "application '$id' environment_config.$environment_name must be a dictionary"
            }
        }
        foreach alias [dict get $values aliases] {
            if {[catch {dict size $alias}]} {
                error "application '$id' aliases entries must be dictionaries"
            }
            foreach property {url_path local_path} {
                if {![dict exists $alias $property]} {
                    error "application '$id' alias is missing $property"
                }
            }
            if {![string match /* [dict get $alias url_path]]} {
                error "application '$id' alias URL path must be absolute"
            }
            if {[dict get $alias local_path] eq {}} {
                error "application '$id' alias local path must not be empty"
            }
        }
        if {[catch {
            set pool_policy [dict merge [dict get $defaults pool_policy] \
                                        [dict get $values pool_policy]]
        }]} {
            error "application '$id' pool_policy must be a dictionary"
        }
        if {[catch {dict size [dict get $values configure]}]} {
            error "application '$id' configure must be a dictionary"
        }
        dict for {class_name class_options} [dict get $values configure] {
            if {[catch {dict size $class_options}]} {
                error "application '$id' configure.$class_name must be a dictionary"
            }
        }
        foreach property {minimum_workers maximum_workers} {
            set count [dict get $pool_policy $property]
            if {![string is integer -strict $count] || $count < 0} {
                error "application '$id' pool_policy.$property must be a nonnegative integer"
            }
        }
        if {[dict get $pool_policy maximum_workers] <
            [dict get $pool_policy minimum_workers]} {
            error "application '$id' maximum_workers must not be less than minimum_workers"
        }
        dict set values pool_policy $pool_policy
        foreach property {reload_on_request retain_uploaded_files} {
            if {![string is boolean -strict [dict get $values $property]]} {
                error "application '$id' $property must be a boolean"
            }
            dict set values $property \
                [expr {!![dict get $values $property]}]
        }
        if {[dict get $values reload_on_request] &&
                [dict get $values file] eq {}} {
            error "application '$id' reload_on_request requires file"
        }
        if {[dict get $values encoding] ni [encoding names]} {
            error "application '$id' has an unknown encoding: [dict get $values encoding]"
        }
    }

    method id {} {
        return $application_id
    }

    # The descriptor is the authoritative configuration record.  The resolved
    # application's configure block extends its application-facing surface, but
    # cannot shadow descriptor fields such as encoding or docroot.  Keeping the
    # merge here also lets get/exists serve the same context-aware view without
    # changing snapshot, which remains the raw serializable descriptor.
    method effective_configuration {} {
        set class_name [dict get $values class]
        return [dict merge [my class_configuration $class_name] $values]
    }

    method get {property} {
        set effective_values [my effective_configuration]
        if {![dict exists $effective_values $property]} {
            error "unknown application configuration property: $property"
        }
        return [dict get $effective_values $property]
    }

    method exists {property} {
        return [dict exists [my effective_configuration] $property]
    }

    method snapshot {} {
        return $values
    }

    method configure {{class_name {}}} {
        set configuration [dict get $values configure]
        if {$class_name eq {}} {
            return $configuration
        }
        if {![dict exists $configuration $class_name]} {
            return {}
        }
        return [dict get $configuration $class_name]
    }

    method class_configuration {class_name} {
        return [my configure $class_name]
    }

    method environment_configuration {{environment_name {}} {key {}}} {
        set configuration [dict get $values environment_config]
        if {$environment_name eq {}} {
            return $configuration
        }
        if {![dict exists $configuration $environment_name]} {
            return {}
        }
        set environment_options [dict get $configuration $environment_name]
        if {$key eq {}} {
            return $environment_options
        }
        if {![dict exists $environment_options $key]} {
            error "environment configuration '$environment_name' has no key: $key"
        }
        return [dict get $environment_options $key]
    }

    method serialize {} {
        return [dict create type        tclwire.application_configuration \
                            version     1 \
                            application_id $application_id \
                            values      $values]
    }

    self method deserialize {serialized} {
        if {[catch {dict size $serialized}]} {
            error "serialized application configuration must be a dictionary"
        }
        foreach property {type version application_id values} {
            if {![dict exists $serialized $property]} {
                error "serialized application configuration is missing $property"
            }
        }
        if {[dict get $serialized type] ne
                "tclwire.application_configuration"} {
            error "unsupported application configuration type: [dict get $serialized type]"
        }
        if {[dict get $serialized version] != 1} {
            error "unsupported application configuration version: [dict get $serialized version]"
        }
        return [my new [dict get $serialized application_id] [dict get $serialized values]]
    }

    foreach property {
        class hosts docroot encoding application_paths aliases package file chore chore_class libdir
        environment environment_config log_level logfile logerr reload_on_request
        retain_uploaded_files pool_policy
    } {
        method $property {} [format {my get %s} [list $property]]
    }
}

package provide tclwire::application_configuration 0.1
