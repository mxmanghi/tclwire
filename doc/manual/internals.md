# Internals

This chapter will collect implementation details that are useful to maintainers
but should not be treated as stable public API unless explicitly stated.

## Scope

- Request descriptors.
- Transaction descriptors.
- Output events.
- Agent dictionaries.
- Shared accounting state.
- Thread-pool records.
- Internal compatibility notes.

## Source Material

- `runtime-doc/AGENT_DATA_STRUCTURES.md`
- `runtime-doc/INTER_THREAD_COMMUNICATION.md`
- `tcl/transaction_descriptor.tcl`
- `tcl/threads_shared_db.tcl`
