# tclwire
An incidentally created Tcl based application server

## Documentation

The documentation is being organized as a MkDocs site. From the repository
root, install MkDocs and run:

```sh
mkdocs serve
```

The manual skeleton starts at [doc/manual/index.md](doc/manual/index.md).
Existing topic documents remain available as reference material:

- [Worker Request API](doc/WORKER_REQUEST_API.md): worker-facing HTTP request
  and response API.
- [Console](doc/CONSOLE.md): Unix-domain inspection and control socket,
  including `PS`, `CONN`, `LOGROTATE`, and `SHUT`.
- [Inter-Thread Communication](doc/INTER_THREAD_COMMUNICATION.md): current
  thread roles and message-passing pathways.
- [Request Body Handling](doc/REQUEST_BODY_HANDLING.md): current request-body
  buffering behavior and future body-mode constraints.
- [Agent Communication Data Structures](doc/AGENT_DATA_STRUCTURES.md):
  dictionaries and event structures exchanged among current agents.
- [Reimplementation TODO](doc/TODO.md): migration status and remaining gaps.
