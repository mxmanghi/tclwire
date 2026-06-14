# transaction_descriptor.tcl --
#
# Connection-thread owner for a transaction descriptor dictionary.

package require TclOO

namespace eval ::tclwire {}

oo::class create ::tclwire::TransactionDescriptor {
    variable descriptor immutable_fields

    constructor {initial_descriptor transaction_id} {
        if {[catch {dict size $initial_descriptor}]} {
            error "transaction descriptor must be a dictionary"
        }

        set descriptor $initial_descriptor
        dict set descriptor transaction_id $transaction_id
        set immutable_fields [dict keys $descriptor]
    }

    method id {} {
        return [dict get $descriptor transaction_id]
    }

    method snapshot {} {
        return $descriptor
    }

    method exists {args} {
        return [dict exists $descriptor {*}$args]
    }

    method get {args} {
        return [dict get $descriptor {*}$args]
    }

    method assert_mutable {field} {
        if {$field in $immutable_fields} {
            error "transaction field is immutable: $field"
        }
        return
    }

    method set {field value} {
        my assert_mutable $field
        dict set descriptor $field $value
        return $value
    }

    method append {field value} {
        my assert_mutable $field
        dict append descriptor $field $value
        return [dict get $descriptor $field]
    }

    method incr {field {increment 1}} {
        my assert_mutable $field
        dict incr descriptor $field $increment
        return [dict get $descriptor $field]
    }

    unexport assert_mutable
}

package provide tclwire::transaction_descriptor 0.1
