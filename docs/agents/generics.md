# Generic Constraints, Protocols, and Existentials

Status: static generics/protocol milestone implemented on `examples-hardening`;
opaque `some` and existential `any` remain proposed follow-up work

Core domain: constrained generics, protocols, associated types, opaque types,
heterogeneous values, capability preservation, Zig comptime lowering, and
diagnostics

## Implementation Status (2026-07-16)

The zero-cost/static portion of this design is implemented and executable:

- inline bounds (`T: Protocol`, intersections, and `SHARED Protocol`);
- owner-scoped inherent `IMPLEMENTATION Owner<T>` blocks with checked METHOD
  lookup and file/arity/coherence diagnostics;
- the intrinsic `Map` protocol, `M::Key`/`M::Value`, indexing, and its stable
  operation set;
- user `PROTOCOL` declarations, inferred conformance headers such as
  `IMPLEMENTATION Lookup<K, V> FOR Store`, conditional conformance binders,
  associated projections, METHOD/FN requirements, and effect checking;
- compile-time adapters with no runtime witness object or existential
  allocation;
- capability-preserving conformance and dispatch through
  `WITH POLYMORPHIC`, including shared wrapper families;
- the self-checking O(1) generic LRU in `examples/generic_cache/`.

The following parts of the broader design are deliberately not claimed as
implemented:

- the expanded `REQUIRES T IS_A P` and general `COMPTIME_REQUIRES` surface;
- opaque `some Protocol` return/parameter types;
- runtime-erased `any Protocol` values and heterogeneous protocol lists;
- exported cross-package conformance metadata and protocol default methods.

Therefore, the implemented milestone is a complete local static-protocol
milestone, not yet a replacement for Rust `dyn Trait`, Swift `any Protocol`,
or Go interface values. A bare protocol name never silently erases a value.

## Executive Decision

CLEAR's protocol system uses static specialization by default. This is the
language's trait/interface system, not a map-specific parser exception.

The design has three deliberately distinct abstractions:

| Surface | Concrete type chosen by | Runtime representation | Dispatch |
| --- | --- | --- | --- |
| `T: Protocol` | Caller | The concrete `T` | Static/comptime |
| `some Protocol` | Producer | One hidden concrete type | Static/comptime |
| `any Protocol` | Runtime value | Explicit existential container | Dynamic witness table |

The common path is a locally bounded type parameter. `T: Protocol` is exact
syntax sugar for `T` plus `REQUIRES T IS_A Protocol`; it should lower to
ordinary Zig
`comptime T: type` / `anytype` specialization with no witness table, allocation,
or runtime type test. `some` also preserves one concrete type. Only `any`
permits heterogeneous runtime values and pays for erasure.

The motivating cache is generic over its complete map type:

```clear
STRUCT Cache<M: SHARED Map> {
  values: M,
}

FN put!<M: SHARED Map>(
  MUTABLE cache: Cache<M>,
  key: M::Key,
  value: M::Value,
) RETURNS !Void ->
  WITH POLYMORPHIC cache.values AS values {
    values[key] = value;
  }
END
```

Capabilities remain part of `M`; they are not separate generic arguments and
are not erased:

```clear
Cache<{String}@shared:locked User>
Cache<{String}@shared:versioned User>
Cache<{String}@shared:sharded(16):writeLocked User>
```

`SHARED Map` means a Map conformance whose concrete value has an admitted
shared synchronization capability. This particular cache rejects a local map
when `Cache<M>` is instantiated,
rather than waiting for `put!` to reach `WITH POLYMORPHIC`. A separate
`LocalCache<M>` or an implementation that does not require polymorphic access
may admit local maps. A declaration must never promise that every `Cache<M>` is
usable by `put!` when some well-formed `M` fails the method's synchronization
contract.

`Map` is a behavioral/layout constraint, not a runtime base class. Inline map
types satisfy it intrinsically. A user-defined type satisfies a user protocol
only through an explicit checked conformance.

## Why This Is a Language Feature, Not a Cache Feature

As soon as the compiler permits `M: Map` (or its expanded
`REQUIRES M IS_A Map` form), it must answer all of the questions
normally owned by a trait or interface system:

- What operations may a generic body perform on `M`?
- How are `M`'s key and value types named?
- When and where is conformance checked?
- Can conformance be implicit, retroactive, overlapping, or conditional?
- Is generic dispatch static or dynamic?
- Can values of different conforming types share one collection?
- How are ownership, cleanup, synchronization, and errors preserved through
  an abstract boundary?
- What does a protocol mean across packages and FFI boundaries?
- How does the compiler report one useful constraint error rather than the
  downstream errors produced by unconstrained Zig `anytype`?

Hard-coding `Map` answers inside indexing and method resolution would create an
implicit, incomplete trait system. It would work for the first cache and fail
as soon as the compiler needs an iterator, formatter, allocator, graph store,
or parser collection abstraction. The protocol model must therefore be small,
explicit, and reusable from its first implementation.

## Design Goals

In priority order:

1. **Preserve CLEAR's capability model.** Ownership, synchronization, layout,
   topology, tenses, and access requirements remain attached to the exact type
   node they modify.
2. **Static by default.** Generic abstraction should normally have the same
   runtime representation and dispatch as hand-written concrete code.
3. **Simple call sites.** Infer type arguments and witnesses from ordinary
   values. Do not make callers write capability arguments or adapter objects.
4. **Early complete diagnostics.** Type-check a generic body against declared
   constraints and validate conformances before Zig emission.
5. **Visible runtime costs.** Heterogeneous erasure requires `any`; it must
   never happen because a protocol name silently became a boxed interface.
6. **One semantic model.** Built-in collection constraints and user protocols
   share `Constraint`, `AssociatedType`, and `ConformanceWitness` facts.
7. **Ideal Zig.** Emit small comptime adapters and direct calls, not repeated
   reflection trees or runtime registries.
8. **Bound specialization.** Canonicalize instantiations, report recursive or
   excessive expansion, and outline constraint-independent code when useful.
9. **Support self-hosting.** The model must express compiler collections,
   visitors, diagnostics, formatters, and allocators without Ruby-like dynamic
   fallback.

## Non-Goals for the First Milestone

- Class inheritance or implementation inheritance.
- Higher-kinded types and arbitrary type-level functions.
- Specialization based on overlapping conformances.
- Implicit user-defined structural conformance.
- Covariant mutable collections.
- Reflection as an application runtime service.
- Making every Zig `anytype` API directly visible as a CLEAR protocol.
- Hiding the cost or error family of synchronization behind an unannotated
  conversion.

## Baseline Before This Implementation

The branch began with these useful foundations:

- structs, unions, and functions accept named type parameters;
- call-site inference recursively binds parameters such as `Cache<T>`;
- `TypeExpression` recursively preserves maps, linear collections, tenses,
  tuples, and capabilities;
- generic structs lower to Zig functions returning a type;
- generic functions lower type parameters as `comptime T: type`;
- `SHARED T`, `REQUIRES`, and `WITH POLYMORPHIC` carry concrete call-site
  synchronization into a generic body.

Two superficially related spellings did not provide the needed model:

