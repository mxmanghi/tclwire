# TclWire

![TclWire logo](assets/tclwire-logo.png){: .home-logo }

TclWire is a Tcl-based application server supporting the HTTP, HTTPS, FTP, FTPS and proxy
protocols and was somehow incidentally created working at the development of a test
suite for the Tclcurl extension. The effort of having an application server challenging 
the Tclcurl client tests was generalized to a largely TclOO based multi-threaded architecture
featuring virtual hosts, simple yet flexible configuration, logging and control through a
unix-socket and a console script to send commands to the server.

Tclwire natively ships HTML documents but implements a worker API for developing
Tcl based web applications.  

## Tclwire Genesis

The existence of TclWire was made possible by devolving to an AI assistant much of the
development that concerned the generally awkward and impervious knowledge of protocol
details, reserving to the developer the task of devising the overall server architecture
and planning the development in steps that made possible to rewiew the code generated
for each code installment.

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
