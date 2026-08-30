# Application Environments

Application environments are optional adapters loaded into a content-generator
worker before the application object is created. They let TclWire host
applications that expect a different runtime surface than the native
`::tclwire::CApplication` API: compatibility commands, command wrappers,
helper namespaces, or a specialized application class.

The implementation contract lives in `tcl/environment.tcl`. Built-in
environment implementations live under `environments/`.

## What Environments Do

An environment may:

- install compatibility commands or command wrappers;
- add namespaces to the application command lookup path;
- declare other environments it requires;
- provide the TclOO application class when an application descriptor omits
  `class`;
- provide the source file for that class when `reload_on_request` needs one;
- expose environment-owned configuration to application and compatibility code.

An environment is not a protocol handler, connection agent, request router, or
thread-pool policy. Those concerns stay in TclWire runtime components. The
environment boundary is the content-generator worker interpreter and the
application surface visible inside that interpreter.

## Declaring Environments

Application tables list environments with the `environment` option:

```toml
[http.hello]
hosts = "localhost"
package = "example::hello"
class = "::example::HelloApp"
docroot = "/tmp/tclwire"
encoding = "utf-8"
environment = "stdchans"
```

Multiple environments are encoded as a Tcl list string:

```toml
environment = "stdchans otherenv"
```

A bare name such as `stdchans` maps to the namespace command
`::tclwire::envs::stdchans` and is loaded with:

```tcl
package require tclwire::stdchans
```

A fully qualified environment name is used as-is. This is useful for tests or
embedded deployments that create an environment namespace directly instead of
loading a `tclwire::<name>` package.

## Runtime Boundary

Environments run inside CGA workers. A CGA worker belongs to one application
pool, so environment installation is worker initialization state, not per
request state.

Worker initialization order is:

1. deserialize the application configuration;
2. store the configuration object on the CGA environment boundary;
3. load and install each configured environment;
4. recursively install environment dependencies first;
5. append environment namespaces to `::tclwire::app`'s namespace path;
6. create the application object.

During request handling, the application object and environment commands can
read request context through TclWire's application APIs, for example
`::tclwire::app::request`, `::tclwire::app::configuration`, and
`::tclwire::app::environment_configuration`.

On worker shutdown, TclWire restores `::tclwire::app`'s previous namespace path
and uninstalls environments in reverse installation order.

## Environment Contract

Every environment namespace must expose an `object` command:

```tcl
::tclwire::envs::<name>::object
```

That command must return a TclOO object. Built-in environments subclass
`::tclwire::ApplicationEnvironment`, which provides lifecycle defaults and
idempotent install state.

The runtime uses these object methods:

| Method | Meaning |
| --- | --- |
| `name` | Stable environment name used for introspection and configuration lookup. |
| `requires` | Tcl list of environments that must be installed before this one. |
| `path_namespaces` | Tcl list of namespaces appended to application lookup paths. |
| `application_class` | Optional TclOO application class supplied by the environment. |
| `application_file` | Optional source file for the environment-supplied application class. |
| `environment_configuration_defaults ?application_descriptor?` | Optional default environment configuration merged under global and application-local environment config. |
| `application_configuration` | The CGA worker's application configuration object. |
| `configuration ?key?` | This environment's effective configuration dictionary, or one value from it. |
| `install` | Install commands, wrappers, namespace state, or hooks. |
| `uninstall` | Undo owned install work. |
| `enabled` | Whether this object currently considers itself installed. |

`::tclwire::ApplicationEnvironment` also defines `do_install` and
`do_uninstall` hooks. Subclasses normally override those hooks instead of
overriding `install` or `uninstall`, because the base class already prevents
repeated installation on the same object.

Its constructor accepts an optional application source path. The base class
normalizes and stores that path, and its `application_file` method returns it.
Environments that supply an application class should pass the matching source
file when creating their environment object; environments that do not supply a
class can continue to construct the object without arguments.

Environment namespaces commonly expose ensemble wrappers for inspection and
manual testing:

```tcl
namespace export object name requires path_namespaces \
                 application_class application_file \
                 application_configuration configuration \
                 enabled install uninstall
namespace ensemble create
```

The runtime contract is the `object` command and the TclOO methods behind it;
the wrappers are a convenience.

## Namespace Paths

`path_namespaces` is how an environment makes unqualified commands visible to
application code sourced or evaluated under `::tclwire::app`.

For example, `stdchans` returns:

```tcl
::tclwire::envs::stdchans
```

After installation, `puts` inside `::tclwire::app` resolves through that
namespace. `stdchans` also wraps global `::puts` and `::flush` so legacy code
using explicitly global standard-channel commands can still write to the
active response body.

If `path_namespaces` returns an empty list, TclWire appends the environment
namespace itself. TclWire also applies installed environment path namespaces to
request-time application object namespaces, so methods on the application
object see the same compatibility command surface.

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
effective environment configuration contains that block. During configuration
normalization, TclWire carries configuration for required environments when it
can load the environment package.

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

## Environment Configuration

Environment configuration lives under `[env.<name>]` tables. TclWire treats
each table as an environment-owned dictionary and reserves only `parent` for
inheritance:

```toml
[env.stdchans]
capture_stderr = true

[env.rivet]
parent = "stdchans"
UploadMaxSize = 10485760
BeforeScript = "rivet/before.tcl"
```

