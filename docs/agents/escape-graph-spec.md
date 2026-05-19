# EscapeGraph specification (Stage A)

The contract for the single value-flow escape analysis that replaces the
5 fragmented proxies (E1 `compute_heap_return_fns!`/`return_expr_is_heap?`,
E2 `analyze!` 9 conditions, E3a `tag_transitive_provenance!`, E3b
`tag_carry_call_sites!`/`heap_carry_return`, `PromotionClassifier`).

**One question:** for each value-producing declaration `D`, does `D`'s
value reach a SINK (outlive its declaring frame)? `escapes?(D)` =
"`D`'s node reaches any sink in the value-flow graph (interprocedural
fixed point)". `escapes? ⇒ storage/provenance :heap`, else `:frame`.
Everything downstream (MIR AllocMark/Cleanup/MoveMark, emitter,
MIRChecker) is unchanged: a return is a move; the receiving binding is
a heap decl with its own one guarded cleanup, recursively.

Shapes are EDGES, not branches — that is the whole point. The 5
proxies are 5 hand-coded per-shape detectors of these same edges/sinks;
they miss combinations (the 20-cell manifest = the gaps). A graph
cannot miss a shape because there is no per-shape code.

---

## NODES

- every `VarDecl` / `BindExpr(:decl)` (the things we stamp `:heap`/`:frame`)
- every value-holding sub-expression (call results, literals, wrapper
  exprs, struct/union literals, OR_RESCUE results)
- per-function synthetic node `RET[fn]` (the interprocedural return summary)
- per-parameter node `PARAM[fn, i]`

## DECISION RULE (corrected — Stage B characterization, 444-miss bucketing)

`storage(D) = :heap` iff **inherently_heap?(D)** ∨ **(escapes?(D) ∧
heap_source?(D))**.

**The key correction (the real simplification):** escape analysis only
matters for the *frame-capable* types — **`@list` and `String`**. Every
other heap-backed type is heap by its **TYPE alone, escape-independent**:

  `inherently_heap?` = map ∨ set ∨ pool (heap hashtable)
                     ∨ sync/storage-wrapped (`@locked`/`@shared`/
                       `@multiowned`/`@atomic`/`@versioned` → Arc/Rc/
                       Locked)
                     ∨ `requires_move?` non-Copy-owned (owns heap
                       resources), excluding @list/String themselves.

The gate proved this empirically: of 444 corpus misses, **397 (89%)
were these type categories, not escape-reachability** (217
requires_move + 180 sync-wrapped + 3 map/set/pool). Only ~46 (37
String + 9 @list + 1) are genuine escape-reachability cases. So the
"single question = does it escape?" framing was wrong; the correct,
*simpler* model is: heap is a **pure type predicate** for everything
except `@list`/`String`, where it is `type ∧ escapes?`. This shrinks
the entire escape-graph surface to two types.

## SOURCES (a node is heap-origin if it is / contains)

- collection/string/map literal or builder: `[..]`, `"a"+"b"`, `Map{}`,
  `Set[]`, `.append`, `.split`, `makeList`, `concat`, `substr`,
  `intToString`, `charAtCodepoint`, `join` (the alloc-faulting stdlib ops)
- a value whose `Type#requires_move?` (non-Copy owned)
- a call to a fn whose `RET[callee]` is heap (interprocedural)
- the declared owned-heap return contract:
  `alloc_fault ∧ (collection? ∨ string? ∨ map?) ∧ ¬borrow`
  (the authority already built this session — keep it as the source rule)

## EDGES  `v ──▶ x`  (x's value contains/derives v; x escapes if v reaches a sink)

