# tclwire
An incidentally created Tcl based application server

## Documentation

The documentation is being organized as a MkDocs site. From the repository
root, install MkDocs and run:

```sh
mkdocs serve
```

The manual skeleton starts at [doc/manual/index.md](doc/manual/index.md).
The older topic documents used to seed TclWire's runtime document root are
kept under `runtime-doc/`:

- [Worker Request API](runtime-doc/WORKER_REQUEST_API.md): worker-facing HTTP request
  and response API.
- [Application Configuration](runtime-doc/APPLICATION_CONFIGURATION.md): immutable
  application descriptor object and serialization envelope.
- [Console](runtime-doc/CONSOLE.md): Unix-domain inspection and control socket,
  including `PS`, `CONN`, `LOGROTATE`, and `SHUT`.
- [Inter-Thread Communication](runtime-doc/INTER_THREAD_COMMUNICATION.md): current
  thread roles and message-passing pathways.
- [Request Body Handling](runtime-doc/REQUEST_BODY_HANDLING.md): current request-body
  buffering behavior and future body-mode constraints.
- [Agent Communication Data Structures](runtime-doc/AGENT_DATA_STRUCTURES.md):
  dictionaries and event structures exchanged among current agents.
- [Chores](runtime-doc/CHORES.md): scheduler-owned periodic maintenance tasks,
  server/application chore registration, and implementation examples.
- [Reimplementation TODO](runtime-doc/TODO.md): migration status and remaining gaps.
