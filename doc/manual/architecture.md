# Architecture

This chapter will explain TclWire's runtime architecture.

## Scope

- Runtime thread responsibilities.
- Transport reactors.
- Connection agents.
- Application dispatcher.
- Content Generator Agent workers.
- Thread-Pool Broker Agent.
- Logging agent.
- Shared state.
- Message-passing rules across Tcl interpreters and threads.

## Source Material

- `runtime-doc/INTER_THREAD_COMMUNICATION.md`
- `runtime-doc/FUNCTIONAL_COMPONENTS_TERMINOLOGY.md`
- `tcl/transport_reactor.tcl`
- `tcl/tpba.tcl`
- `tcl/thread_master.tcl`
