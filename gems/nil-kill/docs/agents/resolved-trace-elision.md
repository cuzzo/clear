# Resolved Runtime Trace Elision

## Decision

Nil-Kill should not collect runtime type evidence for a slot whose static
contract is already strong. Runtime collection remains mandatory for unknown,
`T.untyped`, and weak generic contracts such as `T::Array[T.untyped]`.

This is safe because runtime evidence is used to infer missing contracts, not
to validate strong Sorbet contracts. Sorbet remains responsible for enforcing
those declared contracts during the workload.

## Audit result

Nil-Kill was only partially optimized before this change:

- `TracePlan` correctly marked strong parameters and returns as not sampled.
- Every method nevertheless had `frame: true`, so every resolved method still
  received entry, return, exception, lock, counter, and frame-stack tracing.
- T.let and Struct/Data field recorders had runtime sampling gates.
- TracePlan requested FactMine's architecture-only profile, so ordinary
  annotation facts were unavailable and resolved `T.let` ivars remained in
  the runtime path.

Runtime call edges between fully resolved methods were the only output gained
from keeping those frames. No Nil-Kill inference/report path, Auto-Type path,
or Espalier path consumes `runtime_call_edges`; FactMine's static call graph is
the active input. Removing resolved-only runtime edges therefore does not
remove evidence used to type the remaining slots.

## CLEAR compiler measurement

The trace plan was generated over `compiler/ruby` on 2026-07-13:

| Item | Count |
|---|---:|
| Methods | 5,931 |
| Methods requiring runtime samples | 132 |
| Fully resolved methods pruned | 5,799 (97.8%) |
| Parameter slots | 7,841 |
| Parameter slots sampled | 114 |
| Returns sampled | 35 |
| T.let sites sampled | 53 |
| State/Struct field plan entries | 3,604 |
| Resolved fields pruned | 1,980 |
| Fields sampled or conservatively retained | 1,624 |
| Exact state-write sites | 1,055 |
| Strong state-write sites removed before rewriting | 373 |

Nil-Kill previously requested the complete Nil-Kill FactMine profile and then
discarded CFG/DFG, protocol, shape, call-graph, alias, and pressure facts during
trace planning. The purpose-specific trace-plan profile plus deterministic
parallel file extraction reduces plan construction from 65.47s to 4.60s. A
single raw grammar traversal reduces rewrite computation from roughly 15-17.6s
to 8.0s. Combined preparation is now about 12.6s instead of roughly 81s.

## Runtime benchmark

A controlled Ruby/Sorbet workload made 200,000 calls through a fully typed
method boundary. Five alternating runs included the same Nil-Kill tracer and
Bundler startup in both cases:

| Plan | Times (seconds) | Median |
|---|---|---:|
| Previous frame-only tracing | 2.06, 2.10, 2.08, 2.09, 2.06 | 2.08s |
| Resolved boundary elided | 0.87, 0.87, 0.88, 0.90, 0.90 | 0.88s |

That is a 2.36x speedup, or 57.7% less wall time, for a call-heavy typed path.
Whole-workload improvement will vary with collection mutation and unresolved
slot frequency, but a corpus with 97.8% resolved method boundaries has enough
eligible traffic to justify the optimization.

The full CLEAR compiler suite (6,413 examples) measures 61.5s normally and
329.5s under collection: 5.4x total, or about 4m28s added. Preparation is only
12.6s of that result. The residual is concentrated in hot, deliberately
heterogeneous `T.untyped` AST collection walkers, so the repository's overall
typed percentage is not a work-weighted predictor of collection cost.

## Safety boundary

Elision requires an explicit proof in the generated plan:

- A method is omitted only when every traceable parameter is strong and its
  return is strong or `void`.
- An ivar is omitted only when its declared/T.let type has an explicit strong
  plan entry. A field absent from the plan is sampled conservatively.
- Weak containers and `T.untyped` remain sampled.
- A sampled method is instrumented independently of its caller. A regression
  covers a pruned typed caller invoking an unresolved callee and proves the
  callee still records its parameter and return types.
- Strong T.let and Struct/Data slots retain their existing plan gates.

If runtime call edges are later made an inference input, that feature must
define a targeted edge-collection strategy and its cost explicitly. It must
not silently restore tracing to every resolved method.

## Verification

- Focused method, ivar, TracePlan, source-instrumentation, and runtime tests
  cover both the elided and retained paths.
- The full Nil-Kill suite passes with 511 examples and no failures. Existing
  pending examples are unchanged by this work.
- The controlled benchmark verifies the intended runtime effect rather than
  relying only on the static count of eligible methods.
