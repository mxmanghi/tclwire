package ifneeded tclwire::shared_state 0.1 \
    [list source [file join $dir tcl shared_state.tcl]]

package ifneeded tclwire::constants 0.1 \
    [list source [file join $dir tcl constants.tcl]]

package ifneeded tclwire::accounting 1.2 \
    [subst {
        package require tclwire::shared_state 0.1
        source [list [file join $dir tcl threads_shared_db.tcl]]
    }]


package ifneeded tclwire::support 0.1 \
    [list source [file join $dir tcl support.tcl]]

package ifneeded tomlfile 0.1 \
    [list source [file join $dir tcl toml.tcl]]

package ifneeded tclwire::http::protocol 0.1 [subst {
    package require tclwire::constants 0.1
    package require tclwire::http::query 0.1
    source [list [file join $dir tcl http_protocol.tcl]]
}]

package ifneeded tclwire::ftp::protocol 0.1 \
    [list source [file join $dir tcl ftp_protocol.tcl]]

package ifneeded tclwire::proxy::protocol 0.1 [subst {
    package require tclwire::http::protocol 0.1
    source [list [file join $dir tcl proxy_protocol.tcl]]
}]

package ifneeded tclwire::http::errors 0.1 \
    [list source [file join $dir tcl http_error_messages.tcl]]

package ifneeded tclwire::application::io 0.1 [subst {
    package require tclwire::constants 0.1
    source [list [file join $dir tcl application_io.tcl]]
}]

package ifneeded tclwire::stdchans 0.1 [subst {
    package require tclwire::application::io 0.1
    source [list [file join $dir environments stdchans.tcl]]
}]

package ifneeded tclwire::http::application::io 0.1 [subst {
    package require tclwire::application::io 0.1
    source [list [file join $dir tcl http_application_io.tcl]]
}]

package ifneeded tclwire::http::range 0.1 \
    [list source [file join $dir tcl http_range.tcl]]

package ifneeded tclwire::http::redirect 0.1 [subst {
    package require tclwire::application::io 0.1
    source [list [file join $dir tcl http_redirect.tcl]]
}]

package ifneeded tclwire::application::tools 0.1 \
    [list source [file join $dir tcl application_tools.tcl]]

package ifneeded tclwire::application_configuration 0.1 \
    [list source [file join $dir tcl application_configuration.tcl]]

package ifneeded tclwire::http::query 0.1 \
    [list source [file join $dir tcl http_query.tcl]]

package ifneeded tclwire::http::message 0.1 \
    [list source [file join $dir tcl http_message.tcl]]

package ifneeded tclwire::http::multipart 0.1 [subst {
    package require tclwire::http::message 0.1
    source [list [file join $dir tcl http_multipart.tcl]]
}]

package ifneeded tclwire::http::request 0.1 [subst {
    package require tclwire::http::message 0.1
    package require tclwire::http::multipart 0.1
    source [list [file join $dir tcl http_request.tcl]]
}]

package ifneeded tclwire::transaction_descriptor 0.1 \
    [list source [file join $dir tcl transaction_descriptor.tcl]]

package ifneeded tclwire::console::protocol 0.1 [subst {
    package require tclwire::accounting 1.2
    source [list [file join $dir tcl console_protocol.tcl]]
}]

package ifneeded tclwire::console::connection_agent 0.1 [subst {
    package require tclwire::console::protocol 0.1
    source [list [file join $dir tcl console_connection_agent.tcl]]
}]

package ifneeded tclwire::console::reactor 0.1 [subst {
    package require tclwire::console::connection_agent 0.1
    source [list [file join $dir tcl console_reactor.tcl]]
}]

package ifneeded tclwire::application 0.1 [subst {
    package require tclwire::application::io 0.1
    package require tclwire::http::application::io 0.1
    package require tclwire::application::tools 0.1
    package require tclwire::http::range 0.1
    package require tclwire::http::redirect 0.1
    package require tclwire::http::request 0.1
    package require tclwire::logger::client 0.1
    source [list [file join $dir tcl application.tcl]]
}]

package ifneeded tclwire::content_generator_agent 0.1 [subst {
    package require tclwire::application_configuration 0.1
    package require tclwire::application::io 0.1
    package require tclwire::application::tools 0.1
    package require tclwire::http::request 0.1
    package require tclwire::tpba::control 0.1
    source [list [file join $dir tcl content_generator_agent.tcl]]
}]

package ifneeded tclwire::application_dispatcher 0.1 [subst {
    package require tclwire::application_configuration 0.1
    package require tclwire::tpba::control 0.1
    source [list [file join $dir tcl application_dispatcher.tcl]]
}]

package ifneeded tclwire::connection_agent 0.1 [subst {
    package require tclwire::transaction_descriptor 0.1
    source [list [file join $dir tcl connection_agent.tcl]]
}]

package ifneeded tclwire::http::connection_agent 0.1 [subst {
    package require tclwire::connection_agent 0.1
    package require tclwire::http::protocol 0.1
    package require tclwire::http::errors 0.1
    package require tclwire::application_dispatcher 0.1
    package require tclwire::logger::client 0.1
    source [list [file join $dir tcl http_connection_agent.tcl]]
}]

package ifneeded tclwire::ftp::connection_agent 0.1 [subst {
    package require tclwire::connection_agent 0.1
    package require tclwire::ftp::protocol 0.1
    package require tclwire::logger::client 0.1
    source [list [file join $dir tcl ftp_connection_agent.tcl]]
}]

package ifneeded tclwire::proxy::connection_agent 0.1 [subst {
    package require tclwire::connection_agent 0.1
    package require tclwire::proxy::protocol 0.1
    package require tclwire::logger::client 0.1
    source [list [file join $dir tcl proxy_connection_agent.tcl]]
}]

package ifneeded tclwire::transport_reactor 0.1 \
    [list source [file join $dir tcl transport_reactor.tcl]]

package ifneeded tclwire::logger::client 0.1 \
    [list source [file join $dir tcl logger_client.tcl]]

package ifneeded tclwire::logger::control 0.1 [subst {
    package require tclwire::accounting 1.2
    package require tclwire::logger::client 0.1
    source [list [file join $dir tcl logger_control.tcl]]
}]

package ifneeded tclwire::logger 0.1 [subst {
    package require tclwire::logger::control 0.1
    package provide tclwire::logger 0.1
}]

package ifneeded tclwire::threadpool 2.0 [subst {
    package require tclwire::accounting 1.2
    source [list [file join $dir tcl thread_master.tcl]]
}]

package ifneeded tclwire::tpba 0.1 [subst {
    package require tclwire::threadpool 2.0
    source [list [file join $dir tcl tpba.tcl]]
}]

package ifneeded tclwire::tpba::control 0.1 [subst {
    package require tclwire::accounting 1.2
    source [list [file join $dir tcl tpba_control.tcl]]
}]

package ifneeded tclwire::runtime 0.1 [subst {
    package require tclwire::support 0.1
    package require tclwire::accounting 1.2
    package require tclwire::tpba::control 0.1
    package require tclwire::logger::control 0.1
    package require tclwire::application_dispatcher 0.1
    package require tclwire::transport_reactor 0.1
    package require tomlfile 0.1
    source [list [file join $dir tcl tclwire.tcl]]
}]
