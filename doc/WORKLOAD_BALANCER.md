# Workload-Aware Thread Pool Balancing

This document records the current design discussion and implementation status
for TPBA-visible worker workload metrics and future connection-agent
concurrency.

## Motivation

Connection-agent workers are inherently asynchronous. A worker hosting network
I/O spends much of its lifetime waiting on channel events, so a strict
one-connection-per-thread assignment can waste threads. The target architecture
is to let a connection-agent worker host multiple logical connection agents up
to a configurable capacity, `max_conn_per_thread`.

The balancing goal is to reduce unnecessary thread creation while distributing
work evenly over the available worker threads. The TPBA should be able to pick
the worker with the lowest workload among eligible workers instead of selecting
the first idle worker.

This is being implemented in two steps:

1. Make worker workload visible to the TPBA and use it for idle-worker
   selection.
2. Generalize connection-agent workers so a single worker thread can host
   multiple active connection agents.

The first step is implemented. The second step remains future work.

## Current Allocation Model

Before workload metrics, allocation used only thread lifecycle state:

- `ThreadMaster` searched its owned workers for the first `idle` thread.
- The selected thread was marked `allocated`.
- If no idle thread existed and the pool was below `maximum_workers`, a new
  worker thread was created.
- Workers later returned themselves to the pool through TPBA
  `release_worker`, which changed the thread state back to `idle`.

This model works for Content Generator Agent pools because a CGA executes one
request at a time. It is too coarse for future concurrent connection-agent
pools, where a running worker may still have capacity for more connections.

## Workload Vocabulary

Worker pools maintain two raw workload values for each worker:

| Value | Meaning |
| --- | --- |
| `running_workload` | Current active workload. For current CGA workers this is normally `0` when reported. For connection-agent workers it is the current number of active connections. |
| `cumulative_workload` | Historical work completed or accepted by the worker. For CGAs this is completed request count. For connection-agent workers this is accepted connection count. |

The selected metric mixin interprets worker transition notifications and
computes a combined workload index, or CWI, from those raw values.

The workload database is pool-local. Each `ThreadMaster` stores workload
records keyed by worker thread id:

```text
ThreadMaster -> worker_id -> workload record
```

Each workload record contains:

- `thread_id`
- `running_workload`
- `cumulative_workload`
- `combined_workload`

## Metric Mixins

`ThreadMaster` does not encode any specific metric policy. It stores only an
opaque `metric_options` dictionary and delegates option configuration and CWI
calculation to the selected metric mixin. The metric mixin also interprets
transition ids reported by workers through TPBA.

### PlainMetric

`::tclwire::PlainMetric` is used for ordinary pools, including CGA pools.

It computes:

```text
CWI = cumulative_workload
```

This keeps CGA balancing simple: after a worker completes a request and becomes
idle, workers with fewer completed requests are preferred. The relevant CGA
transition is:

```text
request-processed
```

### ConcurrentConnectionMetric

`::tclwire::ConcurrentConnectionMetric` is selected for connection-oriented
pools. The mixin also configures its own metric-specific option default:

```text
max_conn_per_thread = 5
```

The option is not structural in `ThreadMaster`; it belongs to the connection
metric mixin. Invalid values are rejected by the mixin configurator.

The current scalar formula is:

```text
CWI = max_conn_per_thread * running_workload + cumulative_workload
```

The multiplication makes active connection count dominate historical work for
normal values. The connection metric also has the information needed for the
future eligibility predicate: a worker can accept more work while its
`running_workload` is below `max_conn_per_thread`. The current runtime still
keeps allocation idle-only because connection-agent workers are not yet
multi-agent.

The current connection-agent transitions are:

```text
connection-open
connection-closed
new-connection-processing
idle-connection-agent
```

All worker classes may also notify:

```text
thread-start
thread-exit
```

## Implemented Workload Management

The implemented workload-management step moves workload ownership into each
thread pool while keeping TPBA as the router for worker notifications.

