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

Workers report two raw values:

| Value | Meaning |
| --- | --- |
| `running_workload` | Current active workload. For current CGA workers this is normally `0` when reported. For connection-agent workers it is the current number of active connections. |
| `cumulative_workload` | Historical work completed or accepted by the worker. For CGAs this is completed request count. For connection-agent workers this is accepted connection count. |

The selected metric mixin computes a combined workload index, or CWI, from
those raw values.

The TPBA stores workload records in a private dictionary keyed first by pool
key and then by worker thread id:

```text
pool_key -> worker_id -> workload record
```

Each workload record contains:

- `thread_id`
- `running_workload`
- `cumulative_workload`
- `combined_workload`

## Metric Mixins

`ThreadMaster` does not encode any specific metric policy. It stores only an
opaque `metric_options` dictionary and delegates option configuration and CWI
calculation to the selected metric mixin.

### PlainMetric

`::tclwire::PlainMetric` is used for ordinary pools, including CGA pools.

It computes:

```text
CWI = cumulative_workload
```

This keeps CGA balancing simple: after a worker completes a request and becomes
idle, workers with fewer completed requests are preferred.

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
normal values. In a future capacity-aware allocator, this metric should be used
only after an eligibility check confirms that the worker is still below
`max_conn_per_thread`.

## Implemented First Step

The implemented first step adds TPBA-visible metrics without changing the
current single-connection-per-worker runtime model.

Implemented behavior:

- TPBA owns a workload database keyed by pool key and worker id.
- TPBA exposes `report_workload`.
- TPBA exposes `pool_workloads`.
- `pool_status` includes the workload table.
- `ThreadMaster` can compute workload records through its selected metric.
- `ThreadMaster` selects the idle worker with the lowest CWI when TPBA passes
  a workload table into `acquire_worker`.
- CGA workers report cumulative completed request count at the end of request
  processing, before releasing themselves back to the TPBA pool.
- connection-agent workers report workload on connection startup and
  connection finish.
- connection-agent workers still host only one active connection agent.

The implemented command shape is:

```tcl
::tclwire::tpba request [dict create \
    operation report_workload \
    pool_key $pool_key \
    worker_id $worker_id \
    running_workload $running_workload \
    cumulative_workload $cumulative_workload]
```

The command validates that:

- the pool exists;
- the pool is active;
- the worker is owned by that pool;
- workload values are non-negative integers.

## Current Limitations

The workload-aware allocator still only selects idle workers. This is
intentional for the first step.

Connection-agent workers are not yet concurrent. The current runtime still has
single-connection assumptions:

- each worker stores one `::tclwire::connection_agent`;
- starting a second agent in the same worker is rejected;
- the reactor currently maps one worker id to one active connection key;
- per-connection completion releases the whole worker back to the pool.

Because of these invariants, `ConcurrentConnectionMetric` currently reports
useful workload data but does not yet make running connection-agent workers
eligible for additional connections.

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

The scalar CWI is acceptable for the first instrumentation step because
connection workers are still selected only when idle. The tuple approach should
be reconsidered before enabling running connection-agent workers as allocation
candidates.

## Tests

Current focused tests cover:

- workload reporting through TPBA;
- workload visibility through `pool_workloads` and `pool_status`;
- `PlainMetric` CWI calculation;
- `ConcurrentConnectionMetric` default `max_conn_per_thread`;
- validation of invalid `max_conn_per_thread`;
- lowest-CWI idle-worker selection;
- ownership validation for workload reports.

Focused test commands:

```sh
tclsh tests/tpba.test
tclsh tests/thread_registry.test
```