- current `REQUIRES` parses parameter capability/reentrance families, but not
  type conformance, and `COMPTIME_REQUIRES` is not present on this branch;
- current non-extern `METHOD` is a formatter/call-style directive, not an owner
  scope. Extern declarations already distinguish owner type parameters from
  function type parameters, which is a useful AST precedent but not an
  implementation-block feature.

The work was scoped around the following gaps. The static entries are closed;
the opaque/existential entries are the explicitly deferred roadmap:

- type parameters have names but no declared constraints;
- a body cannot prove that unconstrained `T` supports indexing or map methods;
- there are no associated-type projections such as `M::Key`;
- generic validation records only type-argument arity and substitution;
- the MIR has no protocol-operation or witness concept;
- there is no distinction between an opaque conforming type and a runtime
  existential;
- heterogeneous conforming values have no safe uniform representation;
- nested capability provenance is not described by a general constraint fact.

## Prior-Art Assessment

No examined system is universally bad. Each optimizes for a different runtime,
compatibility boundary, and audience. Several choices are nevertheless a poor
fit for CLEAR.

### Rust

Rust traits provide explicit named contracts, associated functions/types/
constants, bounds, static generic dispatch, explicit `dyn Trait` runtime
dispatch, and `impl Trait` opaque types. This is the strongest semantic model
in the comparison and the clearest precedent for separating static, opaque,
and existential uses.

Strengths worth keeping:

- protocol requirements are known while checking the generic body;
- associated types express relationships such as `Map::Key` and `Map::Value`;
- runtime dispatch is explicit in `dyn` and normally requires explicit
  indirection;
- opaque `impl Trait` preserves optimization while hiding implementation type;
- coherence prevents two incompatible implementations from silently winning.

Costs CLEAR should reduce:

- trait bounds, where clauses, associated types, object/dyn compatibility,
  auto traits, lifetimes, and coherence form a large concept surface;
- dyn compatibility rules make some traits unusable as trait objects;
- monomorphization increases compile time and binary size;
- users often must understand whether a type is `T`, `impl Trait`,
  `dyn Trait`, or `Box<dyn Trait>` before solving the domain problem.

CLEAR should take Rust's semantic separation without importing its lifetime
syntax or requiring an explicit `impl` block for compiler-known collection
shapes.

### Swift

Swift protocols combine associated types, generic constraints, extensions, and
default implementations. Modern Swift explicitly distinguishes generic
constraints, opaque `some Protocol`, and boxed `any Protocol` values.

Strengths worth keeping:

- `some` versus `any` is direct, readable progressive disclosure;
- primary associated types make constraints such as a map of specific key and
  value types concise;
- protocols can supply reusable default behavior;
- existential cost and loss of concrete identity are conceptually separate
  from ordinary generics.

Costs CLEAR should avoid:

- historical ambiguity where a bare protocol name could mean an existential;
- witness-table and existential-container costs appearing in code that looks
  similar to static generic code;
- difficult rules around protocols with `Self` or associated-type requirements
  when used existentially;
- runtime exclusivity checks and boxing caused by erased layout.

CLEAR should require `any` from day one. A protocol name alone is never a
runtime value type.

### Go

Go's small implicit interfaces are exceptionally easy to consume. A type
conforms by having the required methods, with no declaration coupling. Go's
generic constraints are also interfaces and may contain type sets.

Strengths worth keeping:

- small behavioral contracts encourage decoupled APIs;
- type inference makes most generic calls look ordinary;
- functions over language collections are concise;
- users do not write adapters merely to satisfy a nominal hierarchy.

Costs CLEAR should avoid:

- the same `interface` concept serves runtime interface values and compile-time
  type constraints, making representation less obvious;
- implicit conformance can be accidental and provides no declaration-site
  audit for ownership or synchronization semantics;
- runtime interface values erase layout and use dynamic type information;
- interface nil/dynamic-type behavior is not suitable for CLEAR's explicit
  optional model;
- method sets alone cannot express CLEAR's topology, cleanup, or access-gate
  facts.

CLEAR should retain easy inference and small protocols, but require explicit
user conformance. Compiler-known structural types such as maps can receive
intrinsic conformance because their semantics are defined by the language.

### Zig

Zig uses `anytype`, `comptime T: type`, `@TypeOf`, `@typeInfo`, `@hasDecl`, and
ordinary compile-time functions instead of a language-level trait system.

Strengths CLEAR should exploit in lowering:

- arbitrary static specialization without runtime metadata;
- compile-time reflection over concrete layout and declarations;
- generated adapter types and functions are ordinary Zig and optimize well;
- result-location and comptime evaluation can eliminate wrapper construction;
- the backend can choose direct calls, inline adapters, or generated vtables
  from the same concrete facts.

Costs CLEAR should shield users from:

- `anytype` does not declare a contract at the signature;
- failures often appear only after instantiation and point into implementation
  details;
- editor and documentation tooling cannot reliably explain what an `anytype`
  parameter accepts;
- ad-hoc `@hasDecl` checks duplicate interface definitions and diagnostics;
- repeated reflection can increase analysis work and generated-code noise.

CLEAR should use Zig comptime as a target mechanism, not expose it as the user
contract system. The CLEAR frontend validates protocols and emits a canonical
adapter once per concrete conformance.

### Kotlin

Kotlin provides approachable nominal interfaces, declaration-site variance,
type projections, type inference, default implementations, reified inline
parameters, and language-supported delegation.

Strengths worth keeping:

- interface declarations and implementation errors are easy to understand;
- delegation avoids boilerplate wrapper methods;
- declaration-site variance communicates producer/consumer intent;
- erased and reified operations are explicit in generic APIs.

Costs CLEAR should avoid:

- ordinary generic arguments are erased at runtime;
- platform object layout, boxing, and virtual dispatch are acceptable JVM
  tradeoffs but violate CLEAR's systems-performance objective;
- star projections and in/out variance add substantial complexity;
- nominal class/interface subtyping does not describe inline collection layout
  or capability placement.

CLEAR mutable collections remain invariant in the first protocol milestone.
Delegation may be useful later, but it must preserve capability and ownership
facts rather than forward only method names.

### Choices That Are Unacceptable for CLEAR

They are not universally wrong, but these combinations would be design
failures for this language:

1. A bare protocol name silently allocating or dynamically dispatching.
2. Treating `anytype` failure inside generated Zig as the primary constraint
   checker.
3. Erasing a capability chain while retaining only a method table.
4. Claiming map-only synchronization makes a compound LRU transaction safe.
5. Allowing accidental user conformance to security, ownership, or sync
   contracts.
6. Making homogeneous generic collections use existential boxes.
7. Accepting overlapping conformances whose selection depends on import order.
8. Reporting every missing method as a separate downstream error instead of
   one conformance diagnostic.
9. Relying on future incremental compilation to excuse unbounded generic
   expansion. Zig incremental compilation is improving, but it remains an
   optional feature with known correctness limitations at the time of this
   design.

## Terminology and Semantic Model

### Protocol

A protocol is a named compile-time contract containing:

- associated types;
- required functions and methods;
- required effects;
- receiver mutability/ownership requirements;
- optional default implementations;
- optional protocol composition.

