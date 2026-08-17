# Application Environments

Application environments are optional adapters loaded into a content-generator
worker before the application object is created. They let TclWire host
applications that expect a different runtime surface than the native
`::tclwire::CApplication` API.

The implementation contract lives in `tcl/environment.tcl`. Current built-in
environments live under `environments/`.

## Purpose

An environment may:

- install compatibility commands or command wrappers;
- add namespaces to the application command lookup path;
- declare other environments it requires;
- provide the application TclOO class when the application descriptor omits
  `class`;
- provide the source file for that class when `reload_on_request` needs one;
- expose environment-owned configuration to application and compatibility code.

An environment is not a protocol handler, connection agent, request router, or
thread-pool policy. Those concerns stay in TclWire runtime components. The
environment boundary is the content-generator interpreter and the application
surface visible inside that interpreter.

## Runtime Boundary

Environments run inside CGA workers. A CGA worker belongs to one application
pool, so environment installation is worker initialization state, not per
request state.

The initialization order is:

1. deserialize the application configuration;
2. load and install each configured environment;
3. recursively install environment dependencies first;
4. store the application configuration object on the CGA environment boundary;
5. append environment namespaces to `::tclwire::app`'s namespace path;
6. create the application object.

During request handling, the application object and environment commands can
read request context through TclWire's application APIs, for example
`::tclwire::app::request`, `::tclwire::app::configuration`, and
`::tclwire::app::environment_configuration`.

On worker shutdown, TclWire restores `::tclwire::app`'s previous namespace path
and uninstalls environments in reverse installation order.

## Environment Names

Application descriptors list environments with the `environment` option:

```tcl
environment {stdchans}
environment {stdchans otherenv}
```

In TOML this is currently encoded as a Tcl list string:

```toml
environment = "stdchans otherenv"
```

A bare name such as `stdchans` maps to the namespace command
`::tclwire::envs::stdchans` and is loaded with:

```tcl
package require tclwire::stdchans
```

A fully qualified environment name is used as-is. This is useful for tests or
embedded deployments that create an environment namespace directly.

## Contract

Every environment namespace must expose an `object` command:

```tcl
::tclwire::envs::<name>::object
```

That command must return a TclOO object. Built-in environments subclass
`::tclwire::ApplicationEnvironment`, which provides the expected lifecycle
methods and idempotent install state.

The runtime uses these object methods:

| Method | Meaning |
| --- | --- |
| `name` | Stable environment name reported by CGA introspection. |
| `requires` | Tcl list of environments that must be installed before this one. |
| `path_namespaces` | Tcl list of namespaces appended to application lookup paths. |
| `application_class` | Optional TclOO application class supplied by the environment. |
| `application_file` | Optional source file for the environment-supplied application class. |
| `environment_configuration_defaults ?application_descriptor?` | Optional default environment configuration merged under global and application-local environment config. |
| `application_configuration` | The CGA worker's application configuration object. |
| `configuration ?key?` | This environment's effective configuration dictionary, or one value from it. |
| `install` | Install commands, wrappers, namespace state, or hooks. Must be idempotent. |
| `uninstall` | Undo owned install work. Must tolerate partial or repeated cleanup. |
| `enabled` | Whether this object currently considers itself installed. |

`::tclwire::ApplicationEnvironment` also defines `do_install` and
`do_uninstall` hooks. Subclasses normally override those hooks instead of
overriding `install` or `uninstall`, because the base class already guards
idempotency before calling `do_install`.

Environment namespaces usually export ensemble wrappers for the lifecycle
entry points, not for the subclass hooks. The namespace boundary exposes
`install` and `uninstall`; those wrappers call the object's base lifecycle
methods, and the base object methods call `do_install` and `do_uninstall`
after handling idempotency. The CGA environment boundary receives the
application configuration once, before installing any environment in the
worker.

```tcl
namespace export object name requires path_namespaces \
                 application_class application_file \
                 application_configuration configuration \
                 enabled install uninstall
namespace ensemble create
```

The wrappers are useful for tests and manual inspection, but the runtime
contract is the `object` command and the TclOO methods behind it.

## Namespace Path

`path_namespaces` is how an environment makes unqualified commands visible to
application code sourced or evaluated under `::tclwire::app`.

For example, `stdchans` returns:

```tcl
::tclwire::envs::stdchans
```

After installation, `puts` inside `::tclwire::app` resolves to
`::tclwire::envs::stdchans::puts`, while explicitly global `::puts` still
names the global command. `stdchans` also wraps global `::puts` and `::flush`
so legacy code using fully qualified standard-channel commands can still write
to the active response body.

