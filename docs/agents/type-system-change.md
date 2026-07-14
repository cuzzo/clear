# Inline Pivot Type Architecture

Status: approved direction with the normative revisions in this document

Core domain: type syntax, recursive type representation, collection topology,
memory layout, stream completion, and polymorphic synchronization

## Purpose

This document turns the Inline Pivot proposal into an implementable CLEAR
design. It records the current compiler behavior, resolves contradictions in
the proposal, defines one canonical reading order, and provides a staged
implementation plan.

This is a type-system replacement, not a parser-only syntax change. The current
compiler stores a mostly flattened `TypeShape`, reconstructs child types from
symbols, and overlays collection and capability facts separately. Inline Pivot
requires a recursive type algebra in which every collection, tense, generic,
and capability has one explicit node and one owner.

The design must preserve these project constraints:

- deterministic parsing with no speculative backtracking;
- no second semantic type model or permanent compatibility path;
- named typed records rather than hashes, tuple protocols, or `T.untyped`;
- complete ownership, cleanup, escape, MIR, and Zig lowering for every new
  shape before that shape is accepted generally;
- source-based tests that compile or annotate CLEAR strings;
- 100% line coverage for changed executable lines;
- automatic migration only when the old and new types are semantically
  equivalent.

## Current-State Audit

The proposal overlaps several implemented features, but the current surface
and representation differ materially.

| Concern | Current CLEAR | Current implementation consequence |
| --- | --- | --- |
| Fixed array | `T[N]` | `TypeShape` stores one array flag, capacity, and raw element symbol. Nested arrays are recovered by reparsing raw symbols. |
| Dynamic list | `T[]@list`; `List[]` constructor | Collection kind is a capability overlay on an array shape. |
| Pool | `T[N]@pool` | A fixed-capacity generational pool with `Id<T>` handles; this cannot disappear from the new collection model. |
| Set | `T[]@set`; `Set[]` constructor | Set is also a collection capability overlay. |
| Map | `HashMap<V>` or `HashMap<K, V>` | One-argument maps are String-keyed, not Symbol-keyed. |
| Optional | `?T`; optional container uses `?(T[])` | `?T[]` currently means a collection of optional elements. |
| Fallible | `!T` | The error set is implicit; it is not equivalent to an arbitrary `Result<T, E>`. |
| Future | `~T` | A tense wrapper around one raw child type. |
| Streams | `~T[N]`, `~?T[]`, legacy `~T[?]`, `~T[INF]` | Finite stream completion is currently encoded through optionality, which prevents a finite stream from losslessly yielding optional values. |
| Capabilities | `@versioned`, `@indirect`, `@sharded(N):locked`, and others | Capability facts are flattened into top-level and element-level slots. They cannot describe an arbitrary nested layer. |
| Union | named `UNION Name { ... }` | There is no structural `Union<A, B>` type. An uppercase generic spelling is currently only a nominal generic instance. |
| Tuple | `Tuple<A, B>` with contextual list literal `[a, b]` | Tuple types and positional access already exist; a distinct `Tuple{...}` literal does not. |
| Multidimensional arrays | nested `T[N][M]` spellings | The backend models arrays recursively as arrays of arrays, not one flat rank/stride layout. |

Relevant implementation boundaries are:

- `compiler/ruby/ast/parser.rb`: token-level type parsing and capability
  attachment;
- `compiler/ruby/ast/type.rb`: `TypeShape`, compatibility, ownership/cleanup
  classification, stream classification, and Zig type spelling;
- `compiler/ruby/annotator`: type registration, inference, coercion, stream
  yield inference, capabilities, and collection operations;
- `compiler/ruby/mir`: ownership, cleanup, async boundaries, indexing, and
  literal lowering;
- `compiler/ruby/backends`: recursive layout rendering and code generation;
- formatter, LSP, diagnostics, fix rewriter, FactMine, and ruby-to-clear:
  source spelling and type-fact consumers.

The completed `TypeShape` composition work is a useful phase boundary, but it
is not the final representation needed here. Adding recursive Inline Pivot
nodes beside the current flags would recreate the dual-source-of-truth problem
that the composition work removed.

## Normative Revisions to the Input Specification

The following revisions are required for a coherent language.

### 1. All collection layers read outermost to innermost, left to right

The leftmost layer is the first access operation and therefore the outermost
container. The layer closest to the payload is the innermost container.