The `parent` table is resolved first, then the child table overlays its own
keys. `parent` is structural metadata and is not passed to the application or
environment as an ordinary option. Cyclic parent inheritance is rejected.

Applications can override or provide environment options with an
application-local table:

```toml
[http.rivet]
hosts = "rivet.example.test"
environment = "rivet"
docroot = "rivet"
encoding = "utf-8"

[http.rivet.env.rivet]
UploadMaxSize = 2097152
AfterScript = "rivet/after.tcl"
```

The application-local dictionary is merged over `[env.rivet]` when the global
table exists. If `[env.rivet]` is absent, the application-local dictionary is
the effective configuration. This merge happens during application
configuration normalization, before the CGA worker is initialized.

Environments may also provide default environment configuration with
`environment_configuration_defaults ?application_descriptor?`. TclWire passes
the effective application descriptor when finalizing application inheritance, so
an environment can derive default options from application fields such as
`docroot`. These defaults have the lowest precedence: global `[env.<name>]`
tables and application-local `[http.<app>.env.<name>]` tables override them.

Applications that list an environment carry the effective environment
configuration into their CGA workers. Environment objects read their owning
application configuration with `my application_configuration` and read their
own effective environment options with `my configuration ?key?`:

```tcl
method do_install {} {
    set application_config [my application_configuration]
    set options [my configuration]
    set docroot [$application_config docroot]
    set limit [my configuration UploadMaxSize]
    return
}
```

Runtime application code can read the same application-scoped repository
through:

```tcl
set repository [::tclwire::app::environment_configuration]
set options    [::tclwire::app::environment_configuration rivet]
set limit      [::tclwire::app::environment_configuration rivet UploadMaxSize]
```

With no arguments, `::tclwire::app::environment_configuration` returns the
complete application-scoped repository. With one argument, it returns that
environment's dictionary. Missing environments return an empty dictionary.
With two arguments, it returns one key and raises an error when the key is
absent from an existing environment dictionary.

Environment code should validate its own option names and value semantics.
TclWire validates only the repository shape and inheritance graph.

## Built-In Environments

`stdchans`
: Redirects `puts stdout` and `flush stdout` to the current TclWire response
  transaction while leaving non-stdout channels delegated to native Tcl channel
  commands. It is useful for CGI-style Tcl code that writes response bodies
  through standard output.

`rivet`
: Installs an Apache Rivet compatibility surface under `::rivet`, declares
  `stdchans` as a dependency, intercepts request `exit`, and supplies the Rivet
  application class from `environments/rivet_app.tcl`.

`rivetweb`
: Installs RivetWeb on top of `rivet` and supplies the RivetWeb application
  class from `environments/rivetweb_app.tcl`. Configure `rivetweb_root` for the
  shared RivetWeb installation, typically in `[env.rivetweb]`. Configure
  `website_root` per application when it differs from the application's
  `docroot`; when omitted, it defaults to that effective `docroot`.

## Creating an Environment

Use a short bare name such as `myenv`. The package name should be
`tclwire::myenv`, and the public namespace should be
`::tclwire::envs::myenv`.

Add `environments/myenv.tcl` or another loadable file included by
`pkgIndex.tcl`:

```tcl
package require tclwire::environment 0.1

namespace eval ::tclwire {}
namespace eval ::tclwire::envs {}

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

namespace eval ::tclwire::envs::myenv {
    variable environment_object [::tclwire::envs::MyenvEnvironment new]

    proc object {} {
        variable environment_object
        return $environment_object
    }

    proc do_install {} {
        proc ::tclwire::envs::myenv::hello {} {
            return "Hello from a TclWire environment"
        }
        return
    }

    proc do_uninstall {} {
        catch {rename ::tclwire::envs::myenv::hello {}}
        return
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
                     enabled install uninstall hello
    namespace ensemble create
}

package provide tclwire::myenv 0.1
```

Register the package so Tcl can load the environment by name. In the
repository-level `pkgIndex.tcl`, the entry would look like this:

```tcl
package ifneeded tclwire::myenv 0.1 [subst {
    package require tclwire::environment 0.1
    source [list [file join $dir environments myenv.tcl]]
}]
```

Once an application declares `environment = "myenv"`, TclWire installs the
environment in each content-generator worker before creating the application
object. Because `path_namespaces` returns `::tclwire::envs::myenv`,
application code can call `hello` directly:

```tcl
oo::class create ::example::HelloApp {
    superclass ::tclwire::CApplication

    method handle_request {request} {
        my content_type text/plain
        my write [hello]
    }
}
```

If you prefer to avoid namespace-path lookup, call the command explicitly as
`::tclwire::envs::myenv::hello`.

## Implementation Checklist

- Keep installed commands inside a dedicated namespace.
- Return namespaces from `path_namespaces` only when unqualified calls are
  intentional.
- Use `requires` only for environment names, not packages or source files.
- Put owned setup and cleanup in `do_install` and `do_uninstall`.
- Preserve and restore any global commands, hooks, channel wrappers, or
  namespace state changed by the environment.
- Rely on the base `install` and `uninstall` methods for idempotency, and make
  lower-level helpers safe when called more than once.
- Override `application_class` only when the environment owns the application
  execution model, and pass its source path to the base constructor when it
  must support file-backed loading.
- Add tests for lifecycle metadata, install/uninstall behavior, dependency
  ordering, namespace-path command resolution, configuration, and request-time
  behavior.