It has no instance layout and cannot be instantiated.

### Conformance

A conformance associates one concrete type expression with one protocol and
produces a checked `ConformanceWitness`:

```text
ConformanceWitness
  protocol_id
  concrete_type_key
  associated_type_bindings
  operation_bindings
  effect_summary
  ownership_contract
  capability_contract
  visibility/package_owner
```

The witness is a compiler fact. Static generic code does not carry it at
runtime. An existential may reference a runtime witness table generated from
the same fact.

### Constraint

A generic constraint limits a type parameter and supplies facts for checking
the generic body:

```clear
M: Map
T: Hashable & Equality
```

These normalize to `REQUIRES M IS_A Map`, `REQUIRES T IS_A Hashable`, and
`REQUIRES T IS_A Equality`. Constraint composition is intersection. The first
milestone does not add negative bounds or specialization.

### Associated Type

An associated type belongs to the conforming concrete type:

```clear
M::Key
M::Value
```

It is a real recursive `TypeExpression`, so it may itself contain tenses,
collections, tuples, capabilities, or another projection.

### Opaque Type

`some P` means one concrete conforming type chosen by the producer. All return
paths must use that same type. The compiler retains its identity; the caller
may use only the stated protocol surface.

### Existential Type

`any P` is an explicitly erased runtime value. Different values may have
different concrete types. It contains ownership/cleanup metadata and a witness
table. It is the only protocol form that enables a heterogeneous list.

## Surface Syntax and Deferred Extensions

### Declaring a protocol

```clear
PROTOCOL Map<Key, Value> {
  FN get(self: Self, key: Key) RETURNS !?Value;
  FN put!(MUTABLE self: Self, key: Key, value: Value) RETURNS !Void;
  FN delete!(MUTABLE self: Self, key: Key) RETURNS !Bool;
  FN length(self: Self) RETURNS Int64;
}
```

`Key` and `Value` are primary associated types, not storage fields and not
runtime generic arguments. The verbose equivalent is conceptually:

```clear
PROTOCOL Map {
  TYPE Key;
  TYPE Value;
  # requirements...
}
```

The primary spelling makes constrained existentials and adapters readable.

The initial built-in `Map` protocol is language supplied. Its exact operation
set should match the stable common map surface, not every method implemented by
one backend map.

### Inline bounds are contract sugar

A local inline bound is concise and familiar. Rust, Swift, and Kotlin all use
closely related colon-bound syntax; Go uses the same idea without the colon.
CLEAR should support it, but it must desugar into the existing declaration-
contract model rather than create a second constraint engine.

It also preserves CLEAR's ordinary parameter reading:

```clear
FN foo(user: User) RETURNS Void -> ... END
FN bar<T: Map>(cache: T) RETURNS Void -> ... END
```

`user: User` binds a value constrained to `User`; `T: Map` binds a type
constrained to `Map`. The parser records their different binding kinds, then
the contract resolver handles both without a separate generic-bound path.

```clear
STRUCT MapBox<M: Map> {
  values: M,
}

FN keys<M: Map>(map: M) RETURNS []M::Key ->
  # ...
END
```

The following pairs are semantically identical and produce identical typed
facts, diagnostics, metadata, and Zig:

```clear
STRUCT MapBox<M: Map> { values: M }

STRUCT MapBox<M>
  REQUIRES M IS_A Map
{
  values: M,
}

STRUCT SharedCache<M: SHARED Map> { values: M }

STRUCT SharedCache<M>
  REQUIRES M IS_A SHARED Map
{
  values: M,
}
```

The formatter should prefer the inline form when a requirement:

- constrains exactly one type parameter;
- is a direct `IS_A` protocol/capability bound; and
- does not refer to another parameter or associated projection.

`T: SHARED R` means the concrete `T` both satisfies protocol `R` and belongs
to an admitted shared capability family. Square brackets in prose such as
`T: [SHARED] R` denote optionality; they are not literal CLEAR syntax.

Cross-parameter relationships are contracts too:

```clear
FN stableKeys<M: Map, K: Hashable & Equality>(map: M) RETURNS []K
  COMPTIME_REQUIRES M::Key == K
->
  # ...
END
```

The contract families have distinct jobs:

- `T: P` and `REQUIRES T IS_A P` prove the same conformance. The operands make
  this a static contract; it emits no runtime check.
- `COMPTIME_REQUIRES expression` handles a relationship that must be evaluated
  at instantiation, such as exact associated-type equality or a numeric
  capacity invariant. It is not a second place to spell ordinary conformance.
- `REQUIRES parameter: FAMILY` continues to describe admitted runtime
  capability/reentrance families. Existing forms such as
  `REQUIRES map: LOCKED | VERSIONED` remain valid.
- `EFFECTS` describes behavior of the declaration. A protocol implementation
  may have the same or a narrower effect contract than its requirement, never
  an undeclared broader one.

`M: SHARED Map` composes a capability-family requirement with a behavioral
requirement. It is checked when `Cache<M>` is formed, so an unshared `M` cannot
create a value whose methods fail only later. There is no `WHERE` clause in
this design.

### Nominal generic identity and arity

A generic type's identity is its fully qualified nominal name, not its type
parameter names, constraints, or arity. One package scope may declare exactly
one `Cache`:

```clear
STRUCT Cache<M: Map> { ... }

# Illegal: this is a second declaration of the same nominal Cache.
STRUCT Cache<L: List> { ... }

# Also illegal: constraints do not overload a nominal declaration.
STRUCT Cache<T: List> { ... }
```

The second declaration produces one error at its name and cites the first:

```text
Duplicate type declaration `Cache`.

`Cache` was already declared as `Cache<M: Map>` at cache.clear:1.
Generic parameter names and constraints do not overload a type name.

Rename this type (for example, `ListCache`) or define one Cache over a common
protocol implemented by both storage strategies.
```

This matches the nominal model used by Rust, Swift, Go, and Kotlin. If maps and
lists genuinely expose the same cache operations, define a purpose-specific
`CacheStore` protocol and one `Cache<S: CacheStore>`. If their semantics differ,
`MapCache` and `ListCache` should be different types.

Arity belongs to that one declaration. Given `STRUCT Cache<M: Map>`, this is
rejected while checking the function signature, before its body:

```clear
FN inspect<T, K>(cache: Cache<T, K>) RETURNS Void -> ... END
```

```text
Generic type `Cache` expects 1 type argument but received 2.

Declared here: Cache<M: Map>
Written here:  Cache<T, K>

Remove `K`, or use/declare a distinct two-parameter type such as
`KeyedCache<M, K>`.
```

The compiler does not attempt to select a different `Cache` by arity or by
which constraints happen to pass. That would turn ordinary type lookup into
overload resolution and make diagnostics and separate compilation fragile.

### Explicit user conformance

Intrinsic collection shapes conform automatically to their language-defined
protocols:

```clear
{String}User                           # Map<String, User>
{String}@shared:locked User            # Map<String, User>
{String}@sharded(8):writeLocked User   # Map<String, User>
```

User types state conformance explicitly:

