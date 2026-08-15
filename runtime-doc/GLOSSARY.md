# TclWire Architectural Glossary

This glossary records recurring architectural terms used in TclWire's source
comments, runtime documentation, and design discussions. The definitions are
project-specific: they describe how the words are used when reasoning about
TclWire components, interpreters, threads, and application APIs.

## Contract

A **contract** is the stable, observable agreement between two cooperating
parts of TclWire. It states what one side may provide, what the other may
assume, and how failure is reported, without prescribing the internal
implementation.

A contract may define:

- the required keys and meanings of a dictionary;
- the methods an object or environment must expose;
- valid inputs, results, and errors;
- ownership and lifecycle obligations;
- guarantees such as immutability, idempotence, ordering, or cleanup.

For example, `HttpProtocolSession feed` returns a dictionary with a
deliberately stable shape. Connection agents can consume that result as a
contract instead of probing for whichever keys happen to exist. Likewise, an
application environment must expose an `object` command whose object implements
the lifecycle and introspection methods expected by the runtime.

A contract says: whatever happens behind this interface, these are the
promises on which the rest of the system may rely.

## Constitution and Constitutional

The **constitution** of a component is the stable body of state, identity, and
governing relationships that makes the component what it is during its
lifetime. **Constitutional** describes something belonging to, or changing,
that stable order.

This is deeper than configuration alone. The constitution of a Content
Generator Agent (CGA) worker includes:

- the application to which the worker belongs;
- its immutable effective application configuration;
- the installed environments and namespace paths;
- the selected application class;
- the worker-local application object;
- the rules under which requests are handled.

Request data is transient; the application constitution endures for the
worker's lifetime. It is established during worker initialization and remains
stable across requests. Changing it is therefore a constitutional change:
TclWire should replace the application pool and retire its workers rather than
mutating their identity request by request.

The distinction from a contract is useful:

- a constitution describes what a component is and under what stable order it
  exists;
- a contract describes what that component promises to others.

In this sense, `::tclwire::app` is the constitutional namespace of an
application worker. It exposes the worker's stable application identity and
its current request context through controlled commands.

## Surface

A **surface** is the intentionally visible portion of a component: the
commands, methods, values, and behaviors available from a particular point of
view. The term always invites the question: visible to whom?

TclWire has several distinct surfaces:

- the application-facing surface of `HttpRequest`;
- the runtime control surface of the Thread Pools Broker Agent (TPBA);
- the namespace surface installed by an application environment;
- the Rivet compatibility surface;
- the small writable surface of an otherwise read-only request object.

A surface is not identical to the implementation. `HttpRequest`, for example,
wraps a rich transported descriptor but exposes only semantic request
operations. Routing metadata and mutable connection state remain below the
application surface.

A carefully designed surface reduces coupling. Internal representations can
evolve while application code continues to see a coherent vocabulary.
Environments use this property to change the application-visible command
surface without taking ownership of protocol parsing, sockets, dispatch, or
pool policy.

## Boundary

A **boundary** is the architectural line at which responsibility, ownership,
representation, authority, or lifetime changes.

Boundaries are especially important in TclWire because the server spans
multiple Tcl interpreters and threads. Examples include:

- the socket-ownership boundary between a listener and a connection-agent
  worker;
- the thread boundary crossed by copied request dictionaries;
- the protocol/application boundary where wire syntax becomes an
  `HttpRequest`;
- the environment boundary inside a CGA interpreter;
- lifecycle boundaries such as activation, shutdown, release, and cleanup.

A boundary is not merely the place where one source file calls another. It
marks a change in rules. At a boundary TclWire may need to copy or serialize
data, validate invariants, translate representations, transfer ownership, or
arrange cleanup on both sides.

For example, TclOO objects cannot cross interpreter boundaries. Application
configuration therefore crosses as a versioned dictionary envelope and is
reconstructed as a worker-local object. Similarly, the client channel never
crosses into the application worker: the connection agent retains socket and
protocol ownership while the application receives a copied semantic request.

`Boundary` also has a literal HTTP meaning in multipart parsing. That protocol
delimiter is distinct from the architectural use of the word.

## Ownership

**Ownership** identifies the component responsible for a resource and,
therefore, for its mutation, lifecycle, and cleanup. A connection agent owns
its client channel and authoritative transaction state; an application worker
does not. Clear ownership prevents two threads from making incompatible
decisions about the same resource.

## Authority and Authoritative State

An **authoritative** representation is the one whose state determines runtime
reality. Other dictionaries, snapshots, and wrappers may describe or project
it, but they do not compete with it. In the HTTP path, the connection agent
owns the authoritative mutable transaction while the application worker
receives a copied request view.

## Descriptor

A **descriptor** is a structured Tcl value, normally a dictionary, that
describes something sufficiently for another component to act on it. Request,
connection, application, pool, and transaction descriptors move information
without attempting to move thread-local objects.

A descriptor is usually internal and structural. It becomes an API only when
TclWire deliberately declares its shape to be a contract.

## Snapshot

A **snapshot** is a detached observation of state at a particular moment. It
is safe to inspect or modify locally because changing it does not mutate the
source object. Snapshots are especially useful at thread and introspection
boundaries.

## Envelope

An **envelope** is a transport representation carrying both a payload and
enough metadata to interpret it safely, such as a type and schema version.
TclWire's serialized application configuration is an envelope rather than an
arbitrary dictionary because its meaning and evolution are explicitly
identified.

## Pivot

A **pivot** is the precise moment at which processing changes responsibility
or representation. Parsing headers and beginning body framing is a pivot;
converting a request descriptor into an application-facing object is another.
Boundaries are structural lines, while pivots are events that cross or activate
those lines.

## Handoff

A **handoff** is a pivot involving ownership or responsibility moving from one
component to another. A correct handoff accounts for both success and partial
failure: after every possible outcome, exactly one component must still own
cleanup.

## Invariant

An **invariant** is a condition that must remain true throughout a defined
state or lifecycle. Examples include: a completed feed result always contains
the same keys; a worker belongs to one application pool; and the application
never owns the client socket. Contracts expose invariants; implementations
preserve them.

## Projection and View

A **projection**, or **view**, presents selected meaning from a richer internal
value. `HttpRequest` is the application-facing projection of the transported
request descriptor. It exposes what application code needs while withholding
routing metadata and connection authority.

## Policy and Mechanism

A **mechanism** provides a capability; a **policy** decides how that capability
should be used. TPBA supplies worker-pool mechanisms, while pool policy
determines capacity and allocation rules. The transport reactor performs
connection dispatch but does not independently invent worker lifecycle policy.

## Summary Principle

Each TclWire component has a constitution, presents a deliberate surface,
makes contracts across explicit boundaries, and retains unambiguous ownership
of the state for which it is authoritative.
