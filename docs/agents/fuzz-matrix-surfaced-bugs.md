# Bugs surfaced by the 6 mir_lowering fuzz matrices

Status: OPEN. Not fixed (deliberately — the task was to surface, not
fix). Each is reproduced by a `:pass` fuzz cell that currently fails;
the red cell is the live ticket.

All three are the **same family**: the catch / OR-rescue path
(`expr OR fallback`) mishandling allocator identity / cleanup across
the success vs error split. This is invariant #9 ("error paths
preserve allocator identity") and is exactly the decision
`branch_gap_triage` flagged as the P0 — `infer_catch_value_allocator`
was 12/12 dark and `lower_or_rescue` / `walk_catch_body_for_reassigns`
heavily fuzz_axis. The modality plan predicted this cluster; the
targeted matrices confirmed real bugs there.

## B1 — invalid free: OR fallback is a frame value, success is heap
Template `catch_allocator_matrix`, cell
`{value: string, fallback: frame_var, taken: failure}`.

```
FN maybe(s: String) RETURNS !String ->
    IF s.length() == 0_i64 THEN RAISE "empty"; END
    RETURN COPY s;
END
FN main() RETURNS Void ->
    fbv: String = "fb";
    r = maybe("") OR fbv;        # raises -> r = fbv (frame String)
    ASSERT r.length() >= 0_i64, "fallback value live";
    RETURN;
END
```
`maybe("")` raises, so `r` takes the frame-allocated `fbv`. But the
OR-rescue lowering binds `r`'s cleanup to the success path's heap
allocator (`COPY s`). Scope-end frees a frame value with the heap
allocator → `thread panic: Invalid free`.

## B2 — leak: reassign an outer binding through OR on the success path
Template `catch_reassign_matrix`, cell
`{var: local, value: string, taken: success}`.

```
MUTABLE acc = "init";
acc = maybe("X") OR acc;        # success -> acc = COPY-heap value
```
The prior value of `acc` (or the new heap temp) is not cleaned across
the reassignment-through-OR; debug allocator reports leaked memory.

## B3 — segfault: struct field reassigned from a fallible expr whose
fallback is the field itself
Template `catch_reassign_matrix`, cell
`{var: struct_field, value: string, taken: failure}`.

```
MUTABLE h = Holder{ acc: "init" };
h.acc = maybe("") OR h.acc;     # raises -> fallback reads h.acc while
                                 # the reassignment is mid-cleanup
```
`Segmentation fault` — use-after-free: the error path reads `h.acc`
for the fallback after the field's old value has been freed by the
reassignment cleanup.

## Coverage note (the other half of the result)

The 6 matrices (68 cells) moved mir_lowering branch coverage by **2
arms (673 -> 671)** — essentially zero, despite exercising maps,
catch, match, capabilities, binary ops, and indexed assignment as
features. This reproduces, more starkly, the earlier "92 example
programs -> 50/1005 arms" result. Interpretation (both likely true):

1. The dark arms need the *exact* triggering `type_info` shape
   (the `dispatch_key x value_transforms x shard_direct` cross, the
   `:dupe_borrowed_union` borrowed-union-into-map path, etc.), not
   surface-level feature coverage. Feature fuzzing retreads
   already-covered common arms.
2. The `fuzz_axis` bucket is likely over-assigned: many of those 590
   arms are closer to `accept_defensive` (reachable only by shapes a
   valid program does not produce). The bucketer is a proposed
   structural classification, not a verdict — this is the human-
   confirm signal firing.

Conclusion: feature-level fuzz matrices are high value for *finding
bugs* (3 real memory-safety bugs in the predicted P0 cluster) but, as
built, are NOT a branch-coverage-closure lever. Closing the branch gap
requires shape-specific cells driven off the actual dark `type_info`,
or re-triaging the fuzz_axis bucket against reachability.

## B4 — invalid Zig: @indirect:atomic + WITH EXCLUSIVE has no `ctrl`
Template `capability_wrap_matrix` (enumerated), cell `{mode: atomic}`.

```
STRUCT Counter { value: Int64 }
FN main() RETURNS Void ->
    MUTABLE c = Counter{ value: 1_i64 } @indirect:atomic;
    WITH EXCLUSIVE c AS x { x.value = 2_i64; ASSERT x.value == 2_i64; }
    RETURN;
END
```
Both forms are the compiler's OWN guidance (it rejected `@atomic` on a
struct telling us to use `@indirect:atomic`; it rejected
`WITH POLYMORPHIC` telling us to use plain `WITH`). CLEAR then accepts
this and emits invalid Zig: `no field named 'ctrl' in AtomicPtr(...)`.
The `is_atomic_ptr -> atomicPtrCreate` arm of compose_capability_wrap
(a dark arm) is broken. OPEN; not fixed.

## Enumeration result (the decisive coverage finding)

`binary_op_matrix` and `capability_wrap_matrix` were rebuilt from
SAMPLED axes to EXHAUSTIVE enumeration of the dispatch's own `when`
labels (every comparison op incl. LTE/GT, POW int+float, every
ft.sync/ownership mode; symbol-path excluded — no surface literal).
binary_op went 21->30 cells, all clean; capability 7 enumerated cells
(6 pass, 1 = B4).

Branch-gap delta from the *provably complete* enumeration method:
mir_lowering 656 -> 653 (3 arms). Four independent attempts now:

  92 example programs            -> 50 arms
  6 sampled fuzz matrices (68p)  ->  2 arms
  bc-lower whole corpus (0 new)  -> 15 arms
  exhaustive dispatch enumeration->  3 arms

Conclusion (now ironclad): mir_lowering branch coverage is NOT
closable by test generation, even by the theoretically-complete
enumeration. The ~650 dark arms are overwhelmingly invariant-guarded
/ nil-defensive / internal-state branches no source program in any
backend can toggle; the earlier ~22% "genuine dispatch" estimate
(eyeballed from 36 lines) was itself too optimistic. The strategy is
reachability-aware re-triage to remove the impossible arms from the
denominator + a tiny enumerated set for the genuine handful. Fuzz's
delivered value here is bug-finding (B1-B4: 4 real memory-safety /
codegen bugs on dark arms), not coverage.