Implemented behavior:

- Each `ThreadMaster` owns the workload database for its pool.
- Each `ThreadMaster` owns its `eligible_threads_list`.
- TPBA routes worker transition notifications to the correct pool.
- `pool_status` exposes workload data through `stats workloads`.
- `ThreadMaster` computes workload records through its selected metric.
- `ThreadMaster` selects the eligible idle worker with the lowest CWI.
- `PlainMetric` keeps ordinary pools idle-only.
- `ConcurrentConnectionMetric` tracks active connection count and computes CWI
  with `max_conn_per_thread`.
- CGA workers notify `request-processed` at the end of request processing.
- Connection-agent workers notify `connection-open` and `connection-closed`.
- connection-agent workers still host only one active connection agent.
- The shared thread accounting record mirrors `running_workload`,
  `cumulative_workload`, and `combined_workload`.

Workers should use the helper procedure:

```tcl
::tclwire::tpba notify_workload_transition $pool_key $transition_id
```

That helper emits the strict notification list:

```tcl
list [::thread::id] $pool_key $transition_id
```

The TPBA command shape is:

```tcl
::tclwire::tpba request [dict create \
    operation thread_workload_changed \
    notification [list $worker_id $pool_key $transition_id]]
```

The command validates that:

- the pool exists;
- the pool is active;
- the worker is owned by that pool;
- the notification is exactly `{thread_id pool_key transition_id}`.

## Current Limitations

Connection-agent workers are not yet concurrent. The current runtime still has
single-connection assumptions:

- each worker stores one `::tclwire::connection_agent`;
- starting a second agent in the same worker is rejected;
- the reactor currently maps one worker id to one active connection key;
- per-connection completion releases the whole worker back to the pool.

Because of these invariants, the allocator still gates actual selection to
idle workers. Full runtime support for selecting running connection-agent
workers still requires the future connection-agent concurrency changes below.

## Future Connection-Agent Concurrency

The second step should change connection-agent worker allocation from
whole-thread ownership to capacity-slot ownership.

Required changes:

- Replace the single worker-local `connection_agent` variable with a dictionary
  keyed by connection key or agent id.
- Track per-worker active connection count.
- Track per-worker cumulative accepted connection count.
- Change reactor-side tracking from `worker_id -> connection_key` to mappings
  that support many connections per worker, such as:
  - `connection_key -> worker_id`
  - `worker_id -> list(connection_key)`
- Include `connection_key` in completion callbacks so a multi-connection
  worker can identify which logical connection finished.
- Add a hard eligibility predicate for connection pools:

```text
active_connections + reserved_connections < max_conn_per_thread
```

- Make TPBA reserve capacity synchronously during `acquire_worker` so rapid
  accepts cannot over-assign a worker before its asynchronous workload report
  arrives.
- Reconcile TPBA reservations with worker workload reports.
- Release only one capacity slot when a connection closes; return the worker to
  `idle` only when the active connection count reaches zero.

## Open Design Notes

The current connection CWI is scalar. A later implementation may prefer tuple
ordering:

```text
{running_connections cumulative_connections last_selected_at}
```

That ordering would make the priority explicit: prefer fewer active
connections first, then lower historical load, then deterministic or
round-robin tie breaking.

The scalar CWI is acceptable for the current pool-level implementation. The
tuple approach should be reconsidered before the connection-agent runtime is
made fully concurrent.

## Tests

Current focused tests cover:

- workload transition notification through TPBA;
- workload visibility through `pool_status`;
- `PlainMetric` CWI calculation;
- `ConcurrentConnectionMetric` default `max_conn_per_thread`;
- validation of invalid `max_conn_per_thread`;
- lowest-CWI idle-worker selection;
- ownership validation for workload notifications.

Focused test commands:

```sh
tclsh tests/tpba.test
tclsh tests/thread_registry.test
```
