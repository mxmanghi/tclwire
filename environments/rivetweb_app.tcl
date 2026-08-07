# rivetweb_app.tcl --
#
#

package require tclwire::application 0.1


if {[info commands ::tclwire::envs::app::Rivetweb] ne {}} {
    if {![info object isa class ::tclwire::envs::app::Rivetweb]} {
        error "application command is not a TclOO class: ::tclwire::envs::app::Rivet"
    }
    ::tclwire::envs::app::Rivetweb destroy
}

oo::class create ::tclwire::envs::app::Rivetweb {
    superclass ::tclwire::CApplication



}
package provide tclwire::rivetweb 0.1
