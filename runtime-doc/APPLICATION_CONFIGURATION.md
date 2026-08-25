# Application Configuration Object

`::tclwire::ApplicationConfiguration` is the runtime's immutable,
validated representation of one effective application descriptor.

The implementation lives in `tcl/application_configuration.tcl`.

## Construction

```tcl
set configuration [::tclwire::ApplicationConfiguration new $id $descriptor]
```

`id` is the application identifier. `descriptor` is a dictionary that has
already gone through runtime inheritance and path normalization.

Required descriptor fields:

```tcl
class
hosts
docroot
encoding
application_paths
```

The descriptor must also define either `package` or `file`.

Standard optional fields and defaults:

```tcl
package {}
file {}
chore {}
chore_class {}
libdir {}
environment {}
configure {}
aliases {}
log_level {}
reload_on_request 0
rewrite_hook {}
retain_uploaded_files 0
pool_policy {minimum_workers 0 maximum_workers 20}
```

`environment` is a Tcl list of application environments.

Direct `configure` entries apply to the resolved application class. Nested
class-specific entries remain keyed by TclOO class name.

The constructor validates:

- `file` and `chore` when present;
- `hosts` and `application_paths` list shape;
- `aliases` list entries, each with `url_path` and `local_path`;
- `configure` dictionary shape;
- `pool_policy.minimum_workers` and `pool_policy.maximum_workers`;
- boolean options;
- `reload_on_request` requiring `file`;
- `encoding` against Tcl's known encodings.

## Methods

```tcl
$configuration id
```

Returns the application id.

```tcl
$configuration get $property
```

Returns one value from the effective application-facing surface, or errors for
an unknown property. Descriptor fields take precedence; otherwise the resolved
application class's `configure` block is consulted.

```tcl
$configuration exists $property
$configuration effective_configuration
```

`exists` tests the same effective surface. `effective_configuration` returns a
dictionary view of it. These methods let application code access its own
configured options without first extracting a class block.

```tcl
$configuration snapshot
```

Returns the raw validated descriptor dictionary. It preserves the class-keyed
`configure` structure for serialization and introspection, rather than
flattening class options. Mutating the returned dictionary does not mutate the
configuration object.

```tcl
$configuration configure ?class_name?
$configuration class_configuration $class_name
```

Returns the complete class-keyed `configure` dictionary, or the block for one
TclOO class. Missing class blocks return an empty dictionary.

```tcl
$configuration serialize
::tclwire::ApplicationConfiguration deserialize $serialized
```

`serialize` returns a versioned dictionary envelope:

```tcl
type tclwire.application_configuration
version 1
application_id <id>
values <validated-values-dict>
```

`deserialize` reconstructs a new configuration object from that envelope.
This is the format used when application configuration crosses Tcl thread
boundaries.

Named property methods are also available:

```tcl
class
hosts
docroot
encoding
application_paths
package
file
chore
chore_class
libdir
environment
log_level
reload_on_request
retain_uploaded_files
pool_policy
```

## Chore Use

Application chores receive the serialized configuration envelope through
`::tclwire::ApplicationChore application_config`.

```tcl
set envelope [my application_config]
set configuration [::tclwire::ApplicationConfiguration deserialize $envelope]
set docroot [$configuration docroot]
```

The object should be treated as immutable scheduler-thread state. Application
chores should use `pool_key` for TPBA queries instead of trying to retain a
dispatcher or thread-pool object from another interpreter.

Server chores that inherit from `::tclwire::ServerChore` receive a separate
server configuration envelope through `server_config`. Its
`application_configs` field is a dictionary of these same serialized
application configuration envelopes keyed by application id.