| # | Edge | Source proxy(ies) it currently hand-codes |
|---|---|---|
| E-init | `x = <expr>` decl initializer: `<expr> ──▶ x` | all |
| E-wrap | `GIVE v` / `COPY v` / clone/freeze/share: `v ──▶ wrapper` | E1, E2 `e2_return_refs?`/`e2_extract_ident` unwrap |
| E-field | `Struct{ f: v }` / `Union.V{ v }`: `v ──▶ literal` (recursive) | E2 `e2_return_refs?` StructLit/UnionVariantLit |
| E-call | `x = f(args)` and `f`'s `RET[f]` heap: `RET[f] ──▶ x` | E2 cond 6 `:transitive_callee`; E3a |
| E-orresc | `lhs OR <rhs>`: `lhs ──▶ result` (the success value; rhs only if it propagates) | E3a `e3_underlying_callee` (OR_RESCUE see-through) |
| E-assignvar | `BindExpr(:assign)` / `Assignment`: RHS ──▶ the original decl (via `e2_root_ident`) | E2 cond 4, E3a |
| E-arg-takes | call arg `a` into `PARAM[callee,i]` where `param.takes` & heap-cleanup type | E2 cond 8 `:takes_arg_escape` |
| E-arg-mutlist | call arg `a` into `PARAM[callee,i]` where `param.mutable` & `@list` (callee `.append` reallocs) | E2 cond 9 (mutable-collection-param) |

## SINKS (value escapes the declaring frame if it reaches one)

| # | Sink | Source proxy(ies) | Borrow carve-out applies? |
|---|---|---|---|
| S-return | value flows to a `ReturnNode` value (→ `RET[fn]`) | E1 `fn_body_returns_heap?`/`return_expr_is_heap?`; E2 cond 1 `:always_returned`, cond 3 `:heap_ptr_return` (`@indirect`), `e2_carry_return_vars` (string) | **YES** |
| S-heapfield | stored into a heap-storage field/container (`x.f = v` where root storage ∈ {heap,multiowned,shared}) | E2 cond 4 `:assign_escape` | no |
| S-heapmut-arg | frame string-concat passed as arg into a heap-container mutator (`cont.append(a+b)`) | E2 cond 7 `:concat_into_heap` | no |
| S-bgcapture | captured by a BG block / closure | E2 cond 2 `:bg_captured` | no |
| S-takes | passed to a TAKES param of heap-cleanup type | E2 cond 8 | no |
| S-mutlist | passed to a MUTABLE `@list` param the callee appends to | E2 cond 9 | no |
| S-loopcarry | string reassigned across a per-iteration-rewound loop, then used after/returned | E2 cond 5 `:loop_carry_string` + carry-return | only if also returned |

## INTERPROCEDURAL  `RET[fn]`

`RET[fn]` is heap ⟺ some `ReturnNode` in `fn` has a value that reaches
a SOURCE through the edges (with `RET` of callees substituted). Compute
by **fixed point over the call graph** (replaces `compute_heap_return_fns!`;
must handle direct + mutual recursion: monotone, start all `RET=frame`,
iterate to closure). `E-call` then makes `x = heapRetFn()` an escape.

## BORROW CARVE-OUT (one predicate, applied at S-return only)

`fn.return_lifetime` set, **or** `return_type.borrow_provenance?`
⇒ the returned value is borrowed; caller does not own; S-return does
NOT make it escape *for this fn*. (Master mechanism — verified;
`%T` is gone.) This is the *only* exception in the whole model.

## COMPLETENESS CHECK (Stage B gate uses this)

The union of {edges × sinks} above must reproduce, for every
declaration in the green corpus, the same `:heap`/`:frame` decision the
5 proxies produce (superset: never `:frame` where they say `:heap`).

### The 20-cell manifest gaps the graph MUST additionally fix

| Manifest cell (heap_ownership_transfer) | Missing edge/sink combo | Today's bug |
|---|---|---|
| `:give, *, :plain` (×5) | E-wrap (`GIVE v`) → S-return, plain decl | producer frame-allocs `v`, caller heap-frees → **double-free / allocator mismatch** |
| `:literal, *, :err` (×~6) | E-init(literal source) → S-return through `!T` | producer ∉ heap_fns (return_expr_is_heap? AST allowlist misses literal) → caller no cleanup → **leak** |
| `:call, {or_raise,or_fallback,discard_or_raise,onward}, :err` | E-call + E-orresc → S-return | E3a `FuncCall`-only match misses OR_RESCUE-wrapped → **leak / OWNED_RETURN_WITHOUT_ALLOC** |
| `:ident, {or_raise,or_fallback,discard_or_raise,onward}, :err` | E-init + E-orresc → S-return | same | **leak** |

