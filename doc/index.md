# TclWire

![TclWire logo](assets/tclwire-logo.png){: .home-logo }

TclWire is a Tcl written application server supporting the HTTP, HTTPS, FTP, FTPS
and proxy protocols and was somehow incidentally created working at the
development of a test suite for the Tclcurl extension: the tclcurl-ng test server
was easily generalized to a largely multi-threaded architecture featuring a simplified
model of virtual hosts, flexible configuration, logging and Tcl application
development layer which supports binary and text HTTP data transmission, multipart
messaging handling, fixed length and chunked transfers, socket channel control

Since the worker threads run within the same process web services developed
for Tclwire can share part of their state by using Tcl Thread shared areas and
interthread communication mechanism.

Tclwire natively ships HTML documents but implements a worker API for developing
Tcl based web applications.

## Rationale

In recent years the need of having feature reach application servers
has partially because static content distribution or custom applications
providing web services run from within virtualization systems or containers in
private networks. The burden of connection filtering, certificate handling is often
left to proxy servers, effectively relieving the application end-point
of much of the tasks bound to the connection control and network infrastructure 

Tclwire is just another tool for the Tcl programmer with a focus on web application
development and inherent multithreading. 

## Advocacy

Tclwire is a application entirely written in Tcl, a pathologically simple yet
robust scripting language, which implements a `apartment thread` model where
each thread runs its own interpreter and communicates by sending messages in the
form of script fragments or using the multhreading typical construct such as
mutexes condition variables and protected shared areas.
The costs of message based communication are at least partially offset by the
robustness of the approach, since scripts live within an interpreter and the basic
tenet of Tcl's threading approach is that no intepreter can be shared across
threads, even though a Tcl thread can run multiple interpreters.

## Tclwire Genesis

The existence of TclWire was made possible by devolving to an AI assistant much
of the development that concerned the generally awkward and impervious knowledge
of protocol details. But the thread functional organization, their roles, features
and structure is mostly the product of the author direct intervention on the assistant
work. The code is as much as possible organized in TclOO classes and their development
followed a step-by-step progression in order to enable the author to conduct a
thorough review of every code installment.

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
