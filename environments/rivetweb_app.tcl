# rivetweb_app.tcl --
#
#

package require tclwire::application 0.1

source [file join [file dirname [info script]] rivet_app.tcl]

if {[info commands ::tclwire::envs::app::Rivetweb] ne {}} {
    if {![info object isa class ::tclwire::envs::app::Rivetweb]} {
        error "application command is not a TclOO class: ::tclwire::envs::app::Rivetweb"
    }
    ::tclwire::envs::app::Rivetweb destroy
}

oo::class create ::tclwire::envs::app::Rivetweb {
    superclass ::tclwire::envs::app::Rivet

    method handle_request {request} {
        set request_directory [pwd]
        try {
            ::rivet::apache_log_error info "Rivet request script: [$request target]"
            set request_path [$request path]
            if {$request_path != "index.rvt" && $request_path != "/"} {
                return [next $request]
            }

            # Rivetweb and application-provided scripts may change the
            # process-wide working directory. CGA workers serve more than one
            # request, so restore it even when request setup or rendering
            # fails.
            set script {puts [::rivet::xml "Erice Error Handler" pre]}
            ::try {
                # Rivetweb's legacy site scripts use relative paths. Scope
                # them to this application's document root rather than
                # relying on an initialization-time `cd` in the worker.
                cd [my document_root]
                ::Rivet::initialize_request

                ::rivet::apache_log_error debug "running rivetweb request handler ([pwd])"

                namespace eval ::rivetweb {

                # determining if the 'rewrite_par' argument is in the query
                # list of arguments and in case set the rewrite_links flag
                # and the 'rewrite_code' free form code

                    set rewrite_par [$::rivetweb::url_composer get_rewrite_par]
                    set ::rivetweb::rewrite_links [::rivet::var_qs exists $rewrite_par]
                    if {$::rivetweb::rewrite_links} {
                        set ::rivetweb::rewrite_code [::rivet::var_qs get $rewrite_par]
                    } else {
                        set ::rivetweb::rewrite_code ""
                    }

                # we collect the URL-specified arguments and then we move on determining
                # whether this has to be considered the home page of the web site (mostly
                # to allow template specific determination)
                # The is_homepage determination can be overridden in the site specific
                # before script

                    set argsqs [dict create {*}[::rivet::var_qs all]]
                    set ::rivetweb::is_homepage [::rivet::lempty [::rivetweb::strip_sticky_args $argsqs]]

                # ------ workshop code determination should be taken from ::rivetweb::select_template
                # ------ (::rivetweb::select_template) and moved here -------- #

                # it's not clear whether determing the template key here
                # is useful. It's supposed to be in RWPage but since even
                # classes derived from RWWebService may use template_key
                # to generate HTML fragments we do determine this
                # control variable here
                #

                    set template_key [::rivetweb::select_template]

                # we determine the language for this request
                # (keep in mind we are running within the ::rivetweb namespace)

                    if {[::rivet::var exists lang]} {
                        set language [::rivet::var get lang]
                    } elseif {[::rivet::var exists language]} {
                        set language [::rivet::var get language]
                    } else {
                        set language $::rivetweb::default_lang
                    }

                # site specific 'before' script (if any) runs here.

                # this code is called also from this website's ::rivetweb::select_template
                # Replico questa determinazione perché si deve trovare una soluzione
                # al problema della determinazione ed pre-elaborazione degli argomenti 
                # nella URL. E' più corretto che questa determinazione venga fatta qui
                #
                # still have to figure out what to do, but I guess
                # the error handler below must be triggered

                #; --- site specific 'before' script

                if {$::rivetweb::site_before_script != ""} {
                    ::rivet::apache_log_error debug "running specific 'before' script -> $::rivetweb::site_before_script"
                    source $::rivetweb::site_before_script
                }

                #
                # the central point is exactly here: we determine which page we have to display
                #

                    $::rivetweb::logger log debug "registered handlers: [::rwdatas::UrlHandler::registered_handlers]"
                    $::rivetweb::logger log debug "argsqs: $argsqs, language: $language"

                    set ::rivetweb::current_page [::rwdatas::UrlHandler::select_page $argsqs]

                    $::rivetweb::logger log debug "\[::rwdatas::UrlHandler::select_page $argsqs\] returned $::rivetweb::current_page"

                #
                # The three stage generation of a page
                #
                #    * page content preparation
                #    * HTTP header generation and transmission
                #    * page data transmission
                #

                    set ::rivetweb::page_content $::rivetweb::page_key
                    set ::rivetweb::current_page [$::rivetweb::current_page prepare_content \
                                                 [::rwdatas::UrlHandler::current_handler]  \
                                                 $::rivetweb::language $argsqs]

                # sending headers

                    $::rivetweb::current_page send_headers

                # let's proceed with the post processing and data generation

                    $::rivetweb::current_page send_output $language
                    
                }

            } trap {RIVET ABORTPAGE} {err opts} {
                ::Rivet::finish_request $script $err $opts AbortScript
            } trap {RIVET THREAD_EXIT} {err opts} {
                ::Rivet::finish_request $script $err $opts AbortScript
            } on error {err opts} {
                ::rivet::apache_log_error err "RivetWeb request failed: $::errorInfo"
                ::Rivet::finish_request $script $err $opts
                # Do not turn a failed request into a normal return. The CGA
                # owns the final error response and logs the complete Tcl
                # error context, including stack trace, for this application.
                return -options $opts $err
            } finally {
                ::try {
                    ::Rivet::finish_request $script "" "" AfterEveryScript
                } finally {
                    ::Rivet::cleanup_request
                }
            }
        } finally {
            if {[pwd] ne $request_directory} {
                cd $request_directory
            }
        }
    }
}
package provide tclwire::rivetweb 0.1
