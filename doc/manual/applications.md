# Writing Applications

This chapter will describe how to write TclOO applications for TclWire.

## Scope

- Application class requirements.
- The `handle_request {request}` entry point.
- Request-scoped application objects.
- The abstract `::tclwire::Application` lifecycle base and concrete
  `::tclwire::CApplication` static-file application.
- File-backed applications.
- Package-backed applications.
- Development reloading.
- `docroot`, `libdir`, and `auto_path` behavior.

## Source Material

- `runtime-doc/WORKER_REQUEST_API.md`
- `tcl/application.tcl`
- `tcl/application_dispatcher.tcl`
- `tcl/content_generator_agent.tcl`