If `path_namespaces` returns an empty list, TclWire appends the environment
namespace itself.

TclWire also applies installed environment path namespaces to request-time
application object namespaces, so methods on the application object see the
same compatibility command surface.

## Dependencies

Use `requires` when one environment depends on another environment's installed
command surface.

Rivet declares:

```tcl
method requires {} {
    return {stdchans}
}
```

That means `stdchans` is installed before `rivet`, even when the application
lists only `rivet`. The installer rejects cyclic dependencies.

Dependencies are runtime dependencies, not configuration inheritance. If a
dependency also needs environment configuration, ensure that the application's
effective `environment_config` contains the required block. During
configuration normalization, TclWire carries configuration for required
environments when it can load the environment package.

## Application Class Selection

Most environments only alter the command surface and leave the application
class alone. An environment may return a class from `application_class` when it
needs to replace TclWire's default application model.

Rivet returns:

```tcl
::tclwire::envs::app::Rivet
```

When an application descriptor omits `class`, the dispatcher asks configured
environments for a class. If more than one environment returns different
classes, configuration fails.

If `reload_on_request` is enabled and the selected class came from an
environment, the dispatcher asks the environment for `application_file`. This
prevents inherited application source files from being reused for a different
environment-selected class.

## Configuration Ownership

Environment configuration lives under `[env.<name>]` tables. TclWire treats
each table as an environment-owned dictionary and reserves only the `parent`
key for inheritance:

```toml
[env.rivet]
UploadMaxSize = 10485760
BeforeScript = "rivet/before.tcl"
```

Applications can override or provide environment options with an application
local table:

```toml
[http.rivet.env.rivet]
UploadMaxSize = 2097152
AfterScript = "rivet/after.tcl"
```

The application-local dictionary is merged over `[env.rivet]` when the global
table exists. If `[env.rivet]` is absent, the application-local dictionary is
the effective configuration. This merge happens during application
configuration normalization, before the CGA worker is initialized.

Applications that list an environment carry the effective environment
configuration into their CGA workers. When a CGA worker is created, TclWire
stores the current `::tclwire::ApplicationConfiguration` object on the CGA
environment boundary before installing environments. Environment objects read
that object with `my application_configuration` and read their own effective
environment options with `my configuration ?key?`:

```tcl
method do_install {} {
    set application_config [my application_configuration]
    set options [my configuration]
    set docroot [$application_config docroot]
    set limit [my configuration UploadMaxSize]
    return
}
```

Runtime application code can also read the application-scoped repository
through:

```tcl
set repository [::tclwire::app::environment_configuration]
set options    [::tclwire::app::environment_configuration rivet]
set limit      [::tclwire::app::environment_configuration rivet UploadMaxSize]
```

With no arguments, the command returns the complete application-scoped
repository. With one argument, it returns that environment's dictionary.
Missing environments return an empty dictionary. With two arguments, it returns
one key and raises an error when the key is absent from an existing
environment dictionary.

Environment code should validate its own option names and value semantics.
TclWire validates only the repository shape and inheritance graph.

## Existing Environments

`stdchans`
: Redirects `puts stdout` and `flush stdout` to the current TclWire response
  transaction while leaving non-stdout channels delegated to native Tcl channel
  commands. It is useful for CGI-style Tcl code that writes response bodies
  through standard output.

`rivet`
: Installs an Apache Rivet compatibility surface under `::rivet`, declares
  `stdchans` as a dependency, intercepts request `exit`, and supplies the
  Rivet application class from `environments/rivet_app.tcl`.

## Step-by-Step: Creating an Environment

### 1. Choose the environment name

Use a short bare name such as `myenv`. The package name should be
`tclwire::myenv`, and the public namespace should be
`::tclwire::envs::myenv`.

### 2. Create the implementation file

Add `environments/myenv.tcl` or another loadable file included by
`pkgIndex.tcl`.

### 3. Require the base package

```tcl
package require tclwire::environment 0.1
```

### 4. Define a TclOO environment class

```tcl
oo::class create ::tclwire::envs::MyenvEnvironment {
    superclass ::tclwire::ApplicationEnvironment

    method name {} {
        return myenv
    }

    method requires {} {
        return {}
    }

    method path_namespaces {} {
        return {::tclwire::envs::myenv}
    }

    method do_install {} {
        ::tclwire::envs::myenv::do_install
        return
    }

    method do_uninstall {} {
        ::tclwire::envs::myenv::do_uninstall
        return
    }
}
```

### 5. Create the public environment namespace and object command

