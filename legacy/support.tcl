# support.tcl --
#
# Shared runtime support for the TclWire application server.

namespace eval ::tclwire {
    variable debug 0
    variable repo_root [file dirname [file normalize [info script]]]
}

namespace eval ::tclwire::paths {
    variable configured_doc_root
    variable configured_ftp_root
    variable configured_https_cert_file
    variable configured_https_key_file
}

proc ::tclwire::repo_root {} {
    variable repo_root
    return $repo_root
}

proc ::tclwire::msgoutput_enabled {args} {
    puts stderr [join $args {}]
}

proc ::tclwire::msgoutput_disabled {args} { }

proc ::tclwire::configure_debug_output {{enabled 0}} {
    variable debug

    set debug [expr {$enabled ? 1 : 0}]
    if {$debug} {
        proc ::tclwire::msgoutput args {
            ::tclwire::msgoutput_enabled {*}$args
        }
    } else {
        proc ::tclwire::msgoutput args {
            ::tclwire::msgoutput_disabled {*}$args
        }
    }
    return $debug
}

proc ::tclwire::env_or_default {name default_value} {
    if {[info exists ::env($name)] && $::env($name) ne {}} {
        return $::env($name)
    }
    return $default_value
}

proc ::tclwire::range_fixture {{ntimes 8192}} {
    return [string repeat "0123456789abcdef" $ntimes]
}

proc ::tclwire::negotiation_payload {} {
    return [string range [::tclwire::range_fixture] 0 255]
}

proc ::tclwire::https_cert_file {} {
    variable ::tclwire::paths::configured_https_cert_file

    if {[info exists configured_https_cert_file] && ($configured_https_cert_file ne {})} {
        return $configured_https_cert_file
    }
    if {[info exists ::env(TCLWIRE_HTTPS_CERT_FILE)] && $::env(TCLWIRE_HTTPS_CERT_FILE) ne {}} {
        return [file normalize $::env(TCLWIRE_HTTPS_CERT_FILE)]
    }

    return [file join [::tclwire::repo_root] certs server.crt]
}

proc ::tclwire::https_key_file {} {
    variable ::tclwire::paths::configured_https_key_file

    if {[info exists configured_https_key_file] && ($configured_https_key_file ne {})} {
        return $configured_https_key_file
    }
    if {[info exists ::env(TCLWIRE_HTTPS_KEY_FILE)] && $::env(TCLWIRE_HTTPS_KEY_FILE) ne {}} {
        return [file normalize $::env(TCLWIRE_HTTPS_KEY_FILE)]
    }

    return [file join [::tclwire::repo_root] certs server.key]
}

proc ::tclwire::https_credentials_available {} {
    return [expr {[file exists [https_cert_file]] && [file exists [https_key_file]]}]
}

proc ::tclwire::set_https_cert_file {path} {
    variable ::tclwire::paths::configured_https_cert_file
    set configured_https_cert_file [file normalize $path]
    return $configured_https_cert_file
}

proc ::tclwire::set_https_key_file {path} {
    variable ::tclwire::paths::configured_https_key_file
    set configured_https_key_file [file normalize $path]
    return $configured_https_key_file
}

proc ::tclwire::set_doc_root {path} {
    variable ::tclwire::paths::configured_doc_root
    set configured_doc_root [file normalize $path]
    return $configured_doc_root
}

proc ::tclwire::doc_root {} {
    variable ::tclwire::paths::configured_doc_root

    if {[info exists configured_doc_root] && ($configured_doc_root ne {})} {
        return $configured_doc_root
    }

    return [file normalize [env_or_default TCLWIRE_DOC_ROOT "/tmp/tclwire"]]
}

proc ::tclwire::set_ftp_root {path} {
    variable ::tclwire::paths::configured_ftp_root
    set configured_ftp_root [file normalize $path]
    return $configured_ftp_root
}

proc ::tclwire::ftp_root {} {
    variable ::tclwire::paths::configured_ftp_root

    if {[info exists configured_ftp_root] && ($configured_ftp_root ne {})} {
        return $configured_ftp_root
    }
    if {[info exists ::env(TCLWIRE_FTP_ROOT)] && $::env(TCLWIRE_FTP_ROOT) ne {}} {
        return [file normalize $::env(TCLWIRE_FTP_ROOT)]
    }

    return [doc_root]
}

::tclwire::configure_debug_output [::tclwire::env_or_default TCLWIRE_DEBUG 0]