```clear
STRUCT SmallMap<K: Hashable, V> {
  # fields
}

IMPLEMENTATION Map<K, V> FOR SmallMap {
  # checked Map requirement implementations
}
```

The protocol-side arguments infer the owner's slots, so binders are not
repeated before `Map`: `IMPLEMENTATION<K, V> Map<K, V> FOR SmallMap<K, V>` is
not canonical CLEAR. A leading binder list is used only when it introduces an
additional conditional constraint that cannot be inferred from the protocol
application, for example `IMPLEMENTATION<T: Hashable> Sized FOR Box`.

The compiler resolves the declared methods and reports the complete missing or
incompatible requirement set at this declaration. A later adapter form may
support an existing or external type:

```clear
IMPLEMENTATION Map<K, V> FOR ForeignMap {
  # explicit operation bindings or adapter methods
}
```

Coherence rules:

- only one conformance exists for a `(protocol, concrete type)` pair;
- the current package must own the protocol or the concrete nominal type;
- imports never choose between conformances;
- intrinsic collection conformances cannot be replaced;
- conditional conformances must state all conditions and cannot overlap.

### Owner-scoped generic implementations

Today a function such as this is type-unambiguous:

```clear
FN put!<M: SHARED Map>(MUTABLE cache: Cache<M>, key: M::Key, value: M::Value)
  RETURNS !Void ->
  # ...
END
```

Inference binds the one `M` from `Cache<M>` and reuses it everywhere in that
instantiation. No runtime wrapper is required. However, this is still a free
generic function: the declaration does not say that `put!` belongs to
`Cache`, does not place Cache's constraints in lexical scope, and does not give
the compiler a clean method-coherence boundary.

CLEAR therefore uses an owner-scoped implementation block:

```clear
STRUCT Cache<M: SHARED Map> {
  values: M,
  capacity: Int64,
}

IMPLEMENTATION Cache<M> {
  METHOD put!(MUTABLE self, key: M::Key, value: M::Value) RETURNS !Void ->
    WITH POLYMORPHIC self.values AS values {
      values[key] = value;
    }
  END

  METHOD transform<N>(self, fn: FN(M::Value) -> N) RETURNS []N ->
    # N is method-local; M is the owner binding.
  END
}
```

`IMPLEMENTATION Cache<M>` resolves the nominal `Cache` symbol, verifies that
Cache declares exactly one generic slot, and introduces the implementation-
scope name `M` for that slot. The binding is positional and inherits Cache's
declared constraint; it is not a concrete type application. A method repeats
only genuinely method-local parameters such as `N`.

A generic owner must supply exactly one implementation binder per declared
slot. `IMPLEMENTATION Cache` therefore reports the missing `<M>` with a fix,
and `IMPLEMENTATION Cache<M, K>` reports an arity error. A nongeneric owner uses
`IMPLEMENTATION User`. Concrete or conditional inherent specializations are
not part of the first milestone, so a visible nominal name such as `User`
cannot be smuggled into the binder list as a specialization.

This is analogous to Rust's `impl<T> Cache<T>`, Swift extensions, and Kotlin
class member scope, but it carries no inheritance or reference semantics. It
also provides a natural pair with protocol conformance:

```clear
IMPLEMENTATION Map<K, V> FOR SmallMap {
  # Map requirement implementations
}
```

An implementation block is compile-time organization only. It has no runtime
representation, allocation, pointer, or dispatch cost.

More precisely, an inherent implementation is sugar for owner-scoped
functions. `METHOD` supplies the receiver's nominal type, owner generic
bindings, constraints, visibility namespace, and dot-call eligibility:

```clear
IMPLEMENTATION Cache<M> {
  METHOD get(self, key: M::Key) RETURNS ?M::Value -> ... END
  METHOD put!(MUTABLE self, key: M::Key, value: M::Value) RETURNS !Void -> ... END
  METHOD drain!(TAKES self) RETURNS []M::Value -> ... END

  FN new(map: M, capacity: Int64) RETURNS Cache<M> -> ... END
}
```

Conceptually these lower to ordinary functions whose receiver is first:

```clear
FN Cache.get<M>(self: Cache<M>, key: M::Key) RETURNS ?M::Value -> ... END
FN Cache.put!<M>(MUTABLE self: Cache<M>, key: M::Key, value: M::Value)
  RETURNS !Void -> ... END
FN Cache.drain!<M>(TAKES self: Cache<M>) RETURNS []M::Value -> ... END
```

The source must still spell `self`, `MUTABLE self`, or `TAKES self`. Only its
type (`Cache<M>`) is inferred. Receiver ownership is part of CLEAR's API
contract and must not be hidden behind an implicit parameter. A `FN` inside an
implementation is owner-namespaced but has no receiver, so it serves as a
constructor or static operation. The emitted Zig may place these functions in
the generated struct namespace when that produces the cleanest code, but this
does not change their CLEAR semantics.

#### Function, method, UFCS, and file boundaries

Generic free functions remain a core language feature:

```clear
FN first<T>(values: []T) RETURNS ?T -> ... END
FN get<M: Map>(map: M, key: M::Key) RETURNS ?M::Value -> ... END
```

`FN` means free function regardless of whether it is generic. It is callable
by prefix syntax or a pipeline, but never by dot syntax:

```clear
get(map, key);       # valid FN call
map |> normalize;   # valid pipeline call
map.get(key);        # does not resolve to FN get
```

Only `METHOD` (plus compiler-owned intrinsic methods) is eligible for dot/UFCS
resolution. For user nominal types, `METHOD` is legal only inside the one
inherent `IMPLEMENTATION Owner<...>` block located in the exact source file that
defines `STRUCT Owner`:

```clear
# cache.clear
STRUCT Cache<M: Map> { values: M }

IMPLEMENTATION Cache<M> {
  METHOD get(self, key: M::Key) RETURNS ?M::Value -> ... END
  METHOD map<N>(self, fn: FN(M::Value) -> N) RETURNS []N -> ... END
}
```

The second method is generic in method-local `N`; generic methods are not
forbidden. The owner parameter `M` is inherited and cannot be redeclared.

Other files may call `cache.get(key)`, but may not add another method:

```clear
# cache_extensions.clear -- error
IMPLEMENTATION Cache<M> {
  METHOD debug(self) RETURNS String -> ... END
}
```

This is intentionally stricter than Rust traits, Swift/Kotlin extensions, or
Go's package-level method declarations. It prevents imported files from
changing a type's apparent API, keeps method lookup independent of imports,
and makes the defining file the complete review boundary for data plus
behavior.

Rules:

- at most one inherent `IMPLEMENTATION Owner<...>` block exists for a nominal
  type;
- it must have the same file identity as the primary `STRUCT Owner`;
- user code cannot declare inherent methods on built-in, foreign, imported, or
  protocol-only types;
- a protocol conformance block may live where the coherence rule permits, but
  its witness operations do not become inherent UFCS methods automatically;
- a top-level user `METHOD` is invalid in the new model. A same-file legacy
  declaration receives a fix that moves it into `IMPLEMENTATION Owner<...>` when
  its first parameter has one unambiguous nominal owner;
