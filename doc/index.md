# TclWire

![TclWire logo](assets/tclwire-logo.png){: .home-logo }

TclWire is a Tcl written application server supporting the HTTP,
HTTPS, FTP, FTPS and proxy protocols and was spurred by the
work aimed at implementing a server for the test suite of the
[Tclcurl](https://github.com/mxmanghi/tclcurl-ng) extension.
Tclwire is a largely multi-threaded architecture featuring a simplified
model of virtual hosts, TOML flexible configuration, logging 
and a Tcl application development layer
which supports binary and text HTTP data transmission, multipart messaging
handling, fixed length and chunked transfers, socket channel control

Tclwire also implements *environment*, configurable code preloaded
by an application that can emulate a given application environment.
For example applications written for Apache/Rivet can run by
requiring the 'rivet' environment in the configuration.

Since the worker threads run within the same process web services
developed for Tclwire can share part of their state by using Tcl
Thread shared areas and interthread communication mechanism.

Tclwire natively ships HTML documents but implements a worker API
for developing Tcl based web applications.

Tcl wire supports also secure HTTPS connections

## Rationale

In recent years the need of feature reach application servers has
partially waned because content distribution or custom applications
often run within virtualization systems that are hosted within private
networks. On these infrastructure the burden of connection filtering,
certificate handling or other network oriented tasks in on one hand left
to proxy servers, routers and firewalls, effectively relieving the
application end-point of much of the responsabilities connected to the
transport layer. On the other hand having application be running within
virtualization systems often shift to these systems the complexity tied
to resource control and application authorization and safety. In this view
Tclwire is another tool for the Tcl programmer with a focus on web
application development and inherent multithreading. 

## Advocacy

Tclwire is a application entirely written in Tcl, a pathologically simple yet
robust scripting language, which implements a `apartment thread` model where
each thread runs its own Tcl interpreter and communicate by sending messages in
the form of script fragments or using the multhreading typical constructs such
as mutexes, condition variables and protected shared areas. The costs of
message based communication are at least partially offset by the robustness of
the approach, since scripts live within an interpreter and the basic tenet of
Tcl's threading approach is that no intepreter can be shared across threads,
even though a Tcl thread can run multiple interpreters. Therefore this
threading model easily avoids the classical pitfalls tied to threads
synchronization and resource sharing which classically ail multithreaded
programming.

## Tclwire Genesis

The initial buildup of TclWire was made possible by devolving to an AI
assistant much of the development that concerned the generally awkward
and impervious protocol details. But the overall functional organization,
their roles, features and structure is mostly the product of the author
direct intervention on the assistant work. The code is as much as
possible organized in TclOO classes and their development followed a
step-by-step progression in order to enable the author to conduct a
thorough review of every code installment.

## Disclaimer

This project is the first from-ground-up project developed by the author
with an AI assistant. Tclwire was therefore also the testbed where
AI driven development was exploited and tested. In a modern era of 
software development AI assisted programming poses several questions
about code efficiency and responsible usage of the AI assisted power.

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
