# http_request.tcl --
#
# Application view of a transported HTTP request descriptor.
#
# Class boundary:
#
#   HttpRequest is the application-facing wrapper around the request descriptor
#   produced by the connection thread.  The descriptor has already crossed the
#   thread boundary: HttpProtocolSession parsed HTTP syntax, HttpConnectionAgent
#   added connection/transaction metadata, ApplicationDispatcher selected the
#   application, and the Content Generator Agent created this object in the
#   worker thread.
#
#   HttpRequest does not own the client socket, does not parse wire bytes, does
#   not choose the application, and does not manage response output.  It gives
#   application code a stable, method-oriented view of the descriptor and a few
#   request-scoped conveniences such as CookieJar and multipart helpers.
#
# Most fields are read-only accessors over the request dictionary.  The small
# writable surface, rewrite, path and local_path, is intentionally limited to
# application request processing.  `rewrite` atomically updates URL-derived
# metadata while retaining the original request target for diagnostics.
#
# The comments below call out "pivots": points where the object deliberately
# changes representation, such as descriptor dictionary to method API, Cookie
# header to CookieJar object, raw body descriptor to body/body_path access, and
# multipart request to form/upload projections.

package require TclOO
package require tclwire::http::message 0.1
package require tclwire::http::multipart 0.1
package require tclwire::http::query 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::http::cookie {
    # Cookie helpers implement the narrow syntax accepted by CookieJar.  They
    # are kept outside HttpRequest because applications may use CookieJar for
    # response-side cookie state as well as request cookies parsed from headers.
    proc validate_name {name} {
        if {![regexp {^[A-Za-z0-9!#$%&'*+.^_`|~-]+$} $name]} {
            error "invalid HTTP cookie name"
        }
        return
    }

    proc validate_value {value} {
        if {![regexp {^[\x21-\x7e]*$} $value] ||
                [regexp {[";,\\]} $value]} {
            error "invalid HTTP cookie value"
        }
        return
    }

    proc validate_path {path} {
        if {![string match /* $path] ||
                [regexp {[\x00-\x20\x7f;]} $path]} {
            error "invalid HTTP cookie path"
        }
        return
    }

    proc validate_domain {domain} {
        if {$domain eq {} ||
                [regexp {[\x00-\x20\x7f;]} $domain] ||
                [string first ";" $domain] >= 0} {
            error "invalid HTTP cookie domain"
        }
        return
    }

    proc validate_expiration {expiration} {
        if {[string is entier -strict $expiration]} {
            set seconds $expiration
        } elseif {[catch {clock scan $expiration} seconds]} {
            error "invalid HTTP cookie expiration"
        }
        if {[catch {
            clock format $seconds -gmt 1 -locale C \
                -format {%a, %d %b %Y %H:%M:%S GMT}
        }]} {
            error "invalid HTTP cookie expiration"
        }
        return
    }

    proc parse_header {value} {
        # Convert the request's Cookie header into a flat list of
        # {name value} pairs.  Attributes such as Path or Expires are not part
        # of the Cookie request header; those belong to Set-Cookie responses.
        set cookies {}
        foreach field [split $value ";"] {
            set field [string trim $field]
            if {$field eq {}} {
                continue
            }
            set separator [string first = $field]
            if {$separator < 1} {
                error "invalid HTTP Cookie header"
            }
            set name [string trim [string range $field 0 $separator-1]]
            set cookie_value [string trim [string range $field $separator+1 end]]
            validate_name $name
            validate_value $cookie_value
            lappend cookies [list $name $cookie_value]
        }
        return $cookies
    }
}

oo::class create ::tclwire::CookieJar {
    variable cookies

    constructor {{initial_cookies {}}} {
        # Store cookies in a dictionary keyed by cookie name.  Values and
        # response options are validated through the public set method so the
        # same rules apply to request-initialized and application-created
        # cookies.
        set cookies [dict create]
        foreach cookie $initial_cookies {
            my set {*}$cookie
        }
    }

    method get {name {default_value {}}} {
        ::tclwire::http::cookie::validate_name $name
        if {[dict exists $cookies $name]} {
            return [dict get $cookies $name value]
        }
        return $default_value
    }

    method set {name value args} {
        ::tclwire::http::cookie::validate_name $name
        my validate $value

        set options {}
        if {[llength $args] % 2 != 0} {
            error {wrong # args: should be "CookieJar set name value ?-path uriPath? ?-expires expiration?"}
        }
        foreach {option option_value} $args {
            switch -exact -- $option {
                -path {
                    ::tclwire::http::cookie::validate_path $option_value
                    lappend options $option $option_value
                }
                -expires {
                    ::tclwire::http::cookie::validate_expiration $option_value
                    lappend options $option $option_value
                }
                -domain {
                    ::tclwire::http::cookie::validate_domain $option_value
                    lappend options $option $option_value
                }
                -secure -
                -HttpOnly {
                    if {![string is boolean -strict $option_value]} {
                        error "invalid HTTP cookie option value: $option"
                    }
                    lappend options $option [expr {!!$option_value}]
                }
                default {
                    error "unknown HTTP cookie option: $option"
                }
            }
        }

        dict set cookies $name [dict create value $value options $options]
        return $value
    }

    method validate {value} {
        ::tclwire::http::cookie::validate_value $value
        return $value
    }

    method unset {name} {
        ::tclwire::http::cookie::validate_name $name
        dict unset cookies $name
        return
    }

    method serialize {} {
        # Return a transport-friendly list that can be replayed into another
        # CookieJar.  This keeps CookieJar's internal dictionary layout private.
        set serialized {}
        dict for {name spec} $cookies {
            lappend serialized \
                [list $name [dict get $spec value] {*}[dict get $spec options]]
        }
        return $serialized
    }
}

oo::class create ::tclwire::HttpRequest {
    variable request
    variable cookie_jar
    variable multipart_parts_cache
    variable multipart_parts_cached

    constructor {request_descriptor} {

        # Construction is the descriptor-to-object pivot.  The CGA passes a
        # dictionary copied from the connection thread; this object keeps that
        # dictionary as its request-scoped state and exposes it through methods.
        if {[catch {dict size $request_descriptor}]} {
            error "HTTP request descriptor must be a dictionary"
        }

        # Older descriptors used path as the application URL path.  Keep a
        # url_path alias so newer code can ask for the URL-derived path even if
        # application path mapping later changes path.
        if {[dict exists $request_descriptor path] && ![dict exists $request_descriptor url_path]} {
            dict set request_descriptor url_path [dict get $request_descriptor path]
        }
        set request $request_descriptor
        set cookie_jar {}
        set multipart_parts_cache {}
        set multipart_parts_cached 0
    }

    destructor {
        # CookieJar is created lazily and owned by this request object.
        if {$cookie_jar ne {}} {
            $cookie_jar destroy
        }
    }

    method required {field} {
        # Required descriptor fields are programming/runtime contract fields.
        # Missing ones should fail loudly instead of quietly returning an empty
        # value that would hide a malformed request descriptor.
        if {![dict exists $request $field]} {
            error "HTTP request descriptor is missing $field"
        }
        return [dict get $request $field]
    }

    method snapshot {} { return $request }

    method optional {field default_value} {
        # Optional descriptor fields have compatibility defaults because older
        # protocol paths and tests may omit metadata that is not required for
        # every request.
        if {[dict exists $request $field]} {
            return [dict get $request $field]
        }
        return $default_value
    }

    method method {} {
        return [my required method]
    }

    method target {} {
        return [my required target]
    }

    method original_target {} {
        return [my optional original_target [my target]]
    }

    method rewrite {target} {
        # Request rewrites are deliberately restricted to origin-form targets.
        # They update every URL-derived field together so later routing and
        # compatibility layers cannot observe stale query or path metadata.
        if {![string match "/*" $target] ||
                [regexp {[\x00-\x20\x7f#]} $target]} {
            error "rewritten HTTP target must be an absolute path"
        }

        set query_start [string first ? $target]
        set path $target
        set query {}
        if {$query_start >= 0} {
            set path [string range $target 0 $query_start-1]
            set query [string range $target $query_start+1 end]
        }

        if {![dict exists $request original_target]} {
            dict set request original_target [my target]
        }
        dict set request target $target
        dict set request url_path $path
        dict set request path $path
        dict set request query $query
        dict set request query_dict [::tclwire::http::query decode $query]
        if {[dict exists $request local_path]} {
            dict unset request local_path
        }
        return $target
    }

    method url_path {} {
        return [my required url_path]
    }

    method path {args} {
        # path is the application-working path.  With no argument it returns the
        # current mapped path.  With one argument, application routing or static
        # resource mapping can replace it with another absolute path.
        #
        # Pivot: URL metadata becomes application-local routing metadata.  The
        # original target and url_path remain available separately.
        switch -exact -- [llength $args] {
            0 {
                return [my required path]
            }
            1 {
                set path [lindex $args 0]
            }
            default {
                error {wrong # args: should be "HttpRequest path ?path?"}
            }
        }
        if {![string match "/*" $path]} {
            error "HTTP request path must be absolute"
        }
        dict set request path $path
        return $path
    }

    method local_path {args} {

        # local_path is filesystem mapping metadata, normally set by application
        # path mapping code after it decides which local resource corresponds to
        # the request path.  Empty string unsets the mapping.
        #
        # Class boundary: HttpRequest stores the selected local path, but it
        # does not check document roots or authorize filesystem access.  That is
        # application/resource-handler policy.

        switch -exact -- [llength $args] {
            0 {
                return [my optional local_path {}]
            }
            1 {
                set path [lindex $args 0]
            }
            default {
                error {wrong # args: should be "HttpRequest local_path ?path?"}
            }
        }

        if {[llength $args] == 1} {
            if {$path eq {}} {
                if {[dict exists $request local_path]} {
                    dict unset request local_path
                }
                return {}
            }
            set path [file normalize $path]
            dict set request local_path $path
            return $path
        }
    }

    method query {} {
        return [my optional query {}]
    }

    method query_parameters {} {
        return [my optional query_dict [dict create]]
    }

    method query_dict {} {
        return [my query_parameters]
    }

    method query_parameter {name {default_value {}}} {
        set parameters [my query_parameters]
        if {[dict exists $parameters $name]} {
            return [dict get $parameters $name]
        }
        return $default_value
    }

    method version {} {
        return [my required version]
    }

    method headers {} {
        return [my optional headers [dict create]]
    }

    method header {name {default_value {}}} {
        # Headers are normalized to lowercase by HttpProtocolSession, so lookup
        # lowercases the caller's name instead of preserving HTTP field casing.
        set name [string tolower $name]
        set headers [my headers]
        if {[dict exists $headers $name]} {
            return [dict get $headers $name]
        }
        return $default_value
    }

    method cookie_jar {} {
        # Lazily parse Cookie only if application code asks for cookies.
        #
        # Pivot: the wire-level Cookie header becomes a mutable request-scoped
        # CookieJar object.  Mutating this jar does not change the original
        # headers; it gives application code a convenient cookie collection to
        # inspect or serialize.
        if {$cookie_jar eq {}} {
            set cookie_jar [::tclwire::CookieJar new \
                [::tclwire::http::cookie::parse_header [my header cookie]]]
        }
        return $cookie_jar
    }

    method scheme {} {
        # The connection agent records the externally accepted protocol.  This
        # helper keeps URL construction from needing to know that descriptor
        # field directly.
        switch -exact -- [my optional protocol http] {
            https { return https }
            default { return http }
        }
    }

    method authority {} {
        set authority [string trim [my header host]]
        if {$authority eq {}} {
            error "HTTP request has no Host header"
        }
        return $authority
    }

    method origin {} {
        return "[my scheme]://[my authority]"
    }

    method absolute_url {{path {}}} {
        # Build an absolute URL using the request's scheme and Host header.  A
        # supplied absolute-path reference replaces the current target path;
        # a relative reference is resolved against the current application path.
        if {$path eq {}} {
            set path [my target]
        }
        if {[string match /* $path]} {
            return "[my origin]$path"
        }

        set directory [my path]
        if {![string match */ $directory]} {
            set slash [string last / $directory]
            set directory [string range $directory 0 $slash]
        }
        return "[my origin]$directory$path"
    }

    method content_type {{default_value {}}} {
        return [my header content-type $default_value]
    }

    method content_type_info {} {
        # Content-Type parsing is delegated to the HTTP message helper so media
        # type and parameter rules stay in one package.
        set value [my content_type]
        if {$value eq {}} {
            error "HTTP request has no Content-Type"
        }
        return [::tclwire::http::message parse_content_type $value]
    }

    method media_type {{default_value {}}} {
        set value [my content_type]
        if {$value eq {}} {
            return $default_value
        }
        return [dict get \
            [::tclwire::http::message parse_content_type $value] media_type]
    }

    method content_type_parameter {name {default_value {}}} {
        set value [my content_type]
        if {$value eq {}} {
            return $default_value
        }
        set parameters [dict get \
            [::tclwire::http::message parse_content_type $value] parameters]
        set name [string tolower $name]
        if {[dict exists $parameters $name]} {
            return [dict get $parameters $name]
        }
        return $default_value
    }

    method is_multipart {} {
        set value [my content_type]
        if {$value eq {}} {
            return 0
        }
        return [expr {
            [string match multipart/* \
                [dict get \
                    [::tclwire::http::message parse_content_type $value] \
                    media_type]]
        }]
    }

    method body_media {} {
        return [my optional body_media raw]
    }

    method body_storage {} {
        # Body storage tells application code which accessor is valid:
        # in_memory uses body, spooled_file uses body_path, and multipart
        # decomposed data is reached through multipart/form/upload helpers.
        return [my optional body_storage none]
    }

    method body {} {
        # Only in-memory bodies are returned as bytes.  Spooled bodies should be
        # read from body_path so a large upload is not accidentally copied into
        # worker memory.
        if {[my body_storage] ne "in_memory"} {
            error "HTTP request body is not stored in memory"
        }
        return [my optional body {}]
    }

    method body_path {} {
        # The connection/CGA lifecycle owns cleanup of spooled request files
        # after request processing.  This method only exposes the path while the
        # application is handling the request.
        if {[my body_storage] ne "spooled_file"} {
            error "HTTP request body is not stored in a spooled file"
        }
        return [my required body_path]
    }

    method body_size {} {
        return [my optional body_size 0]
    }

    method multipart_parts {} {
        # Multipart pivot.  A descriptor may already contain decomposed parts
        # from HttpProtocolSession's incremental multipart sink.  Older or
        # in-memory paths may still carry one raw body, so parse on demand and
        # cache the resulting part descriptors for repeated form/file access.
        if {!$multipart_parts_cached} {
            if {[dict exists $request multipart_parts]} {
                set multipart_parts_cache [dict get $request multipart_parts]
            } else {
                set multipart_parts_cache [::tclwire::http::multipart parse \
                    [my content_type] [my body]]
            }
            set multipart_parts_cached 1
        }
        return $multipart_parts_cache
    }

    method optional_multipart_parts {} {
        # Form helpers should behave like empty form data for non-multipart
        # requests instead of forcing every caller to check Content-Type first.
        if {![my is_multipart]} {
            return {}
        }
        return [my multipart_parts]
    }

    method form_fields {} {
        return [::tclwire::http::multipart form_fields \
            [my optional_multipart_parts]]
    }

    method form_values {name} {
        return [::tclwire::http::multipart field_values \
            [my optional_multipart_parts] $name]
    }

    method form_value {name {default_value {}}} {
        set values [my form_values $name]
        if {[llength $values] == 0} {
            return $default_value
        }
        return [lindex $values end]
    }

    method uploaded_files {{name {}}} {
        return [::tclwire::http::multipart files \
            [my optional_multipart_parts] $name]
    }

    method uploaded_file {name} {
        set files [my uploaded_files $name]
        if {[llength $files] == 0} {
            return {}
        }
        return [lindex $files 0]
    }

    method trailers {} {
        # HTTP trailers are available only for chunked requests that supplied
        # them.  They remain separate from headers because they arrive after the
        # body and must not affect routing/framing decisions.
        return [my optional trailers [dict create]]
    }

    method trailer {name {default_value {}}} {
        set name [string tolower $name]
        set trailers [my trailers]
        if {[dict exists $trailers $name]} {
            return [dict get $trailers $name]
        }
        return $default_value
    }

    method connection_id {} {
        return [my optional connection_id {}]
    }

    method transaction_id {} {
        return [my required transaction_id]
    }

    method remote_host {} {
        return [my optional remote_host {}]
    }

    method remote_port {} {
        return [my optional remote_port {}]
    }

    method application_id {} {
        return [my optional application_id {}]
    }

    unexport optional optional_multipart_parts required
}

package provide tclwire::http::request 0.1
