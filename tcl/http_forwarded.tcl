# http_forwarded.tcl --
#
# Trusted reverse-proxy address handling for HTTP requests.
#
# X-Forwarded-For is only evidence about a client address when the immediate
# TCP peer is an explicitly trusted proxy.  This module keeps that policy out
# of HttpRequest: the connection agent knows the peer and resolves the header
# before the application-facing request object is constructed.

package require ip

namespace eval ::tclwire::http::forwarded {
    namespace export compile_trusted_proxies parse_x_forwarded_for \
        address_is_trusted resolve_client

    proc validate_address {address} {
        set address [string trim $address]
        set family [::ip::version $address]
        if {$address eq {} || $family < 0 ||
                [::ip::mask $address] ne {}} {
            error "invalid IP address: $address"
        }
        set address [::ip::normalize $address]
        if {$family == 6} {
            set address [::ip::contract $address]
        }
        return $address
    }

    proc compile_trusted_proxies {specifications} {
        if {[catch {llength $specifications}]} {
            error "trusted proxies must be a list of IP addresses or CIDRs"
        }

        set networks {}
        foreach specification $specifications {
            set specification [string trim $specification]
            if {$specification eq {}} {
                error "trusted proxy entry must not be empty"
            }

            set family [::ip::version $specification]
            if {$family < 0} {
                error "invalid trusted proxy: $specification"
            }
            set prefix [::ip::mask $specification]
            set maximum [expr {$family == 4 ? 32 : 128}]
            if {$prefix eq {}} {
                set prefix $maximum
            } elseif {![string is integer -strict $prefix] ||
                    $prefix < 0 || $prefix > $maximum} {
                error "invalid trusted proxy prefix: $specification"
            }
            if {[catch {
                set network [::ip::prefix $specification]
                set network [::ip::normalize "$network/$prefix"]
            } message]} {
                error "invalid trusted proxy '$specification': $message"
            }
            lappend networks $network
        }
        return $networks
    }

    proc address_is_trusted {address trusted_networks} {
        if {[catch {set address [validate_address $address]}]} {
            return 0
        }
        foreach network $trusted_networks {
            if {[::ip::version $network] != [::ip::version $address]} {
                continue
            }
            set prefix [::ip::mask $network]
            if {[::ip::equal "$address/$prefix" $network]} {
                return 1
            }
        }
        return 0
    }

    proc parse_x_forwarded_for {value} {
        if {[string trim $value] eq {}} {
            return {}
        }

        set addresses {}
        foreach field [split $value ,] {
            set address [string trim $field]
            if {$address eq {}} {
                error "invalid X-Forwarded-For address list"
            }
            if {[catch {set address [validate_address $address]}]} {
                error "invalid X-Forwarded-For address: $address"
            }
            lappend addresses $address
        }
        return $addresses
    }

    proc resolve_client {remote_host header_value trusted_networks} {
        set result [dict create client_host $remote_host forwarded_for {}]
        if {[catch {set addresses [parse_x_forwarded_for $header_value]}]} {
            return $result
        }
        dict set result forwarded_for $addresses

        # Work from the observed socket peer toward the advertised origin.
        # Once an untrusted hop is reached, values to its left are untrusted
        # client input and must not influence the effective client address.
        set client $remote_host
        foreach address [lreverse $addresses] {
            if {![address_is_trusted $client $trusted_networks]} {
                break
            }
            set client $address
        }
        dict set result client_host $client
        return $result
    }

    namespace ensemble create
}

package provide tclwire::http::forwarded 0.1
