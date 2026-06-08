#!/usr/bin/env tclsh

package require tcltest 2
namespace import ::tcltest::*

set test_dir [file dirname [file normalize [info script]]]
configure -testdir $test_dir {*}$argv

if {[runAllTests] > 0} {
    exit 1
}