```clear
[List]{Symbol}T       # list[index][symbol] -> T
{Symbol}[List]T       # map[symbol][index] -> T
{Symbol}{Int64}T      # map[symbol][integer] -> T
```

This preserves the mixed-layout examples and makes declaration order match
access order. It replaces the contradictory map rule that described the
rightmost map as outermost. Consequently, the type for a Symbol-keyed outer map
and Int64-keyed inner map is `{Symbol}{Int64}T`, not `{Int64}{Symbol}T`.

### 2. `[Set]T` is canonical

The proposal describes both braces and brackets for sets but only demonstrates
`[Set]T`. Braces are reserved for associative key layers; `[Set]T` is the
canonical set spelling. Sets do not support positional indexing even though
their layout constructor uses brackets.

### 3. Existing capability names remain canonical

The new syntax changes attachment location, not the established capability
vocabulary.

| Proposed spelling | Canonical CLEAR spelling | Reason |
| --- | --- | --- |
| `@mvcc` | `@versioned` | Already implemented with `SNAPSHOT` semantics. `@mvcc` may be accepted temporarily as a fixable alias. |
| `@boxed` | `@indirect` | Stable heap indirection is already represented by `@indirect`. |
| `@shared:striped` | `@sharded(N):locked` or `@sharded(N):writeLocked` | Shard count and lock policy must remain explicit. There is no safe inferred `N`. |

No auto-fix may invent a shard count.

### 4. Capacity hints are not nominal identity

`[List(10)]T` and `[Set(10)]T` request initial allocation capacity. The `10`
does not participate in assignment compatibility, function overload identity,
or equality of semantic types. It is retained as construction metadata at an
allocation site.

A capacity hint on a parameter, return type, type alias, or field is rejected:
there is no durable guarantee that a value still has that capacity. A binding
declaration with an initializer is an allocation site and may carry the hint;
the hint is transferred to that initializer. The canonical parameter type is
`[List]T` or `[]T`.

Fixed `[10]T`, bounded stream `[~10]T`, and pool `[Pool(10)]T` capacities do
participate in semantics because they constrain topology or cardinality.

### 5. Pool remains a first-class inline layout

The existing generational pool is a real CLEAR collection with safety and
performance behavior not supplied by arrays, lists, sets, or maps. Its Inline
Pivot spelling is:

```clear
[Pool(1000)]Enemy
```

The capacity is mandatory and pool indexing continues to use `Id<Enemy>` and
produce `?Enemy`.

### 6. Finite stream completion is not item optionality

The current `~?T[]` convention uses optionality both for end-of-stream and for
the item type. That makes a finite stream of `?T` impossible to consume without
losing information.

Inline Pivot separates the stream state from its item:

```clear
[~]T          # finite, dynamically bounded stream of definite T
[~]?T         # finite stream whose yielded item is ?T
[~10]T        # finite stream with a maximum cardinality of 10
[~INF]T       # declared non-terminating stream
[]~T          # list of futures
~[]T          # future resolving to a list
```

Internally and at the explicit consumer boundary, a finite stream advances as
`StreamStep<T> = Item(T) | Closed`. It must not use `?T` as the completion
sentinel. Pipeline operators may hide `StreamStep`, but a direct `NEXT` on a
finite stream must expose a closed branch. `NEXT` on a single future remains a
different operation returning its payload.

The integer in `[~10]T` bounds the number of yielded items; it is not the
channel/ring-buffer capacity. Buffer sizing remains construction/runtime
policy. Exceeding a declared maximum is rejected statically when provable and
checked at runtime otherwise.

### 7. Structural `Union<A, B>` is not assumed

CLEAR currently has named tagged unions declared with `UNION`; it does not have
an anonymous structural union constructor. Treating `Union<String, Int64>` as
already defined would silently produce an ordinary nominal generic and skip
variant/tag semantics.

The stream work therefore uses existing named unions:

```clear
UNION TextOrInteger {
  Text: String,
  Integer: Int64
}

values = BG STREAM: ?TextOrInteger {
  YIELD TextOrInteger{ Text: "one" };
  YIELD NIL;
  CLOSE;
};
```

Anonymous structural unions may be designed later, but are not smuggled into
this change through generic syntax.

### 8. The capability limit and example are corrected

The proposed rule says that more than three separate `@` sites is an error and
that a joined chain such as `@shared:locked` counts as one site. Therefore a
type with exactly three capability sites is legal under that rule. The example
claiming otherwise is incorrect.

