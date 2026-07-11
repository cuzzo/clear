# Iterator Invalidation: Reliability Assessment and Fact-Mine Design

Status: **Do not implement the proposed cross-language detector.**

This decision covers the proposal in
`iterator_invalidation_plan.md` to identify a loop collection, follow arguments
through a `(method, parameter-index)` graph, and use per-language mutation-name
registries to report iterator invalidation. That design cannot be made reliable
for all languages supported by FactMine without adding language compiler front
ends, type and symbol resolution, points-to/alias analysis, and container-specific
semantic models. The likely value does not justify that second analysis stack.

The supported set is Ruby, Python, JavaScript, Java, TypeScript, Swift, Kotlin,
Go, Rust, Zig, Lua, C, C++, C#, and PHP. Tree-sitter and normalized syntax make
their *shapes* comparable; they do not make their iteration semantics equivalent.

## Decision and terminology

Do not add `stdlib_mutations.yml`, `DirectMutation`,
`ParameterPropagation`, or a generic reachability detector as proposed.

The proposal combines three different conditions under one name:

1. **Iterator invalidation:** an iterator, pointer, reference, or index ceases to
   be valid, potentially causing undefined behavior or a runtime exception.
2. **Mutation during traversal:** traversal remains valid, but the language
   specifies that inserted/deleted elements may be visited, skipped, or observed.
3. **Algorithmic surprise:** the program is valid and specified, but modifying
   the traversed collection is hard to reason about.

Only the first is iterator invalidation. A generic "iterated value reaches a
mutating method" test cannot distinguish them and would mislabel many valid Go,
JavaScript, PHP, Ruby, Python, and language-specific collection idioms.

Reliability here means that a finding proves all of the following:

- which runtime object is being traversed;
- which iterator/traversal contract applies to that object;
- that the mutation reaches the same object, including through aliases and
  calls;
- which mutation operation occurs and whether it invalidates this iterator;
- that no snapshot, copy, rebinding, copy-on-write collection, permitted
  iterator mutation, or implementation-specific contract makes it safe; and
- that the condition is not already rejected by the language compiler.

FactMine cannot currently prove those statements.

## Why the proposed facts are insufficient

Current facts do not expose a loop entity or the identity of its iterable.
`NormalizedExtractor::scan_loop` only scans descendants under the control label
`"iterates"`. `CallSite.arguments` and receivers are strings, not resolved value
IDs. `FunctionDef.body` and normalized nodes are intentionally private to
FactMine passes. `MethodSummary` provides statement-level local reads/writes,
not heap-object identity, iterator creation, aliases, points-to sets, or resolved
callees.

A graph keyed by `(method name, parameter index)` therefore has fundamental
collisions:

- overloads, methods with the same name in different owners, extensions, traits,
  interfaces, monkeypatches, and dynamic dispatch;
- receiver mutation versus argument mutation;
- rebinding a parameter versus mutating the object it refers to;
- field, index, pointer, slice, view, and closure-captured aliases;
- callbacks/yields whose bodies run inside library traversal;
- generic functions whose behavior depends on the concrete collection;
- same-file versus cross-file definitions and external dependencies; and
- native/reflection/FFI calls with unavailable bodies.

A mutation-name YAML file does not repair this. Names are not semantic identities:
`append` is a builtin in Go, a method in several languages, user-definable in
dynamic languages, and can rebind or return a new value rather than mutate the
traversed object. C and C++ mutations often have no method call at all.

## Per-language feasibility

This matrix is deliberately conservative. “Possible narrowly” means only with
the named compiler/type service and a versioned model of known library
collections; it does not mean FactMine's current syntax facts are sufficient.

