# -- thread_model.tcl
#
#

    namespace eval :: {

        package require TclOO
        package require Thread
        source [file join [pwd] threads_shared_db.tcl]
        source [file join [pwd] support.tcl]

        set tclwire_root [::tclwire::repo_root]

        source [file join $tclwire_root http_application.tcl]
        source [file join $tclwire_root logger.tcl]

        namespace eval ::tclwire {}

        oo::class create ::tclwire::CMockUpApplication {
            superclass ::tclwire::CApplication

            variable logger

            constructor {l} {
                set logger $l
            }

            destructor {
                $logger destroy
            }

            method request_handling {args} {
                $logger "args: $args"
            }

            method wait_for_nsecs {n} {
                $logger log "[::thread::id] starts sleeping"
                after [expr 1000*$n]
                $logger log "[::thread::id] awakes"
            }

        }
        #set app [::tclwire::CTestApplication new]

        set logger [::tclwire::logger new]
        variable application [::tclwire::CMockUpApplication new $logger]
        variable accounting ::tclwire::accounting

        $logger log "CMockUpApplication created as $application"

        #::oo::class create ::tclcurl::ApplicationController {
        #    variable application
        #    variable accounting
        #
        #    constructor {app} {
        #        set accounting ::tclwire::accounting
        #        set application $app
        #    }
        #
        #   method exec_method {method args} {
        #        $accounting change_thread_status [::thread::id] running
        #        $application $method {*}$args
        #        $accounting change_thread_status [::thread::id] idle
        #    }
        #}

        proc exec_method {method args} {
            variable accounting
            variable application

            $accounting change_thread_status [::thread::id] running [concat $method {*}$args]

            $application $method {*}$args
            $accounting change_thread_status [::thread::id] idle   
        }

        #variable app_controller [::tclcurl::ApplicationController new $app]
        #$logger log "CApplicationController created as $app_controller"

        set master_thread_id ""
        set ::auto_path [concat [pwd] $::auto_path]

        proc demand_thread_exit {} {
            variable accounting
            $accounting change_thread_status [::thread::id] terminating
            ::thread::release [::thread::id]
        }
        $logger log "thread [::thread::id] created"

        ::thread::wait

        $logger log "thread [::thread::id] terminating"
        $logger destroy

        $accounting remove_thread [::thread::id]
    }