This design retains the hard limit of three capability-bearing nodes. A fourth
site is the compile error:

```clear
[List]@local{Symbol}@versioned[List]@sharded(8){Int64}@shared T
#       1                  2                     3              4 -> error
```

The compiler also emits an earlier readability warning for a type with more
than six explicit access obligations (future, fallible, optional, snapshot,
lock, ownership unwrap, or stream-close branch). The warning does not change
type semantics.

## Canonical Surface Syntax

### Linear and set layouts

| Type | Meaning |
| --- | --- |
| `[10]T` | Inline fixed array of exactly ten `T` values. |
| `[List]T` | Dynamic contiguous list of `T`. |
| `[]T` | Canonical shorthand for `[List]T`. |
| `[List(10)]T` | List construction with initial capacity ten; allocation-site only. |
| `[Set]T` | Default dynamic hash set of `T`. |
| `[Set(10)]T` | Set construction with initial capacity ten; allocation-site only. |
| `[Pool(1000)]T` | Fixed-capacity generational pool. |

`T[]` is legacy syntax during migration and is not retained as a second
canonical form.

### Multidimensional layouts

```clear
[10, 5]T
[List, List]T
[10, List]T
```

A comma-separated rank is one rectangular layout node:

- fixed dimensions use one contiguous flat block;
- dynamic dimensions use a flat buffer plus shape and stride metadata;
- every row has the same extent for a given axis;
- resizing a non-final axis may relocate the flat buffer and is O(total
  elements);
- `grid[x, y]` is canonical indexing;
- `grid[x][y]` is permitted as sugar only if the first operation produces a
  compiler-owned borrowed row view with a proven lifetime. It never changes the
  representation into an array of pointers.

Jagged collections are written as nested collection nodes, not a rank:

```clear
[][List]T       # list whose elements are independent lists
```

`[List, List]T` and `[][List]T` are intentionally different types.
Only integer and `List` dimensions participate in a comma-separated rank.
`Set` and `Pool` must be the sole entry in their layer because neither denotes
a rectangular axis.

### Maps and nesting

```clear
{Symbol}T
{Int64}T
{Symbol}{Int64}T
{}T
{}{}T
```

`{}T` is shorthand for `{Symbol}T`, and `{}{}T` is shorthand for
`{Symbol}{Symbol}T`. Mixed explicit/default map layers such as `{}{Int64}T`
are rejected with an auto-fix to `{Symbol}{Int64}T`; `{Int64}{}T` is fixed to
`{Int64}{Symbol}T`.

`{Symbol, Int64}T` is invalid. A comma denotes dimensions only inside a linear
rank. Separate map layers are required because each key is a distinct lookup:
`{Symbol}{Int64}T`.

This is a deliberate change from the current one-argument `HashMap<V>`, whose
key is String. Migration must preserve behavior:

```clear
HashMap<Value>          -> {String}Value
HashMap<Int64, Value>   -> {Int64}Value
```

It must not rewrite current `HashMap<Value>` to `{}Value`, because that would
change String keys to Symbol keys.

Map key types must satisfy a registered `Hashable + Equality` contract.
Collection, stream, fallible, and optional key nodes are rejected unless a
future language feature explicitly supplies those contracts.

### Mixed topology

The left-to-right rule applies without exceptions:

```clear
[List]{Symbol}T     # collection[0][:key]
{Symbol}[List]T     # collection[:key][0]
[10, 5]{Symbol}T   # collection[x, y][:key]
{Symbol}[10, 5]T   # collection[:key][x, y]
```

### Tenses

Tenses are unary type constructors and bind to the complete type immediately
to their right:

```clear
?[]T       # optional list of definite T
[]?T       # definite list of optional T
!{Symbol}T # fallible map
{Symbol}!T # map whose values are fallible
~[]T       # future list
[]~T       # list of futures
```

Parentheses remain available for readability but are not needed to repair an
ambiguous precedence rule. Prefix constructors build a type tree directly.
Repeated identical tenses on the same node (`??T`, `!!T`, `~~T`) are errors.

### Capabilities

A capability chain immediately follows the exact node it modifies:

```clear
{Symbol}@versioned[]T
{Symbol}[]@versioned T
[]T@indirect
[List]@local {Symbol}@shared:locked T
```

Whitespace is insignificant. The formatter inserts a space after a capability
chain when needed to make the following node visually distinct.