- `METHOD` prefix spelling may remain as migration-compatible UFCS and
  `clear fmt` canonicalizes it to `receiver.method(...)`; plain `FN` is never
  considered by dot-call fallback;
- if prefix lookup finds both a free `FN` and a legacy METHOD spelling, the
  compiler reports ambiguity and offers explicit prefix and dot alternatives;
- method names are keyed by `(owner nominal ID, method name)`, not by one
  global function-name table.

The implementation removes the former arbitrary MethodCall-to-FN fallback.
`METHOD` eligibility is now a checked semantic fact, while free `FN`
declarations remain prefix/pipeline-only.

Required diagnostics include:

```text
`get` is a free function, not a method of `Cache<M>`.

Use: get(cache, key)
```

```text
Cannot add methods to `Cache` from `cache_extensions.clear`.

`Cache` is defined in `cache.clear`; its inherent IMPLEMENTATION must be in
that file. Move `debug` to `cache.clear`, or keep it as a prefix FN.
```

```text
`METHOD debug` must belong to an IMPLEMENTATION block.

Cache is the unambiguous receiver type. Move this declaration into:
IMPLEMENTATION Cache<M> { ... }
```

#### Why not `CLASS` or `DATA` in an implementation block

`CLASS Cache<M> { DATA ... METHOD ... }` would group the same source nicely,
but `CLASS` conventionally implies reference identity, heap allocation,
inheritance, or virtual dispatch. None is intended here. Adding the keyword
would make CLEAR's value semantics harder to learn without solving a semantic
problem that `STRUCT` plus `IMPLEMENTATION` does not solve.

`DATA` must remain owned by the primary `STRUCT` declaration. Permitting an
extension-like `IMPLEMENTATION` to add fields would make layout depend on
imports and declaration order, breaking separate compilation and ABI
stability. If source locality later proves important, CLEAR may add this pure
syntax sugar:

```clear
STRUCT MapBox<M: Map> {
  DATA {
    values: M,
    capacity: Int64,
  }

  IMPLEMENTATION {
    METHOD length(self) RETURNS Int64 -> RETURN self.values.length(); END
  }
}
```

The parser must immediately desugar that form into the same `StructDef` and
owned `ImplementationDef` facts as separate declarations. It is deferred until
the separate form proves useful; two semantic models are not acceptable.

#### Generic-name and ownership diagnostics

- A generic parameter may not shadow a visible built-in, nominal type,
  protocol, associated type, owner parameter, or sibling parameter. If
  `STRUCT T { ... }` is visible, `FN foo<T>(...)` is a fixable error suggesting
  `ValueT`, `Item`, or another unused name.
- `IMPLEMENTATION Cache<M>` binds one local name for Cache's one owner slot and
  inherits the slot's complete constraint environment.
- A method may not redeclare an owner parameter:
  `IMPLEMENTATION Cache<M> { METHOD put<M>(...) }` is a fixable error.
- A free `FN foo<T>` remains a function for every admitted `T`; it never gains
  owner privileges merely because a nominal `T` exists.
- `IMPLEMENTATION T` for a bare unconstrained type parameter is illegal.
  Generic extension behavior belongs in a protocol default implementation.
- Inherent methods must be declared in the nominal type's defining file, not
  merely somewhere in its package. Protocol implementations retain the
  protocol-or-type ownership rule above but do not add inherent methods.

These rules make accidental "method for every T" declarations fail at the
declaration rather than producing confusing call-site behavior.

### Generic, opaque, and existential use

```clear
# Caller chooses one M. Static dispatch.
FN use<M: Map>(map: M) RETURNS Void -> ... END

# Producer chooses one hidden map type. Static dispatch.
FN makeMap() RETURNS some Map<String, User> -> ... END

# Runtime value may contain different map implementations. Dynamic dispatch.
FN inspect(map: any Map<String, User>) RETURNS Void -> ... END
```

No bare `Map` value type is permitted. A diagnostic offers `M: Map`,
`some Map`, or `any Map` based on context.

## Lists of Maps

The spelling must distinguish topology from erasure.

### Concrete homogeneous list

```clear
MUTABLE maps: []{String}User = [];
```

This is a list whose every element has the one concrete type
`{String}User`. It is not a list of arbitrary maps.

The compact `[]{}User` uses the default map key and is likewise concrete. It
means "list of default-key maps of User," not "list of any map." Explicit keys
are preferred in generic examples.

### Generic homogeneous list

```clear
FN inspectAll<M: Map<String, User>>(maps: []M) RETURNS Void ->
  # Every element has the same caller-selected concrete M.
END
```

This is zero-cost and should be the default answer to "a function that accepts
a list of any map implementation." One call may use locked maps and another
may use sharded maps, but one list instance has one element type.

### Heterogeneous runtime list

```clear
MUTABLE maps: []any Map<String, User> = [];
maps.append(GIVE localMap);
maps.append(GIVE customMap);
```

Each append performs a contextual existential conversion. The `any` keyword is
the explicit cost marker. The underlying values may have different sizes and
implementations, so each element uses a uniform existential representation.

This is the primary open-world library design, not a fallback. A library may
publish and own `[]any P`; a downstream package may define a new type, provide
a legal public `IMPLEMENTATION P FOR NewType`, and append its value without the
library being rebuilt around a new union variant. Exported conformance metadata
provides the witness and ownership operations at the conversion boundary.

The established counterparts are:

- Rust: `Vec<Box<dyn P>>` or another explicit owner around `dyn P`;
- Swift: `[any P]` using existential containers and witness tables;
- Go: `[]P`, where each interface value carries its concrete dynamic type and
  value and third-party types may satisfy the interface;
- Zig: a hand-built erased pointer/context plus function table, because Zig
  comptime interfaces alone do not create a heterogeneous runtime value.

CLEAR's `[]any P` is intentionally closest to modern Swift's explicit `any`,
while the ownership part is derived from CLEAR's binding semantics rather than
requiring every caller to spell `Box` or an erased context struct.

If and only if the set is intentionally closed and performance-sensitive, a
named union is available:

```clear
UNION UserMap {
  Local: {String}User,
  Sharded: {String}@sharded(8):writeLocked User,
}

MUTABLE maps: []UserMap = [];
```

The compiler must not recommend converting a public or extensible existential
API into a union merely because the currently visible concrete set is small.
That changes an open-world API into a closed-world API. A union suggestion is
appropriate only for a private/local declaration whose closed set is provable
and whose author asks for performance guidance.

### Capability-polymorphic heterogeneous list

Mixing local, locked, and versioned values is not ordinary type erasure because
the access protocol differs. The full target syntax reuses existing `SHARED`
semantics:

```clear
MUTABLE maps: []any SHARED Map<String, User> = [];
maps.append(GIVE lockedMap);
maps.append(GIVE versionedMap);

FOR erased IN maps DO
  WITH POLYMORPHIC erased AS map {
    # Access only through the scoped capability-aware alias.
  }
END
```

`any SHARED P` carries a runtime conformance witness and a capability-access
witness. It projects the concrete synchronization error at construction into
the existential's declared error surface. The compiler must not allow direct
field/index access that bypasses the gate.

