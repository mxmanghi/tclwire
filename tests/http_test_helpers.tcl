# http_test_helpers.tcl --
#
# Shared assertions and projections for complete HTTP responses in tests.

package require tclwire::constants 0.1

namespace eval ::tclwire::test {
    proc http_response_separator_index {response} {
        set index [string first \
            $::tclwire::constants::http_header_separator $response]
        if {$index < 0} {
            error "HTTP response is missing the header separator"
        }
        return $index
    }

    proc http_response_headers {response} {
        set index [http_response_separator_index $response]
        return [string range $response 0 $index-1]
    }

    proc http_response_body {response} {
        set index [http_response_separator_index $response]
        set separator_length [string length \
            $::tclwire::constants::http_header_separator]
        return [string range $response $index+$separator_length end]
    }

    proc parse_http_response {response headers_variable body_variable} {
        upvar 1 $headers_variable response_headers
        upvar 1 $body_variable response_body

        set index [http_response_separator_index $response]
        set separator_length [string length \
            $::tclwire::constants::http_header_separator]
        set response_headers [string range $response 0 $index-1]
        set response_body [string range \
            $response $index+$separator_length end]
        return
    }
}
