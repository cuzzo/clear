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
| Methods requiring runtime samples | 197 |
| Fully resolved methods pruned | 5,734 (96.7%) |
| Parameter slots | 7,841 |
| Parameter slots sampled | 114 |
| Returns sampled | 100 |
| T.let sites sampled | 53 |
| State/Struct field plan entries | 4,198 |
| Resolved fields pruned | 1,230 |
| Fields sampled or conservatively retained | 2,968 |

Using the richer Nil-Kill FactMine profile increased plan construction on this
large corpus from 43.84s to 59.54s. That is a one-time 15.70s cost before a
collection workload; it exposes the annotation facts needed to remove ongoing
runtime hooks. For short one-shot commands, static-only `nil-kill infer` remains
the appropriate first step. For the compiler's multi-suite collection workload,
the runtime savings dominate this fixed preparation cost.

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
slot frequency, but a corpus with 96.7% resolved method boundaries has enough
eligible traffic to justify the optimization.

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
- The full Nil-Kill suite passes with 498 examples and no failures. Existing
  pending examples are unchanged by this work.
- The controlled benchmark verifies the intended runtime effect rather than
  relying only on the static count of eligible methods.