Capability dimensions remain typed and orthogonal. Duplicate ownership, sync,
layout, or collection-topology modifiers on one node are errors. Applicability
is validated against that node, not against the entire flattened type:

- `@versioned` on a map version-controls that map only;
- `@local` on a list constrains that list's scheduler visibility;
- `@indirect` on `T` boxes the payload values, not the surrounding list;
- `@soa` applies only to a compatible struct collection layer;
- `@sharded(N)` applies only to a sharded collection/map layer.

Top-level capability polymorphism remains possible, but nested capabilities
cannot simply be erased. A function that traverses a list of versioned maps
must either name that topology or declare a capability-polymorphic layer. The
annotator must never pretend that nested synchronization is a top-level wrapper.

## Grammar

The parser should implement a predictive grammar equivalent to the following.
It must not parse a raw type string with regular expressions and then recover
children later.

```text
type             := tense_type

tense_type       := tense tense_type
                  | layered_type

tense            := "?" | "!" | "~"

layered_type     := layer layer_capabilities? layered_type
                  | atom atom_capabilities?
                  | "(" type ")"

layer            := linear_layer
                  | map_layer
                  | stream_layer

linear_layer     := "[" linear_dims "]"
linear_dims      := linear_dim ("," linear_dim)*
linear_dim       := integer
                  | "List" ("(" integer ")")?
                  | "Set" ("(" integer ")")?
                  | "Pool" "(" integer ")"
                  | empty

map_layer        := "{" map_key? "}"
map_key          := type

stream_layer     := "[" "~" (integer | "INF")? "]"

atom             := TYPE_ID generic_args?
                  | function_type
                  | tuple_type

generic_args     := "<" type ("," type)* ">"
tuple_type       := "Tuple" "<" type ("," type)* ">"

layer_capabilities := capability_chain
atom_capabilities  := capability_chain
capability_chain   := capability (":" capability)*
```

The real implementation should use typed parse results for dimensions,
layers, capability sites, and source spans. Error recovery must advance to a
known delimiter and remain linear in token count. The grammar has no reason to
backtrack.

## Recursive Semantic Model

`TypeShape` should become an immutable recursive algebra. Conceptually:

```text
TypeExpr =
  Named(name, generic_args)
  Function(params, result, effects)
  Tuple(items)
  Optional(inner)
  Fallible(inner, error_set)
  Future(inner)
  Linear(kind, dimensions, item, allocation_hint, capabilities)
  Map(key, value, capabilities)
  Stream(cardinality, item, capabilities)
```

Capabilities and placement remain separate typed concepts, but capability
attachment is stored per eligible node rather than in one top-level record plus
one element record. Each semantic node has a stable ID/fingerprint independent
of source spelling and Zig rendering.

Required invariants:

- there is exactly one semantic shape tree;
- child types are `TypeExpr` values, never raw Symbols requiring reparsing;
- canonical printing walks the tree; it does not read the original raw string;
- compatibility, cleanup, copyability, escape class, slot size, and Zig/MIR
  lowering are exhaustive visitors over the same variants;
- new variants cannot silently fall through as user structs;
- allocation hints are excluded from semantic identity where specified;
- type-tree traversal is iterative or depth-guarded.

The current boolean combination (`array`, `map`, `optional`, `tense`,
`generic_instance`) is not extended with more booleans. That representation
cannot express arbitrary nested capability sites safely.

## Monadic and Nominal Generic Boundary

Inline Pivot is canonical for compiler-known collection and tense families.
Nominal generics remain available for user abstractions and shapes that do not
have an equivalent Inline Pivot form.

Safe canonical auto-fixes include:

```text
Option<T>       -> ?T
Future<T>       -> ~T
List<T>         -> []T
Set<T>          -> [Set]T
HashMap<K, V>   -> {K}V
```

They are allowed only when these names resolve to compiler-owned standard
types, not user declarations with coincidentally matching names.

`Result<T, E>` is not automatically rewritten to `!T` today. CLEAR's `!T`
does not encode an arbitrary explicit `E`, so that rewrite can discard type
information. It becomes fixable only after typed error sets make the two forms
provably equivalent.

Mixed syntax such as `{Symbol}[]Result<Option<T>, E>` receives a diagnostic if
the generic subtree is a compiler-known monadic/container family. The fix is
offered only if every node has an exact Inline Pivot equivalent. Otherwise the
diagnostic recommends a fully nominal spelling without changing code.