```tcl
namespace eval ::tclwire::envs::myenv {
    variable environment_object \
        [::tclwire::envs::MyenvEnvironment new]

    proc object {} {
        variable environment_object
        return $environment_object
    }

    proc do_install {} {
        return
    }

    proc do_uninstall {} {
        return
    }
}
```

### 6. Add ensemble wrappers for inspection and tests

```tcl
namespace eval ::tclwire::envs::myenv {
    proc name {} {
        tailcall [object] name
    }

    proc requires {} {
        tailcall [object] requires
    }

    proc path_namespaces {} {
        tailcall [object] path_namespaces
    }

    proc enabled {} {
        tailcall [object] enabled
    }

    proc configuration {args} {
        tailcall [object] configuration {*}$args
    }

    proc application_configuration {} {
        tailcall [object] application_configuration
    }

    proc install {} {
        tailcall [object] install
    }

    proc uninstall {} {
        tailcall [object] uninstall
    }

    namespace export object name requires path_namespaces \
                     application_configuration configuration \
                     enabled install uninstall
    namespace ensemble create
}
```

### 7. Install only owned state

If the environment renames global commands, creates namespaces, or changes
hooks, save the previous state and restore it in `do_uninstall`. Do not expose
`do_install` or `do_uninstall` from the namespace boundary; expose `install`
and `uninstall` wrappers that delegate to the object. Use `catch` for cleanup
of state that may already be gone. Keep installation idempotent by relying on
the base `install` method and by making lower-level helpers safe when called
more than once.

### 8. Add compatibility commands

Put public commands in the namespace returned by `path_namespaces`. Those
commands will be visible to application code through Tcl's namespace path.

### 9. Provide an application class only when needed

Override `application_class` and `application_file` only when the environment
owns the application execution model. If ordinary `::tclwire::CApplication`
subclasses can use the environment, leave these methods empty.

### 10. Register the package

Update `pkgIndex.tcl` so `package require tclwire::myenv` loads the
implementation.

### 11. Add tests

Add coverage in `tests/environments.test` for metadata, install/uninstall
idempotency, namespace-path command resolution, dependency behavior, and any
compatibility commands. Add application-level tests when the environment
changes CGA initialization or request behavior.

### 12. Document configuration

If the environment supports `[env.myenv]` options, document each key in the
environment's own docs and mention operationally important keys in
`runtime-doc/CONFIGURATION_OPTIONS.md`.

## Minimal Template

```tcl
package require tclwire::environment 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}

oo::class create ::tclwire::envs::MyenvEnvironment {
    superclass ::tclwire::ApplicationEnvironment

    method name {} {
        return myenv
    }

    method path_namespaces {} {
        return {::tclwire::envs::myenv}
    }

    method do_install {} {
        return
    }

    method do_uninstall {} {
        return
    }
}

namespace eval ::tclwire::envs::myenv {
    variable environment_object [::tclwire::envs::MyenvEnvironment new]

    proc object {} {
        variable environment_object
        return $environment_object
    }

    proc name {} {
        tailcall [object] name
    }

    proc requires {} {
        tailcall [object] requires
    }

    proc path_namespaces {} {
        tailcall [object] path_namespaces
    }

    proc enabled {} {
        tailcall [object] enabled
    }

    proc configuration {args} {
        tailcall [object] configuration {*}$args
    }

    proc application_configuration {} {
        tailcall [object] application_configuration
    }

    proc install {} {
        tailcall [object] install
    }

    proc uninstall {} {
        tailcall [object] uninstall
    }

    namespace export object name requires path_namespaces \
                     application_configuration configuration \
                     enabled install uninstall
    namespace ensemble create
}

package provide tclwire::myenv 0.1
```

## Checklist

- The namespace is `::tclwire::envs::<name>` for bare environment names.
- `object` returns a TclOO object.
- The object subclasses `::tclwire::ApplicationEnvironment` unless there is a
  specific reason not to.
- `requires` lists only environment names, not packages or source files.
- `path_namespaces` returns namespaces that exist after `install`.
- The namespace boundary exposes `install` and `uninstall`.
- Object subclasses put owned setup and cleanup in `do_install` and
  `do_uninstall`.
- `install` and `uninstall` are idempotent.
- `do_install` reads the owning application configuration with
  `my application_configuration` and effective environment options with
  `my configuration ?key?`.
- Global command wrappers preserve and restore previous commands.
- Environment configuration is read through
  `::tclwire::app::environment_configuration`.
- `application_class` is empty unless the environment owns the application
  model.
- `application_file` is set when an environment-supplied class must support
  `reload_on_request`.
- `pkgIndex.tcl` can load the environment through
  `package require tclwire::<name>`.
- Tests cover lifecycle, dependencies, namespace path, configuration, and
  request-time behavior.