The first existential milestone may support local `any P` before
`any SHARED P`; it must reject the latter clearly until capability witnesses,
cleanup, and error projection are complete. It must never accept it by erasing
the capability.

## Capability Semantics

### Capabilities remain in the concrete type

For an unconstrained-capability `MapBox<M: Map>`, these are different `M`
identities:

```clear
{String}User
{String}@shared:locked User
{String}@shared:versioned User
```

The `Map<String, User>` conformance is shared behavior, not type equality.
Generic substitution retains the full `MapTypeExpression` and its
`TypeCapabilities`.

### Protocols declare logical operations, not wrappers

The protocol says that a map can perform get/put/delete. The conformance
witness says how those operations are reached for a concrete capability:

- local/plain map: direct operation;
- whole-map lock: acquire scoped guard;
- versioned map: retryable snapshot/update;
- sharded map: key-routed per-shard operation;
- custom map: declared adapter.

This matters because a sharded map must not be lowered as one artificial global
lock merely to satisfy a generic `WITH` spelling. The witness carries an
operation-level `CapabilityPlan`, not just a method name.

### `SHARED` and `WITH POLYMORPHIC`

Existing `SHARED T` remains the way a function accepts a caller-selected
shared synchronization family. Protocol constraints compose with it:

```clear
FN update!<M: SHARED Map>(MUTABLE map: M, key: M::Key, value: M::Value)
  RETURNS !Void
  REQUIRES map: LOCKED | VERSIONED
->
  WITH POLYMORPHIC map AS writable {
    writable[key] = value;
  }
END
```

The type contract proves both map operations and that a shared capability is
present. The parameter-family contract narrows which shared access plans this
body admits. They are orthogonal facts internally. An unshared map fails while
forming the generic instantiation; it does not survive until the
`WITH POLYMORPHIC` body.

### Compound-state atomicity

An LRU cache changes more than its value map:

- the value map;
- a key-to-recency-node index;
- linked recency nodes;
- head and tail handles;
- size/capacity state.

Synchronizing only the value map cannot make eviction or promotion atomic. A
concurrent exact LRU therefore needs an outer gate over the complete LRU state:

```clear
FN get!<M: Map>(MUTABLE cache: SHARED LruCache<M>, key: M::Key)
  RETURNS !?M::Value
->
  WITH POLYMORPHIC cache AS state {
    # Lookup and recency mutation occur in one capability-selected region.
  }
END
```

The capability audit must diagnose a synchronized `values` map combined with
unprotected mutable recency state when the cache crosses a concurrency
boundary. It should suggest either:

- synchronize the complete `LruCache` binding;
- use a local map inside the synchronized outer cache to avoid double locking;
- implement an explicitly sharded/per-partition LRU protocol.

The example must not imply that `Map@locked + plain head/tail` is safe.

## LRU Cache Acceptance Design

The proving example should implement an exact O(1) LRU, not a list scan labeled
as an LRU.

Conceptual storage:

```clear
STRUCT LruNode<K> {
  key: K,
  previous: ?LruNode<K>@link,
  next: ?LruNode<K>@link,
}

STRUCT LruCache<M: Map> {
  values: M,
  recency: {M::Key}LruNode<M::Key>@node,
  head: ?LruNode<M::Key>@link,
  tail: ?LruNode<M::Key>@link,
  capacity: Int64,
}
```

The value map remains the caller-selected `M`; the internal recency index maps
the same key type to compiler-managed nodes. This avoids requiring callers to
construct a map whose value is an internal cache entry.

Required operations:

- `new(capacity, map)` with positive capacity validation;
- `get!` returning `?M::Value` and promoting a hit;
- `put!` replacing or inserting and promoting;
- `delete!` unlinking in O(1);
- tail eviction in O(1);
- `length`, `empty?`, and deterministic self-check output.

Capability matrix:

1. Plain/local cache and map.
2. Outer `@shared:locked` cache accessed through `SHARED` and
   `WITH POLYMORPHIC`.
3. Outer `@shared:writeLocked` cache through the same body.
4. Outer `@shared:versioned` cache through the same body, with retry-safe work.
5. A sharded map instantiation for generic/type preservation, with a safe outer
   policy and a diagnostic if the combination merely double-synchronizes.
6. At least two value types and two key types.

The implementation should print PASS only after verifying promotion order,
replacement, deletion, eviction, optional misses, and concurrent access.

## Type Checking and Inference

### Generic bodies are checked once against constraints

When checking `FN f<M: Map>`, the type environment contains an abstract
`ProtocolType(M, Map)` with:

- `M::Key` and `M::Value` projections;
- the Map operation set;
- declared effects and mutability;
- an abstract capability variable retaining any explicit bounds.

Indexing `M` is admitted because Map supplies that operation. Calling an
undeclared method is rejected in the generic body even if one current concrete
map happens to have it.

### Call-site inference

Inference extends the existing recursive substitution:

1. Bind concrete type arguments from parameters.
2. Resolve each required conformance.
3. Bind associated projections from the witness.
4. Solve equality constraints.
5. Validate capability-family requirements.
6. Produce one `GenericInstantiation` fact used by annotation and MIR.

Inference does not strip runtime capabilities from a type parameter constrained
as a collection. Capability stripping remains valid only for payload-generic
positions whose contract explicitly ignores wrappers.

### Invariance

Mutable `Map<K, V>` and `List<T>` are invariant. A map of `Admin` is not a map
of `User` when mutation is possible. Read-only covariance may be introduced
later through a distinct read protocol; it is not inferred from method usage.

### Constraint failure location

Prefer the earliest declaration that made the contradiction unavoidable:

- malformed protocol: protocol declaration;
- incomplete explicit conformance: `IMPLEMENTATION P FOR T` declaration;
- concrete type violates bound: generic instantiation;
- generic body uses undeclared operation: operation in generic body;
- existential cannot represent protocol: `any` type annotation.

## Diagnostic Contract

Diagnostics are part of the feature, not post-implementation polish.

### Wrong generic argument

```text
Cache<M> requires M to satisfy SHARED Map, but User is an unshared struct with
no Map conformance.

Expected: a shared Map<Key, Value> or another shared type implementing it
Example:  Cache<{String}@shared:locked User>
```

### Missing conformance requirements

Report one grouped error:

```text
SmallMap<K, V> declares Map<K, V> but does not satisfy 2 requirements:
  - delete!(MUTABLE Self, K) RETURNS !Bool: missing
  - get(Self, K) RETURNS !?V: found RETURNS ?V (missing fallible effect)
```

### Heterogeneous list mistaken for generic list

```text
This []M list already inferred M as {String}User, but the appended value is
{String}@sharded(8):writeLocked User.

Use one concrete map type, a named UNION for a closed set, or
[]any Map<String, User> for explicit runtime dispatch.
```

### Capability loss

```text
The Map conformance is valid, but this conversion would erase
@shared:versioned access semantics. Use a SHARED generic parameter or
any SHARED Map<...> and access it with WITH POLYMORPHIC.
```

### Zig shielding

