# Espalier Big-O Design

Status: active design note for the Big-O analyzer.

## Problem

Espalier originally treated Big-O evidence as a flat set of method calls plus
flat nil-kill loop observations. That avoided false `O(N^19)` reports, but it
also hid real structural multipliers. A method that calls an `O(N)` operation
inside a loop is `O(N^2)` in the relevant dimension, and a graph/dataflow
fixpoint pass can be quadratic even when every individual runtime loop record is
only flat `O(N)`.

The current `src/` audit found high-confidence under-reported shapes:

- fixpoint loops over slots or call graph edges;
- graph traversal per graph node;
- aggregate scans such as `states.count { ... }` or `states.all? { ... }`
  inside another collection loop;
- shifting array operations such as `Array#insert` inside a body walk;
- known project-local `O(N)` helper calls inside fixpoint loops;
- loops calling known `O(N^2+)` helpers;
- direct nested loop containment such as `O(N^3)` for three nested collection
  loops;
- branching recursion such as Fibonacci-style `O(2^N)`;
- recursive branching over a shrinking collection such as permutation search
  `O(N!)`.

Examples include:

- `AutoUnifier#resolve!`: `while progress` over `@slots.each`.
- `EffectTracker#compute_effects!` and `#compute_can_fail!`: fixpoint
  propagation over `function_call_graph`.
- `EffectTracker#check_indirect_reentrancy!`: graph traversal per function.
- `LockHelper#propagate_lock_acquires!`: fixpoint graph propagation.
- `MIRChecker#normalize_guarded_conditional_releases!`: for each name, scan
  all branch states.
- `Hoist.hoist_body!`: body loop plus `Array#insert` shifts.

## Target Model

Espalier should report a lower bound plus explicit confidence notes:

- `O(1)`, `O(N)`, `O(N log N)`, `O(N^2)`, etc. are lower-bound estimates.
- Runtime loop lines alone are sequential evidence, not proof of nesting.
- Structural source evidence can multiply when an operation is syntactically
  inside a loop body.
- Unknown receiver or callback work should remain warnings rather than being
  silently treated as safe.

## Current Implementation

The Big-O analyzer consumes operation nodes:

- `:call`: resolved through known receiver type and stdlib complexity.
- `:loop`: flat runtime loop evidence, contributing a sequential `O(N)`.
- `:structural`: source-span structural hints, such as `O(N^2)` from an
  `O(N)` operation inside a loop.

Complexity comparison uses a small lattice:

- constant/logarithmic work: `O(1)`, `O(log N)`;
- polynomial work: `O(N)`, `O(N log N)`, `O(N^k)`,
  `O(N^k log N)`;
- multi-dimensional polynomial work: currently `O(N * M)`;
- exponential work: `O(2^N)`;
- factorial work: `O(N!)`.

Sequential work takes the maximum class. Loop containment multiplies the
contained class by `O(N)`. Super-polynomial classes dominate polynomial work:
`O(N!) > O(2^N) > O(N^k)`.

The structural pass is intentionally conservative. It is not a full language
parser. It uses method spans already present in Espalier static evidence and
looks for high-confidence Ruby shapes inside those spans:

- fixpoint loops such as `while changed`, `while progress`, or
  `loop do ... break unless changed`;
- collection scans inside those fixpoint loops;
- known project-local linear calls inside those fixpoint loops;
- direct block-loop containment, including `O(N^3)` and higher;
- known project-local `O(N^2+)` calls inside loops, propagated through a small
  fixed-point pass over methods in the same owner;
- aggregate collection scans inside another collection loop;
- graph traversal inside a per-node graph loop;
- shifting `insert` calls inside explicit loops;
- multiple direct recursive calls with shrinking arguments, reported as
  `O(2^N)`;
- recursive calls inside a collection loop that branches over a shrinking
  collection, reported as `O(N!)`.

This catches the concrete under-reporting bugs without reintroducing the old
flat-loop multiplication bug.

The pass deliberately does not promote every helper call inside every parser,
scanner, or lexer loop. Those loops often consume disjoint token spans, so
`while scanner` plus `read_string` can be amortized `O(N)` even when the helper
has its own loop. Espalier needs normalized loop containment and cursor-progress
facts before it can prove those cases either way.

## Implementation Plan

The practical solution is split into layers so Espalier can improve without
returning to the old false `O(N^19)` behavior:

1. Keep runtime nil-kill loop evidence flat unless FactMine provides a nesting
   tree. Repeated loop hits on different lines are sequential evidence.
2. Build source-span loop containment inside each method. Count block-loop
   depth directly and emit polynomial structural hints for `O(N^2)`,
   `O(N^3)`, and higher.
3. Compute method complexities by fixed point. First use flat calls and runtime
   loop evidence, then re-run structural hints until callers can see callee
   complexity. This detects a loop calling an `O(N^2)` helper as `O(N^3)`.
4. Detect high-confidence super-polynomial recursion:
   - two or more direct recursive branches over shrinking inputs => `O(2^N)`;
   - recursive call inside a loop over a shrinking collection => `O(N!)`.
5. Keep ambiguous amortized parser/scanner helper calls as warnings or
   future-facts rather than eagerly multiplying them.
6. Move this source scanning into FactMine facts once possible:
   loop spans, call-site spans, call containment, cursor advancement,
   recursive-call argument deltas, and collection-shrinking operations.

## Future FactMine Boundary

Long-term, structural Big-O evidence should be mined by FactMine as normalized
facts:

- loop/iterator spans;
- call sites with receiver and callee identity;
- callee containment within loop spans;
- fixpoint loop markers such as `while changed`, `while progress`, and
  `loop do ... break unless changed`;
- graph-work classifications for traversals over adjacency maps.
- recursion facts: direct recursive calls, argument deltas, recursive calls
  inside collection loops, and shrinking collection expressions.

Espalier should then consume those facts instead of scanning source text. The
current source-span pass is an interim implementation to make Big-O reporting
actionable now.

## Known Limitations

- It can under-report parser loops that call helpers whose own loop consumes
  the same token stream in non-amortized ways.
- It can over-report when aggregate scan work is bounded by a constant or a
  small unrelated dimension.
- It does not yet prove graph density, so `O(V * (V + E))` is reported as
  `O(N^2)` unless richer graph facts are available.
- It reports all polynomial nesting in the same `N` dimension until dimension
  facts can separate `N`, `M`, tokens, slots, states, and graph edges.
- Exponential and factorial recursion detection is intentionally heuristic; it
  requires direct recursion patterns and does not yet infer mutual recursion.
- It does not model callbacks or yielded blocks precisely.

## Roadmap

1. Keep runtime loop evidence flat and sequential.
2. Add structural hints for high-confidence loop-contained linear work.
3. Add direct polynomial loop containment and fixed-point helper propagation.
4. Add explicit recursion classification for `O(2^N)` and `O(N!)`.
5. Report structural warnings explaining why a function was promoted.
6. Move loop/call containment mining into FactMine once normalized facts exist.
7. Add dimension-aware graph notation when Espalier can distinguish `V`, `E`,
   states, slots, tokens, and body size.