| Language | Semantic obstacle | Reliable repository-wide detector |
| --- | --- | --- |
| Ruby | Duck typing, aliases, open classes, `each`/yield callbacks, and collection-specific behavior; some mutations raise while others produce defined or surprising traversal | No; local syntactic lint only |
| Python | Dynamic dispatch and aliases; list traversal differs from dict/set size-change checks; user iterators define their own contract | No; local syntactic lint only |
| JavaScript | Array iteration methods, indexed loops, and live Map/Set iterators have different specified behavior; prototypes and proxies are dynamic | No; many mutations are not invalidation |
| TypeScript | Types improve symbol resolution but erase at runtime; JavaScript prototype/proxy and iterator semantics remain | Possible narrowly with the TypeScript compiler API, not Tree-sitter alone |
| Java | Overloads and receiver types must be resolved; fail-fast behavior is generally best-effort and collection/iterator implementations vary | Possible narrowly with javac/JDT plus JDK collection models |
| Swift | Collection indices and mutation guarantees are type-specific; value semantics, copy-on-write, exclusivity, and custom `Collection` conformances matter | Possible narrowly with Swift compiler semantic information |
| Kotlin | Dispatch and types require compiler resolution, and semantics can differ across JVM, JS, and Native targets | No single source-level policy for all targets |
| Go | `range` behavior is specified separately for arrays, slices, maps, channels, integers, and iterator functions; map deletion/addition and slice append are not one invalidation rule | Usually not an invalidation defect; do not report generic mutation |
| Rust | Safe borrowing rejects the ordinary same-collection structural mutation case; interior mutability, unsafe code, custom iterators, and reallocation require compiler/MIR-level reasoning | Little incremental value; rely on rustc/Clippy/Miri |
| Zig | Arrays, slices, pointers, allocators, and container APIs expose different lifetime/reallocation behavior; aliases are explicit but require semantic and points-to analysis | No with syntax facts; compiler-level work required |
| Lua | Table traversal and mutation are dynamic and library/user iterators are ordinary functions/closures | No; local syntactic lint only |
| C | Iteration is encoded as pointer/index/control flow; there is no universal container or mutation API; invalidation depends on allocator and library contracts | No general detector; needs whole-program points-to analysis and annotations |
| C++ | Standard container, operation, iterator category, allocator, range/view, and language-version rules form a large matrix; custom containers add arbitrary contracts | Possible narrowly with Clang AST/CFG and versioned standard-library models |
| C# | `foreach` lowering and resolved enumerator types matter; standard collections often version-check, while custom enumerators define arbitrary behavior | Possible narrowly with Roslyn and BCL models |
| PHP | `foreach` by-value/by-reference behavior, copy-on-write, arrays versus Traversable objects, and dynamic calls differ | No; local syntactic lint only |

Even the “possible narrowly” entries would create a compiler-integration product,
not a modest new FactMine pass. Supporting all 15 at a common reliability level
is not realistic.

## If the decision is revisited

First validate demand with a precision-first experiment in one language and one
container family. C++ standard containers with Clang, Java JDK collections with
javac/JDT, or C# BCL collections with Roslyn are reasonable experiments because
resolved types and documented collection contracts exist. Do not start with a
cross-language abstraction.

The experiment must use an explicit semantic fact contract, not method-name
registries:

```text
IterationSite
  id, file, span, function_symbol
  iterable_value_id, iterator_value_id
  resolved_iteration_contract

MutationSite
  id, file, span, function_symbol
  target_value_id, operation_symbol
  effect = element_write | structural_change | reallocate | unknown

AliasEdge
  from_value_id, to_value_id, kind, confidence

CallEdge
  caller_symbol, call_site_id, callee_symbol, dispatch_kind, confidence

ParameterEffectSummary
  function_symbol, parameter_index
  effect, path_condition, confidence

IteratorInteraction
  iteration_id, mutation_id
  outcome = invalidated | runtime_fail_fast | traversal_changes | safe | unknown
  contract_source, confidence
```

Rules for such a prototype:

- Language-owned semantic providers resolve symbols and assign iteration and
  mutation contracts. Generic FactMine code must not branch on a language.
- Stable symbol/value IDs replace textual method names, receiver names, and
  argument strings.
- Summaries are computed to a fixed point over resolved call-graph strongly
  connected components. An unqualified DFS over names is forbidden.
- Aliasing includes assignments, fields, indexing/views, closure captures,
  pointer/reference operations, receiver-to-parameter flow, and returns.
- Unknown dispatch, unknown container type, external body, FFI, reflection, or
  imprecise aliasing yields `unknown`, not a user-visible invalidation finding.
- A reported result must carry the exact collection contract and invalidating
  operation that justify it.
- Facts remain detector-neutral and serialize through `Document`; Decomplex may
  not inspect source, normalized nodes, `Document.language`, or compiler ASTs.

This requires changes in order:

1. Write exact positive and negative source fixtures, including aliasing,
   overloads, callbacks, copies/snapshots, custom collections, allowed iterator
   removal, recursion, unresolved dependencies, and concurrency.
2. Integrate the chosen language's semantic compiler service behind a
   language-owned provider.
3. Add the semantic facts and exact source-fact oracles to FactMine.
4. Measure precision on real repositories before adding a Decomplex consumer.
5. Proceed only if reviewed findings meet a predeclared precision threshold
   (recommended: at least 95%) and reveal defects not already caught by the
   compiler or standard linters.

Do not claim support for a language until every applicable fixture category is
implemented. Unsupported/unknown cases must be explicit and silent by default.

## Final recommendation

Do not implement this as an all-language Decomplex detector. The work needed for
correctness is very large, the common abstraction is weaker than the languages'
actual contracts, dynamic-language precision would remain poor, and Rust removes
the flagship case at compile time. A low-cost textual implementation would add
noise under a dangerously strong “iterator invalidation” label.

If there is still product interest, run one compiler-backed, standard-library-only
experiment and treat it as a separate feasibility project. Until that experiment
demonstrates unique high-precision value, FactMine should add no facts for this
proposal.
