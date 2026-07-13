# TclWire

![TclWire logo](assets/tclwire-logo.png){: .home-logo }

TclWire is a Tcl-based application server supporting the HTTP, HTTPS, FTP, FTPS
and proxy protocols and was somehow incidentally created working at the
development of a test suite for the Tclcurl extension. The effort of having an
application server challenging the Tclcurl client tests was generalized to a
largely TclOO based multi-threaded architecture featuring virtual hosts, simple
yet flexible configuration, logging and control through console script that
communicates with the server through a unix-socket.

Since the worker threads run within the same process web services developed
for Tclwire can share part of their state by using Tcl Thread shared areas and
interthread communication mechanism.

Tclwire natively ships HTML documents but implements a worker API for developing
Tcl based web applications.

## Rationale

In recent years the need of having complex and feature reach application servers
has partially waned when it comes to the distribution of documentation or the
deployment of HTTP based applications for web services. Furthermore in many
cases such services live within virtualization systems or containers running
within corporate networks that expose selected ports mapping specific internal
services. In these cases much of the network security or encrypted protocols
certificate exchange and validation is a task devolved to the gateway and proxy
services, thus effectively relieving the endpoint services from the complexity
of replicating their management. Tclwire is just another tool for the Tcl
programmer with a focus on web service development and inherent multithreading.
Unlike other application servers Tclwire

## Advocacy

Tclwire is a application entirely written in Tcl, a pathologically simple yet
robust scripting language, which implements a `apartment thread` model where
each thread runs its own interpreter and communicates by sending messages in the
form of script fragments or using the ::tsv package to share a protected common
area for internal resource accounting. The costs of message based communication
are at least partially offset by the robustness of the approach, since scripts
live within an interpreter and the basic tenet of Tcl's threading approach is that
no intepreter can be shared across threads, even though a Tcl thread can run
multiple interpreters.

## Tclwire Genesis

The existence of TclWire was made possible by devolving to an AI assistant much
of the development that concerned the generally awkward and impervious knowledge
of protocol details, reserving to the human developer the task of outlining the
overall server architecture and planning the development in steps that made
possible to rewiew the code generated in each installment.

## Current Entry Points

- [Manual Overview](manual/index.md)
- [Getting Started](manual/getting-started.md)
- [Configuration](manual/configuration.md)
- [Writing Applications](manual/applications.md)
- [Architecture](manual/architecture.md)

## Runtime Documentation Source

The older reference documents used to seed TclWire's default document root live
under `runtime-doc/` in the repository root. They are kept separate from the
MkDocs source tree while the manual is drafted.