Ordinary generic payloads remain legal:

```clear
[]Id<User>
{Symbol}Page<Row>
```

The rule is about duplicate monadic/container vocabularies, not a blanket ban
on generic values inside collections.

## Type Complexity Budget

The compiler enforces limits both for readability and for compiler safety.

1. A type may contain at most three capability-bearing nodes. A joined chain
   on one node counts once.
2. A parsed type may contain at most 32 semantic nodes. This applies to inline
   and nominal generic forms equally and prevents generic syntax from becoming
   a denial-of-service escape hatch.
3. A single comma-rank collection counts as one semantic collection node;
   nested collection nodes remain distinct.
4. The compiler warns when a use requires more than six access obligations.
   The diagnostic lists them in execution order and suggests a named type or
   wrapper struct.
5. Recursive named types are checked through stable IDs and a visited set; type
   walkers never expand them indefinitely.

The complexity checker consumes the semantic tree, not source punctuation, so
aliases and whitespace cannot bypass it.

## BG STREAM, YIELD, and CLOSE

### Construction and annotation

`BG STREAM` accepts an optional item annotation:

```clear
values = BG STREAM: ?TextOrInteger {
  YIELD TextOrInteger{ Text: "one" };
  YIELD NIL;
  CLOSE;
};
```

The annotation names the yielded item type, not the entire stream wrapper. The
binding or context determines `[~]`, `[~N]`, or `[~INF]`.
Without an expected stream type, `BG STREAM` defaults to finite unbounded
`[~]Item`. Bounded and infinite claims require an expected binding/return type
or an explicit future extension to the producer header.

### Inference

The annotator collects full yielded `Type` values and computes a least upper
bound using existing coercion rules:

- identical types remain unchanged;
- `T` plus `NIL` becomes `?T`;
- compatible numeric types use normal numeric promotion;
- capabilities and ownership must be safely joinable;
- unrelated types do not create an anonymous union.

If unrelated yielded types occur, the producer must declare a named union item
type and yield its variants. The current check of `yield_types.map(&:resolved)`
is insufficient because it discards optional, collection, generic, and
capability structure.

### Termination

`CLOSE;` is a stream-producer statement. It closes the stream exactly once and
terminates the producer body. Normal fallthrough performs an implicit close so
cleanup remains exception-safe. A `YIELD` reachable after `CLOSE` is a compile
error. `CLOSE` outside `BG STREAM` is a compile error.

`[~INF]T` rejects a reachable explicit or implicit normal close unless the
producer is being cancelled or failing; otherwise its non-termination claim is
false. A producer whose termination cannot be proven should use `[~]T`.

`RETURN` exits a producer without yielding. It must not be used as an alias for
`YIELD` in examples or inference.

### Consumption

Finite advancement distinguishes item and completion:

```text
NEXT finite_stream -> StreamStep<T>
NEXT future        -> T
```

The language should provide an ergonomic control-flow form over
`StreamStep<T>` before removing the legacy optional-sentinel API. Pipelines
must lower the same tagged completion protocol. A yielded `NIL` is always an
`Item(NIL)`, never `Closed`.

## Tuples

Tuple types already exist. This change adds a dedicated literal:

```clear
x: Tuple<Int64, String, Int64> = Tuple{1, "1", 1};
```

`Tuple{...}` creates an `AST::TupleLit`, not a list or struct literal. Inference
preserves every positional type. Constant integer indexing returns the exact
position type. Dynamic indexing into a heterogeneous tuple is rejected unless
the result is explicitly matched through a future union facility.

During migration, a list literal contextually coerced to `Tuple<...>` remains
accepted and is auto-fixed to `Tuple{...}`. New code and formatter output use
the dedicated literal.

## Migration Rules

Migration is staged and source-preserving.

| Legacy type | Inline Pivot output |
| --- | --- |
| `T[N]` | `[N]T` |
| `T[]@list` | `[]T` |
| `T[N]@pool` | `[Pool(N)]T` |
| `T[]@set` | `[Set]T` |
| `HashMap<V>` | `{String}V` |
| `HashMap<K, V>` | `{K}V` |
| `~T[N]` | `[~N]T` |
| `~T[INF]` | `[~INF]T` |
| `~?T[]` or `~T[?]` used as an open stream | `[~]T` |
| `?T[]` | `[]?T` |
| `?(T[])` | `?[]T` |
| contextual tuple `[a, b]` | `Tuple{a, b}` |

