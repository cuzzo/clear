# Iterator Invalidation Detector: Product and Architecture Decision

Status: **Do not implement the proposed all-language detector.**

The detailed extraction and feasibility assessment lives in
`gems/fact-mine/docs/agents/iterator-invalidation-reliability.md`. This document
records the Decomplex-side decision and prevents a future agent from building a
plausible-looking detector on insufficient facts.

## Decision

Do not add an `IteratorInvalidationDetector` based on loop spans, textual
collection variables, mutation method names, or `(method, parameter-index)`
reachability. Do not put language mutation registries or language branches in a
Decomplex detector.

Across the 15 supported languages, mutation during traversal can mean undefined
behavior, a fail-fast runtime exception, a compiler error, defined live traversal,
snapshot/copy traversal, a permitted operation, or merely surprising logic.
Calling all of these “iterator invalidation” would be inaccurate. Reliably
distinguishing them requires resolved types and symbols, heap-object aliasing,
call/return/callback flow, and collection/version-specific contracts. Current
FactMine facts provide none of those guarantees.

This is also low-value relative to its cost:

- Rust already rejects the ordinary safe-borrow case.
- Java, C#, C++, Swift, TypeScript, and Zig need compiler semantic services for
  useful precision.
- C needs a points-to analysis plus annotated library/allocator contracts.
- Ruby, Python, JavaScript, Lua, and PHP retain unresolved dynamic behavior even
  after substantial analysis.
- Go deliberately specifies several mutations during `range`; mutation is not
  synonymous with invalidation.
- Existing compilers, runtimes, and focused linters already cover many of the
  strongest cases.

## Architectural boundary

If future evidence justifies a narrow implementation, FactMine must emit a
language-neutral, already-adjudicated `IteratorInteraction` fact containing:

- stable iteration and mutation IDs/spans;
- resolved iterable and mutation target value identity;
- resolved iteration and mutation contracts;
- an outcome such as `invalidated`, `runtime_fail_fast`, `traversal_changes`,
  `safe`, or `unknown`;
- the contract source and confidence; and
- enough evidence to explain why the mutation targets the traversed object.

Decomplex may consume only those facts. It must not:

- parse source or normalized nodes;
- compare source-text receiver/argument names;
- infer aliases or callees;
- own standard-library mutation lists;
- inspect `Document.language`; or
- reinterpret `unknown` as hazardous.

This follows the existing boundary: FactMine establishes semantic evidence;
Decomplex groups, thresholds, explains, and reports it.

## Reconsideration gate

Reconsider only after a separate, compiler-backed, standard-library-only pilot
for one language achieves at least 95% reviewed precision on real repositories
and finds useful issues not already reported by that ecosystem's compiler or
standard linters. C++/Clang, Java/javac or JDT, and C#/Roslyn are plausible pilot
choices. A Tree-sitter-only or YAML-registry prototype is not evidence that the
design works.

Until that gate is met, the correct implementation is no implementation.
