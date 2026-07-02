# Workload Balancer Development Status Assessment

## Current Model

Worker eligibility is maintained when lifecycle and workload transitions are
processed. Allocation consumes this authoritative state directly rather than
reconstructing it by scanning the pool.

- Plain/CGA pools maintain an idle-worker FIFO.
- Connection-worker pools maintain eligible workers in increasing combined
  workload index (CWI) order.
- Equal connection-worker CWI values are ordered by thread id, providing a
  deterministic tie breaker.
- Newly created zero-workload workers enter the eligibility structure as idle
  before allocation.
- `allocate_eligible_thread` reads the queue head and advances a cursor. The
  normal allocation path is therefore constant-time.
- Connection reservations distinguish synchronously reserved capacity from
  asynchronously confirmed connection opens, preventing double accounting.

## Assessment

The model is structurally sound. Eligibility is updated at the point where the
information changes, while allocation performs only selection. This removes
the previous duplication in which the maintained eligibility list was
supplemented by a scan of idle and running workers.

The main benefits are:

- predictable FIFO reuse for request-at-a-time workers;
- deterministic connection-worker selection;
- constant-time normal allocation;
- workload ordering costs paid during workload transitions rather than on the
  connection dispatch path;
- a clearer ownership boundary: `ThreadMaster` and its metric mixin own
  eligibility policy, while TPBA routes transition notifications.

## Risks and Limitations

### Derived-state consistency

The eligibility structure is derived state. A missing, duplicated, or
out-of-order transition notification can make it inconsistent with accounting.
The allocation path should not reintroduce a pool scan, but diagnostics should
make such divergence observable.

### Transition-time complexity

Connection-worker repositioning currently uses a sequentially ordered Tcl
list, making a transition update O(n). Allocation remains O(1) through the head
cursor. This tradeoff is appropriate for current pool sizes; substantially
larger pools may justify a heap, bucketed priority queue, or another indexed
priority structure.

### Historical weight in CWI

The connection-worker metric is:

```text
CWI = max_conn_per_thread * running_workload + cumulative_workload
```

Including cumulative workload provides long-term fairness, but historical work
never decays. Over a sufficiently long runtime it can dominate current load.
Operational evidence should determine whether cumulative workload needs an
epoch, decay factor, or periodic normalization.

### Accounting error handling

`allocate_eligible_thread` discards a queue entry when changing its accounting
status fails. This handles externally removed accounting records, but catching
every error can hide genuine accounting faults. Error handling should
eventually distinguish a missing/stale worker from other failures and propagate
unexpected errors.

## Recommended Follow-up

Add a debug-only invariant checker that independently derives expected
eligibility from owned-thread accounting and workload records, then compares it
with the maintained queue. It should be used by tests and diagnostics, not by
normal allocation. This provides evidence and recovery guidance without
compromising the constant-time fast path.

The invariant checks should cover:

- every queued worker is owned by the pool;
- every queued worker satisfies its metric's eligibility predicate;
- no worker occurs more than once;
- every eligible owned worker is represented;
- plain-worker order follows return order;
- connection-worker order is nondecreasing by CWI and deterministic for ties;
- the queue head cursor never exceeds the underlying list length.