Generated Zig may contain internal `comptime` assertions, but a user should not
normally see `@hasDecl`, `@typeInfo`, `anytype`, or a Zig instantiation trace.
If Zig rejects an emitted conformance that CLEAR accepted, report it as a
compiler bug with the compact CLEAR witness summary.

## Zig Lowering

### Static generic path

Conceptually:

```zig
fn Cache(comptime M: type) type {
    return struct { values: M };
}

fn put(
    comptime M: type,
    cache: *Cache(M),
    key: ClearMapFacts(M).Key,
    value: ClearMapFacts(M).Value,
) !void {
    return ClearMapAdapter(M).put(&cache.values, key, value);
}
```

`ClearMapFacts(M)` and `ClearMapAdapter(M)` are generated/canonical compiler
helpers. The frontend has already validated them. They should be evaluated once
per `(protocol, concrete type, capability plan)` and reused.

For a simple concrete map, Zig should inline the adapter to the same operation
as hand-written Zig. For a sharded map, the adapter retains key routing. For a
versioned map, it retains retry semantics.

### Protocol operations in MIR

Do not lower constrained operations directly to string templates. Introduce a
typed operation carrying:

```text
ProtocolCall
  protocol_id
  requirement_id
  receiver
  args
  static_witness_id | existential_witness
  capability_plan
  ownership_contract
  result_type
```

Static witness IDs disappear during Zig emission. Existential witnesses lower
to vtable calls.

### Opaque path

`some P` lowers to the one concrete return type selected by the function. It
does not allocate or create a witness table. Cross-module metadata records the
opaque identity without exposing its implementation spelling.

### Existential path

`any P` lowers only when requested:

```zig
const AnyP = struct {
    data: *anyopaque,
    witness: *const WitnessTable,
    ownership: OwnershipOps,
};
```

The exact layout is an implementation decision, but the first implementation
should favor simple deterministic ownership over a complicated small-object
optimization. `any` already signals indirection. Later inline storage is
permitted only if it does not change semantics or hide copies.

The witness table contains only requirements actually callable on the
existential plus cleanup/copy/move operations required by its ownership
contract. Associated types used by an existential must be fixed by the
existential type, such as `any Map<String, User>`.

### Controlling specialization cost

- Intern semantic type and conformance keys.
- Emit one generic instantiation per canonical key, not per spelling.
- Share adapters across functions.
- Outline large code that does not depend on `T`.
- Detect recursive instantiation cycles before Zig.
- Track per-declaration and whole-program instantiation counts.
- Warn on unusually high code growth and show the concrete type fanout.
- Add generated-Zig tests asserting no vtable on static/opaque paths.

Incremental Zig compilation improves rebuilds but does not remove first-build
analysis, code size, or pathological-instantiation concerns.

## Protocol Evolution and Package Boundaries

- Adding a required method is a source-breaking protocol change unless it has
  a default implementation.
- Removing a requirement may change overload/constraint selection and is also
  versioned.
- Associated type order in primary syntax is API metadata.
- Public conformances are exported in module semantic metadata.
- Private conformances do not satisfy constraints in importing packages.
- Conformance identity never depends on import order.
- An ABI C declaration cannot expose `some`, `any`, or unconcretized generics.
- Zig ABI boundaries may use generated adapters, but their concrete layout must
  be explicit in emitted module metadata.

## Implementation Phases

### Phase 1: Constraint representation and grammar — implemented for inline bounds

- Replace `type_params: String[]` with typed generic parameter declarations.
- Parse inline `T: P & Q` bounds as sugar for declaration contracts; extend
  contracts with `REQUIRES T IS_A P` and `COMPTIME_REQUIRES expression`.
- Parse protocol associated projections. Do not add `WHERE`.
- Parse `IMPLEMENTATION Owner<T, ...> { METHOD ... }` into an owner-scoped AST
  node. Binder arity must equal the owner's declared generic arity; a
  nongeneric owner omits the list. It may not contain data fields or concrete
  specialization arguments.
- Preserve the defining file identity on nominal declarations and reject an
  inherent implementation whose file identity differs.
- Add immutable `ProtocolDecl`, `ProtocolRequirement`, `TypeProjection`,
  `ConstraintSet`, and `ConformanceWitness` facts.
- Preserve source ranges for every constraint and projection.
- Do not change runtime lowering yet.

### Phase 2: Intrinsic Map protocol — implemented

- Register language-defined `Map<Key, Value>`.
- Derive intrinsic witnesses from `MapTypeExpression`.
- Resolve `M::Key` and `M::Value`.
- Type-check map indexing and the stable map method set in a constrained body.
- Resolve owner generic slots and inherited constraints inside inherent
  implementation blocks; reject shadowing and method-local redeclaration.
- Replace arbitrary MethodCall-to-FN fallback with checked METHOD eligibility;
  keep FN prefix calls and pipelines unchanged.
- Reject `Cache<User>` with the final diagnostic.

This phase proves the design without requiring arbitrary user protocols.

### Phase 3: Static witness lowering — implemented

- Carry resolved witnesses into typed facts and MIR.
- Add `ProtocolCall` and canonical adapter lowering.
- Preserve capability and ownership plans.
- Compare emitted Zig for constrained versus concrete map functions.
- Require no runtime witness table in this phase.

### Phase 4: Nested capability polymorphism — implemented for static protocols

- Recognize a constrained field such as `cache.values` as originating from `M`.
- Preserve M's exact nested capability chain at instantiation.
- Extend `SHARED`/`WITH POLYMORPHIC` admission and error projection.
- Handle sharded operation-level access without synthesizing a global lock.
- Add capability-loss and compound-state diagnostics.

### Phase 5: LRU proving example — implemented

- Implement the O(1) LRU described above.
- Exercise local, locked, write-locked, and versioned outer policies through
  one generic body.
- Exercise more than one concrete map type and key/value combination.
- Add deterministic examples, transpile tests, and fuzz matrices.
- Benchmark against a concrete specialized implementation.

### Phase 6: User protocols and explicit conformance — implemented locally

- Parse `PROTOCOL` and conformance `IMPLEMENTATION P FOR T` blocks on top of
  the already working inherent implementation representation.
- Reject generic orphan conformances and layout additions.
- Check complete conformance at the declaration.
- Add package coherence and visibility.
- Add default methods only after requirement dispatch is stable.
- Keep implicit conformance limited to compiler-owned structural types.

### Phase 7: Opaque `some` — deferred

- Permit parameter/return positions where one concrete identity is provable.
- Require the same concrete return type on every path.
- Preserve cross-module opaque identity.
- Prove zero allocation and static dispatch in generated Zig.

### Phase 8: Existential `any` — deferred

- Implement explicit local existential containers and ownership witnesses.
- Support heterogeneous `[]any P`.
- Require associated types used by methods to be fixed.
- Export public conformance witnesses so downstream implementations can enter
  library-owned `[]any P` collections without editing the library.
- Restrict union suggestions to provably closed, non-public declarations.
- Add capability-aware `any SHARED P` only after scoped access, cleanup, and
  error projection are complete.

## Testing Strategy

### Compiler integration tests

Use CLEAR source strings and run parser, annotation, MIR verification, and Zig
emission for:

