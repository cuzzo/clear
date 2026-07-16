# Espalier Big-O Design

Status: active architecture contract.

## Non-negotiable boundary

Espalier does not parse source code for Big-O analysis. It does not open source
files, scan lines, match language syntax with regular expressions, reconstruct
block boundaries, or infer loop/recursion semantics from text.

All structural evidence comes from FactMine's Tree-sitter-backed normalization.
FactMine emits serialized `complexity_facts`; it does not assign final time or
space complexity classes. Espalier performs that algebra using those facts,
type evidence, and the stdlib complexity registry.

If FactMine does not provide a required fact, Espalier keeps a lower bound and
reports the evidence gap. It must never fill that gap with source-text guesses.

## Pipeline

```
source
  -> Tree-sitter grammar
  -> FactMine normalized AST
  -> FactMine canonical complexity facts
  -> Espalier time/space lattice and interprocedural evaluator
  -> manifest, SARIF, and Lineage
```

FactMine owns:

- normalized loop/iterator nodes and containment;
- normalized iteration-domain references;
- fixed versus input-dependent bounds;
- cursor assignment/dataflow used to prove amortized scans;
- fixpoint-loop evidence;
- recursive call argument shape (shrinking or halving);
- recursive-call containment inside loops;
- receiver-state checkpoint, restoration, and intervening-call facts;
- receiver-state cursor progress and collection-index domain relationships;
- normalized call-site containment and operation identity;
- call-argument cardinality (`same`, `partition_of`, `independent_of`, or
  `unknown`);
- collection materialization and result-cardinality facts;
- known collection-parameter identity from normalized types.

Language adapters own iterator method identities, cardinality-preserving calls,
range/bound conventions, collection-type names, and worklist operation names.
The language-independent fact extractor must not maintain such allowlists.

Espalier owns:

- stdlib complexity lookup using resolved types;
- combining sequential facts with the complexity lattice;
- calculating recursive time and auxiliary stack space;
- calculating materialization and interprocedural auxiliary space;
- interprocedural fixed-point propagation from normalized call facts;
- confidence/evidence-gap reporting;
- output formatting.

## Fact contract

The FactMine profile emits `complexity_facts`. Each method record contains
canonical iteration facts, explicit cardinality relationships and bound
classification, recursive call progress facts, normalized call containment,
execution multiplicity, parameter identity, and known collection parameters.
It contains no final Big-O time or space answer.

Facts also carry normalized call contexts: call identity/span, execution
multiplicity, and the argument's cardinality relationship to the containing
iteration. Espalier combines independent domains, but collapses partitioned
calls: `groups.each { |group| scan(group) }` remains O(N), while repeatedly
scanning the same full input is O(N^2). A linear loop containing `Array#sort`,
for example, is O(N^2 log N), not merely O(N log N).

The normalized fact layer recognizes:

- fixed loops as O(1) with respect to input size;
- one or more independently growing parameter domains;
- hierarchical child traversal as one input domain;
- amortized nested cursors through normalized assignment dependencies;
- separate ordinary dataflow from collection-cardinality provenance;
- indexed child collections and arbitrary callback results as hierarchical or
  unknown domains, rather than invented Cartesian products;
- fixpoints only when a normalized boolean flag is reset and re-raised while
  iterating;
- linear, halving, branching, and loop-contained shrinking recursion.
- receiver-state replay across branching recursive components.
- fixed, input-sized, and unknown-sized collection materializations.

Espalier derives recursion time and space together. Halving recursion uses
O(log N) stack, shrinking recursion uses O(N) stack, and branching changes time
without multiplying live stack depth. Unproven recursive progress is `unknown`
for both time and space.

Internal recursive strongly connected components are never iterated through the
ordinary cost fixed point. Direct recursion uses FactMine's normalized progress
facts; mutual recursion without a progress proof is `unknown`. This prevents
recursive call cycles from fabricating ever-growing O(N^k) results.

Receiver-state replay is promoted to exponential time only when all of the
following normalized evidence agrees: a local checkpoint is restored to the
same receiver field after an intervening call; that call re-enters the same
recursive component; the component has more recursive call sites than a simple
cycle; the receiver field progresses; and the field indexes a receiver-state
collection. The analysis is language-neutral and method-name-neutral. A missing
gate remains `unknown`; checkpoint-like local variables alone are not enough.
The resulting recurrence is reported as O(2^N) time and O(N) live stack space.

## Complexity model

- Sequential work takes the maximum complexity.
- Independent iteration domains multiply.
- Hierarchical child collections do not invent additional powers of `N`.
- Fixed bounds do not contribute input growth.
- A cursor derived from an outer cursor can reuse the outer iteration domain.
- Super-polynomial classes dominate polynomial classes:
  `O(N!) > O(2^N) > O(N^k log N) > O(N^k)`.

Unknown callback multiplicity, receiver, call target, recursive progress, or
domain semantics remain explicit `unknown`; they are never silently treated as
O(1). Loop-contained unknown calls that receive known collection parameters are
highlighted. Nil-kill/runtime evidence may refine them later.

## Testing contract

- FactMine unit tests cover normalized-node analysis.
- Cross-language golden fixtures exercise real Tree-sitter normalization,
  FactMine profile serialization, Espalier fact consumption, and final output.
- Every false positive or false negative gets a golden regression when the
  source language is supported.
- The oracle corpus includes fixed loops, Cartesian products, hierarchical
  traversal, amortized cursors, fixpoints, recursive complexity classes,
  mutual recursion, cross-language receiver-state replay, allocation space, and
  interprocedural time/space.

## Prohibited regressions

Do not add any of the following to Espalier Big-O code:

- `File.read`, `File.readlines`, or equivalent source access;
- regexes for loops, calls, recursion, braces, indentation, or bounds;
- language-specific block matching;
- raw-source reparsing;
- complexity promotion without a normalized FactMine fact.