Every gap is a (known edge) ∘ (known sink) the fragmented detectors
fail to *compose*. The graph composes them by construction → all 20
flip to `:pass`.

## INVARIANT (the structural proof, Stage C)

MIRChecker's 7 invariants are unchanged and verify the result: every
heap decl ⇒ exactly one AllocMark + one guarded Cleanup; every move
(return/GIVE/TAKES/store) ⇒ MoveMark first. `MIRChecker green ∧ net
green ⟺ escape decisions are cleanup-consistent for every exercised
shape`. The graph decides; the checker proves.

---

## STAGE B VERDICT — APPROACH DROPPED (negative result)

The single-unified-analysis approach was built and gated twice:

| Model | DISQUALIFYING (under; UAF risk) | NEW_HEAP_OLD_FRAME (over; perf/ABRT) |
|---|---|---|
| v1 heuristic (type predicates + name allowlist) | 444 → 36 | 113 → 830 |
| v2 authoritative (registry `return_alloc` + Type + escape) | 36 → **34** | 830 → **796** |

The v2 fix was architecturally correct (it removed the name-list
anti-pattern and read the registry's authoritative `return_alloc`),
yet it moved the numbers by ~5% — **noise**. This is the decisive
evidence: the non-convergence is **not** caused by using heuristics
instead of ground truth. Reading the same authoritative inputs the
proxies read still does not reproduce their decision: **34 decls
under-classified (UAF) + 796 over-classified (a clean superset would
heap-allocate ~800 values the corpus-tuned proxies deliberately keep
on the frame — a real perf/ABRT regression).**

**Conclusion:** the 5 proxies' combined decision function is not
reproducible by a clean unified analysis within iterative reach —
neither by heuristic re-derivation (v1) nor by authoritative-input
re-derivation (v2). A substantial fraction of the ~1500 LOC is
**essential, corpus-tuned, escape-conditional nuance**, not
fragmentation hiding a simple model. Per the pre-agreed protocol
(Stage B non-convergence ⇒ STOP, do not wire, do not patch around),
the approach is **dropped**. EscapeGraph + the env hook are removed;
production was never altered (read-only/env-gated throughout).

The Stage-A spec, the characterization gate methodology, and these
numbers are retained as the documented negative result: they answer
"surely this can be simplified" with a measurement — within the
methods tried, it largely cannot. The memory-safety bug (#13 / the
20-cell manifest, incl. double-frees) remains separately tractable by
closing the localized shape gaps in the existing proxies (option-1
ledger localized them) — that is NOT a dead end and does NOT require
the grand unification.

---

## RESOLUTION — APPROACH SUCCEEDED (negative result OVERTURNED)

The "non-convergent / largely irreducible" verdict above was wrong. It
was an artifact of the WRONG ORACLE: every prior attempt gated on
byte-equivalence with the 5 proxies' stamps -- but the proxies ARE the
#13 bug, so reproducing them is both impossible and undesirable. The
correct oracle is the truth the proxies only approximate: MIRChecker's
7 invariants (compile-time proof of no leak / double-free / UAF) + the
full test suite + the 20-cell manifest flipping to pass.

Re-gated against that oracle, the single value-flow EscapeGraph
(escape_graph.rb, EscapeGraph.apply!) converges:

  storage = :heap iff inherently_heap?(Arc/Rc/Locked, by construction)
                   OR escapes?(value-flow graph reaches a sink)

Collections/strings/structs are uniformly escape-conditional (the
"map/set/pool inherently heap" and "397/444 are type categories"
buckets were themselves measured against the buggy proxies -- the same
trap). Sinks: S-return (list ownership transfer / @indirect),
S-heapfield, S-heapmut-arg (concat_into_heap), S-bgcapture,
S-loopcarry, S-takes, S-mutlist, transitive heap-call. Shapes are
EDGES in one graph; no composition can be missed.

Result (committed): escape_analysis.rb 933 -> 171 LOC (-762); 5
proxies -> 1 rule; manifest 77/77 with in_dev=0 (#13 fixed -- all
double-frees and leaks); prspec 4823/0; transpile-tests 569/569
0-leak; stable fuzz 145/145; MIRChecker green throughout. The
simplification IS the fix.
