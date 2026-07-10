# Glossary

This chapter will define TclWire terminology.

## Initial Terms

Application
: A TclOO object that handles one HTTP request through `handle_request`.

CGA
: Content Generator Agent. A worker thread that runs application code and sends
  ordered output events back to the connection agent.

Connection Agent
: A worker object that owns an accepted client channel and protocol session.

TPBA
: Thread-Pool Broker Agent. The thread and API responsible for worker-pool
  lifecycle and allocation.

Transport Reactor
: A runtime-thread object that owns a service listener and dispatches accepted
  connections.

## Source Material

- `runtime-doc/FUNCTIONAL_COMPONENTS_TERMINOLOGY.md`
- `runtime-doc/INTER_THREAD_COMMUNICATION.md`
