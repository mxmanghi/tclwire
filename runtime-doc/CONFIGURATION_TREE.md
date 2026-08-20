# Configuration Tree

`tclwire::configuration_tree` renders configuration dictionaries and
configuration envelopes as structured ASCII trees.

The implementation lives in `tcl/configuration_tree.tcl`.

## Package

```tcl
package require tclwire::configuration_tree 0.1
```

The package installs the `::tclwire::configuration` namespace ensemble.

## Public Surface

### `::tclwire::configuration tree configuration ?sink?`

Renders `configuration` as a tree.

With no `sink`, it returns the complete tree as one newline-separated string:

```tcl
set text [::tclwire::configuration tree $configuration]
puts $text
```

With a `sink`, it emits one rendered line at a time. The sink is a command
form. If any command word contains the literal substring `%s`, that substring
is replaced with the rendered line. Otherwise, the line is appended as the
final argument.

```tcl
::tclwire::configuration tree $configuration \
    [list puts stderr]

set logger [::tclwire::logger::Client new chore]
::tclwire::configuration tree $configuration \
    [list $logger log_error chore %s info]

::tclwire::configuration tree $configuration \
    [list ::tclwire::io out "%s\n"]
```

For arbitrary Tcl logic, use an `apply` command form. This keeps the sink
contract simple while still allowing `format`, filtering, or aggregation:

```tcl
::tclwire::configuration tree $configuration [list apply {{line} {
    ::tclwire::io out [format "%s\n" $line]
}}]
```

The command returns the same tree text whether or not a sink is used.

## Application And Rivet Use

Inside a running application, the current application configuration is exposed
as an object command:

```tcl
::tclwire::app::configuration
```

The tree renderer expects a dictionary, so pass either `snapshot` or
`serialize`, not the object command itself. `snapshot` renders only the
application descriptor values; `serialize` also includes the envelope metadata
and application id.

For a Rivet script such as `/tmp/index.tcl`:

```tcl
package require tclwire::configuration_tree 0.1

puts "<pre>"
puts [::tclwire::configuration tree \
    [[::tclwire::app::configuration] serialize]]
puts "</pre>"
```

The same call can be written with a line sink:

```tcl
puts "<pre>"
::tclwire::configuration tree \
    [[::tclwire::app::configuration] serialize] \
    puts
puts "</pre>"
```

In a Rivet environment, `puts` writes to the HTTP response body because
`stdchans` is installed as a Rivet dependency.

### `::tclwire::configuration emit_lines lines sink`

Emits an existing list of lines to a sink command form using the same `%s`
replacement and `apply` command-form rules as `tree`. It returns the number of
emitted lines.

This is mainly useful when a caller already rendered or filtered lines and
wants to reuse the same sink behavior.

## Rendered Shape

The root label is always `configuration`. Dictionary keys are rendered in
dictionary iteration order. Lists are rendered as zero-based indexed children.

Example input:

```tcl
set configuration [dict create \
    type tclwire.server_configuration \
    version 1 \
    values [dict create \
        host 127.0.0.1 \
        startservers {http ftp}] \
    application_configs [dict create]]
```

Rendered output:

```text
configuration
+-- type = tclwire.server_configuration
+-- version = 1
+-- values
|   +-- host = 127.0.0.1
|   +-- startservers
|       +-- [0] = http
|       +-- [1] = ftp
+-- application_configs
```

## Structure Heuristics

The renderer has to distinguish Tcl lists from Tcl dictionaries. It uses these
rules:

- known dictionary fields are rendered as dictionaries when they are valid
  dictionaries;
- known list fields are rendered as lists;
- other valid dictionaries are rendered as dictionaries;
- non-dictionary multi-item values are rendered as lists;
- empty strings are rendered as `{}`;
- multi-line scalar strings are list-quoted.

Known dictionary fields:

```tcl
application_configs
applications
configure
pool_policy
values
```

Known list fields:

```tcl
application_paths
args
hosts
paths
server_chores
services
startservers
```

These heuristics are intentionally presentation-oriented. They do not validate
configuration semantics; validation belongs to the runtime configuration and
`ApplicationConfiguration` code.

## Chore Use

Server chores can use the helper to print the configuration envelope received
through `::tclwire::ServerChore server_config`:

```tcl
oo::class create MyServerChore {
    superclass ::tclwire::ServerChore

    constructor args {
        next {*}$args
        set logger [::tclwire::logger::Client new chore]
        ::tclwire::configuration tree [my server_config] \
            [list $logger log_error chore %s info]
        $logger destroy
    }
}
```

Because the helper is line-oriented, it works with `puts`, logger methods,
test collectors, and other command forms without needing a special logger API.