Migration uses the parsed legacy semantic type, not textual substitutions.
This is essential for nested arrays, optionals, generics, and capabilities.

The compiler follows an expand-contract sequence:

1. parse both surfaces into the new semantic tree;
2. print only Inline Pivot in formatter/fixes;
3. warn on legacy spellings after full backend parity;
4. migrate repository sources and generated ruby-to-clear output;
5. remove legacy parsing only after corpus and downstream-tool inventories are
   empty.

Compatibility parsing is temporary and must have a deletion issue and metric.
No backend may branch on whether a type originated in legacy syntax.

## Implementation Plan

Each phase is a separate commit series with a green tree at its boundary.

### Phase 0: Freeze semantics and inventories

- Add syntax-oracle fixtures for every canonical example, invalid example,
  migration pair, and precedence pair.
- Inventory every `TypeShape` reader/writer, `Type.new(raw)` reconstruction,
  type surface printer, Zig type branch, capability propagation site, and
  stream-classification predicate.
- Inventory existing `HashMap<V>` uses because their default key is String.
- Record compiler, formatter, ruby-to-clear, FactMine, NilKill, Decomplex, and
  Espalier baselines.
- Add an architecture test forbidding a second structural source of truth.

Exit gate: the normative examples in this document have parser-oracle expected
trees even though production parsing still uses the old representation.

### Phase 1: Replace flattened TypeShape with the recursive algebra

- Introduce typed immutable variants for named, function, tuple, tense,
  collection, map, and stream nodes.
- Make child references concrete semantic nodes rather than raw Symbols.
- Give every node stable identity, source span, canonical printer support, and
  exhaustive visitor hooks.
- Migrate compatibility, copyability, cleanup, escape, slot-size, generic
  substitution, and type-ID logic.
- Delete the replaced boolean/raw-child fields in the same series.

Exit gate: old syntax produces the new recursive tree; no caller reconstructs
children by reparsing `raw`.

### Phase 2: Implement the predictive Inline Pivot parser and printer

- Parse prefix layers, ranks, maps, tenses, generics, and per-node capability
  chains directly into typed parse records.
- Add delimiter recovery and precise diagnostics without cursor checkpoint
  replay.
- Add canonical surface printing and formatter support.
- Add temporary legacy-to-tree parsing behind one explicit migration boundary.
- Update LSP spans, diagnostic anchors, and fix rewriter.

Complexity target: O(tokens) time and O(type depth) space, bounded by the type
node limit. No parser rule may restart type parsing from an earlier cursor.

### Phase 3: Per-layer capabilities and complexity validation

- Replace flattened top/element capability slots with capability attachment on
  the eligible semantic node.
- Define capability compatibility, polymorphic abstraction, ownership poison,
  cleanup, escape, and scheduler rules recursively.
- Implement the three-site hard limit, node-depth limit, and access-obligation
  diagnostic.
- Accept fixable aliases `@mvcc` and `@boxed`, but print `@versioned` and
  `@indirect`.
- Reject `@shared:striped` with a fix that requests an explicit shard count.

Exit gate: nested capabilities affect exactly their target layer through AST,
annotation, MIR, and backend output.

### Phase 4: Collection and map lowering

- Lower fixed arrays, lists, sets, pools, and maps from recursive nodes.
- Preserve current pool/handle safety and collection cleanup behavior.
- Implement flat multidimensional storage with checked stride calculation,
  overflow diagnostics, row views, and multi-index MIR.
- Treat list/set initial capacity as allocation metadata rather than type
  identity.
- Implement String-preserving HashMap migration and Symbol shorthand only for
  new `{}` syntax.
- Port SOA and sharding to node-local capability attachment.

Exit gate: representative types compile and run through Zig and bytecode, and
old/new equivalent spellings produce equivalent MIR layouts.

### Phase 5: Stream completion redesign

- Add stream cardinality nodes for finite unbounded, finite bounded, and
  infinite streams.
- Add `StreamStep<T>` to MIR/runtime finite advancement.
- Add the ergonomic finite-stream consumer control form and migrate pipelines.
- Add `AST::StreamClose`, control-flow reachability rules, implicit close, and
  exactly-once runtime close.
- Infer full yield types and least upper bounds; require named unions for
  incompatible items.