- constrained struct/function declarations;
- associated projections in parameters, returns, fields, and nested types;
- generic inference through `Cache<M>`;
- complete grouped conformance diagnostics;
- exact capability preservation;
- static/opaque/existential lowering distinctions;
- ownership and cleanup across return, collection, BG, and error paths.

The declaration/coherence suite must additionally cover:

- duplicate `Cache` declarations whose parameter names, arities, or bounds
  differ, both within one file and across required files;
- wrong generic arity in fields, function parameters, returns, nested
  collections, protocol arguments, and implementation headers;
- `IMPLEMENTATION Cache<M>` in the defining file succeeds, binds M to Cache's
  first generic slot, and inherits every owner bound;
- missing, extra, duplicate, shadowing, or otherwise undeclared implementation
  binders fail at the implementation header or first invalid use;
- a second inherent implementation, an implementation in another file, an
  implementation for an unknown/non-nominal owner, and any implementation that
  adds data all fail at their declarations;
- owner parameter redeclaration and method-local parameter shadowing fail with
  rename fixes;
- generic `FN foo<T>` works through prefix calls and pipelines;
- `value.foo()` does not resolve to `FN foo(value)` and offers the exact prefix
  rewrite;
- an owner `METHOD foo` works through dot syntax from other files;
- legacy same-file top-level METHOD receives an IMPLEMENTATION migration fix,
  while a foreign-file or built-in extension is rejected;
- identical method names on two locally owned nominal types do not conflict;
- ambiguous legacy prefix METHOD/FN calls report both candidates and offer
  explicit dot/prefix fixes.

Every negative case needs a diagnostic snapshot containing the primary source
range, the relevant prior declaration range, the violated rule in plain
language, and at least one actionable correction. Apply every advertised fix,
reparse the result, and require the targeted diagnostic to disappear without
introducing a cascade. Tests should assert structured diagnostic codes and
ranges first, with concise rendered-message snapshots as the user-facing
oracle.

### Transpile tests

- Concrete and constrained implementations produce identical results.
- Static generic paths contain no runtime witness call.
- `some` retains one hidden concrete type.
- `any` permits heterogeneous values and performs correct cleanup.
- `SHARED`/`WITH POLYMORPHIC` works across supported sync families.
- LRU behavior covers hit promotion, replacement, deletion, eviction, misses,
  and concurrent callers.

### Fuzz matrices

Cross at minimum:

- protocol kind: Map, List, Set, user protocol;
- concrete shape: inline collection, nominal adapter, generic wrapper;
- capability: plain, local, shared, locked, writeLocked, versioned, sharded;
- nesting: field, tuple, optional, fallible, future, list, map;
- boundary: argument, return, field, collection element, BG capture;
- dispatch: static, opaque, existential, named union;
- ownership: affine, shared, multiowned, node/link where legal;
- expected outcome: pass, constraint error, capability error, escape error.

### Performance and compile-time gates

- Static constrained LRU within measurement noise of the concrete version.
- No allocation attributable solely to `T: Protocol` or `some Protocol`.
- Existential overhead measured and documented rather than optimized away in
  the test.
- Instantiation count and emitted Zig size recorded for the matrix.
- Geometric generic nesting terminates within the frontend resource budget.
- Mutants removing a requirement, witness, capability, cleanup action, or
  equality check must be killed.

## Full-Roadmap Acceptance Criteria

The implemented static milestone satisfies the zero-cost items below through
the generic cache, protocol transpile tests, and bounded fuzz matrices. Items
that mention `some`, `any`, heterogeneous values, or cross-package witnesses
remain acceptance criteria for the explicitly deferred phases 7 and 8.

The design is ready to implement fully when all of these are true:

1. `Cache<{String}@shared:locked User>` is a normal well-formed type.
2. `Cache<User>` fails at the instantiation with one actionable error.
3. A body constrained by `M: Map` can use `M::Key`, `M::Value`, indexing, and
   stable map methods without knowing M's representation.
4. Capabilities on M survive inference, fields, calls, returns, and MIR.
5. Static generic dispatch emits no vtable or existential allocation.
6. Sharded maps retain per-key/per-shard behavior.
7. The O(1) LRU uses one body across local and multiple synchronized outer
   policies through `SHARED` and `WITH POLYMORPHIC`.
8. The compiler rejects the false claim that a synchronized value map protects
   unsynchronized LRU metadata.
9. `[]M` is homogeneous and zero-cost.
10. `[]any Map<String, User>` is explicitly heterogeneous and dynamically
    dispatched; a downstream package can add a legal implementation and store
    it in a library-owned list without editing a union in that library.
11. `[]any SHARED Map<String, User>` cannot land until capability-aware
    witnesses and scoped access are sound.
12. All changed executable Ruby lines have 100% line coverage, with integration
    and fuzz tests preferred over targeted unit tests.
13. Generated Zig is reviewed against hand-written Zig for runtime work,
    allocation, cleanup, and analysis duplication.
14. `IMPLEMENTATION Cache<M>` binds Cache's owner slot as local `M` once;
    methods inherit its contracts and cannot accidentally use or redeclare an
    unrelated generic name.
15. A generic parameter that shadows `STRUCT T`, another visible nominal type,
    a protocol, an owner parameter, or a built-in produces a fixable error.
16. A fully qualified nominal name has one declaration and one generic arity;
    bounds and parameter names never overload it.
17. A user nominal type has at most one inherent `IMPLEMENTATION`, in the same
    file as its `STRUCT`, and callers in other files can use but not extend its
    methods.
18. Generic `FN` remains legal and prefix/pipeline-only. Only checked `METHOD`
    declarations and compiler-owned intrinsics participate in dot/UFCS lookup.
19. Duplicate-name, wrong-arity, wrong-file, illegal-extension, FN-as-method,
    and shadowing failures each have readable ranged diagnostics whose fixes
    reparse successfully.

## References

- Rust Reference: [Traits](https://doc.rust-lang.org/stable/reference/items/traits.html),
  [trait objects](https://doc.rust-lang.org/reference/types/trait-object.html),
  and [`impl Trait`](https://doc.rust-lang.org/stable/reference/types/impl-trait.html).
- Rust Compiler Development Guide:
  [Monomorphization](https://rustc-dev-guide.rust-lang.org/backend/monomorph.html).
- Swift language guide: [Protocols](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/),
  [Generics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/),
  and [Opaque and Boxed Protocol Types](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/opaquetypes/).
- Swift compiler documentation:
  [Existential Types and Performance](https://docs.swift.org/compiler/documentation/diagnostics/existential-type/).
- Go specification: [Interface types and type constraints](https://go.dev/ref/spec),
  and the Go team guidance [When To Use Generics](https://go.dev/blog/when-generics).
- Zig language reference: [comptime, anytype, and type reflection](https://ziglang.org/documentation/master/).
- Zig 0.16 release notes:
  [Incremental Compilation](https://ziglang.org/download/0.16.0/release-notes.html#Incremental-Compilation).
- Kotlin documentation: [Generics](https://kotlinlang.org/docs/generics.html),
  [Interfaces](https://kotlinlang.org/docs/interfaces.html), and
  [Delegation](https://kotlinlang.org/docs/delegation.html).