- Migrate `~?T[]`, `~T[?]`, `~T[N]`, and `~T[INF]` without changing behavior.

Exit gate: `[~]?T` can yield both `NIL` and a closed event and consumers can
distinguish them in source and runtime tests.

### Phase 6: Tuple literal and generic-boundary enforcement

- Add `AST::TupleLit`, parser support, exact positional inference, MIR lowering,
  Zig emission, cleanup, copyability, and constant-index checking.
- Auto-fix contextual tuple list literals.
- Register compiler-owned monadic/container generics and implement only
  equivalence-proven fixes.
- Diagnose mixed standard/generic monadic forms without rewriting `Result<T,E>`
  unsafely.

Exit gate: tuple construction is no longer dependent on expected-type context,
and no generic auto-fix loses error or capability semantics.

### Phase 7: Repository migration and downstream tools

- Run `clear fix` over compiler tests, examples, stdlib, docs, and transpile
  fixtures in reviewable groups.
- Update ruby-to-clear to emit canonical Inline Pivot syntax from the semantic
  tree, not by string rewriting.
- Update FactMine normalized type facts so analyzers see topology, rank,
  cardinality, and per-layer capabilities cross-language.
- Update NilKill collection/type facts, Decomplex type-pressure facts, and
  Espalier cost models for ranks, sets, maps, and streams.
- Update public documentation and migration notes.

Exit gate: repository and generated CLEAR contain no legacy type spellings
outside explicit migration fixtures.

### Phase 8: Contract legacy syntax

- Make legacy spellings errors with fixes for one release window.
- Remove legacy parser branches, aliases, raw-string reconstruction, and stale
  diagnostics.
- Remove the migration feature flag and inventory.
- Re-run fuzzing with deeply nested, malformed, and capability-heavy types.

Exit gate: one parser, one semantic tree, one canonical printer, and one backend
path remain.

## Test and Measurement Requirements

At every phase:

- run Sorbet and parser/annotator/MIR/backend focused specs;
- test changed behavior primarily with CLEAR source strings;
- maintain 100% line coverage for changed executable lines and cover every new
  diagnostic/fix branch;
- run compiler syntax and semantic oracles;
- run relevant Zig/bytecode integration and runtime tests;
- run FactMine, NilKill static mode, Decomplex, and Espalier and compare deltas;
- investigate analyzer findings in new code before proceeding;
- record material architectural improvements that the analyzers fail to
  recognize as detector gaps;
- run `git diff --check` and architecture guardrails before each commit.

Required adversarial tests include:

- maximum legal and first illegal type depth/capability counts;
- malformed delimiters and generic/map nesting with linear parser work;
- old/new map default-key preservation;
- multidimensional extent and stride overflow;
- optional container versus optional element at every layer;
- yielded `NIL` followed by `CLOSE`;
- close on every control-flow path, duplicate close, and yield-after-close;
- nested capability ownership/cleanup across BG, DO, BG STREAM, fields, returns,
  and FFI;
- generic aliases whose names resemble standard Option/Result/List types;
- tuple cleanup and dynamic heterogeneous index rejection.

## Risks and Non-Goals

- This design does not introduce anonymous structural unions.
- This design does not infer a sharding count or synchronization policy.
- This design does not treat initial list/set capacity as a durable contract.
- This design does not preserve both old and new type models internally.
- This design does not promise that every multidimensional resize is cheap;
  rectangular flat storage makes some operations O(total elements).
- This design does not use `?T` as a finite-stream completion sentinel.
- This design does not auto-fix a generic type unless semantic equivalence is
  proven from compiler-owned definitions.

The highest implementation risk is not parsing. It is ensuring that ownership,
cleanup, escape, capability, MIR, and backend visitors become exhaustive over
the recursive type tree without temporary fallback behavior. The phase order
therefore establishes the semantic representation before enabling the new
surface generally.

## Final Recommendation

Proceed with Inline Pivot using the revisions above. The syntax becomes
materially clearer once every prefix layer reads in access order and stream
completion is separated from optional values. Do not implement the proposal as
string syntax over the current flattened `TypeShape`; that would make nested
capabilities and mixed topology unreliable and would leave ruby-to-clear with a
harder translation target.

The first implementation milestone should be the recursive semantic tree plus
oracles, not collection parser branches. If that milestone cannot delete the
raw child-symbol reconstruction path, stop and redesign before adding surface
syntax.
