# tools/fuzz — Combinatorial Fuzz Harness

Template-based program generator that stresses MIR ownership invariants and
escape-analysis cross-products. Runs `.clear` programs through the existing
`./clear test` pipeline, which catches MIR violations (statically) and leaks /
UAF / double-free (at runtime via `std.testing.allocator`).

## Usage

    # Generate + run the full matrix (every parameter combination)
    ruby tools/fuzz/run.rb --matrix

    # Sample N tuples from the matrix with a fixed seed
    ruby tools/fuzz/run.rb --count 50 --seed 42

    # Generate only — useful for inspecting outputs before running them
    ruby tools/fuzz/run.rb --matrix --generate-only

    # Custom output dir + clean previous run
    ruby tools/fuzz/run.rb --matrix --out /tmp/fuzz --clean

    # Local diagnosis: recursively isolate every failing positive program.
    # Green sequential programs still require only one bundled Zig build.
    ruby tools/fuzz/run.rb --matrix --bisect-positives --out /tmp/fuzz --clean

    # CI gate: every registered cell, with no quarantine mechanism
    ruby tools/fuzz/run.rb --matrix --out /tmp/fuzz --clean

## No quarantine

Every registered fuzz cell runs. There is no quarantine file, skip flag, or
non-blocking fuzz lane. Unsupported language behavior must be represented by
an active `:compile_error` cell, and a compiler/runtime defect must make CI red.

Exit code is 0 only if every program parses, type-checks, transpiles, runs,
and reports zero leaks.

## Mutant Harness

`tools/fuzz/mutants/run.rb` is the targeted safety check for the fuzz suite.
CI runs every active entry. It deliberately applies a small patch that disables
one ownership rule, runs the relevant fuzz templates before and after the patch,
then reports whether the mutated compiler produced new failures relative to
baseline.

This is intentionally separate from the normal fuzz matrix because it is slower
than generation-only fuzzing and mutates the working tree while it runs. The
runner checks that the patch applies, refuses to touch target files that already
have local edits, and reverses the patch before exiting. Use `--allow-dirty`
only when you intentionally want to test a mutant against WIP.

    # List available mutants
    ruby tools/fuzz/mutants/run.rb --list

    # Check patch applicability without running fuzz
    ruby tools/fuzz/mutants/run.rb --mutant allow_with_alias_return --dry-run

    # Run a single mutant
    ruby tools/fuzz/mutants/run.rb --mutant allow_with_alias_return --out /tmp/clear-fuzz-mutants

    # Run against WIP that touches mutant target files
    ruby tools/fuzz/mutants/run.rb --mutant allow_with_alias_return --allow-dirty

Each run writes baseline and mutated fuzz logs under the chosen output
directory. A mutant is useful when it is "killed": the mutated run produces the
configured failure delta over the baseline run.

Active mutants:

| Mutant | Templates | Signal |
|---|---|---|
| `allow_with_alias_return` | `access_gate` | unexpected pass |
| `escape_struct_field_walker` | `nested_loop_escape` | fail |
| `lower_if_cond_pending_leak` | `cond_or_fallback` | fail |
| `cleanup_required_finalizer` | `mir_checker_negative_matrix` | unexpected pass |
| `loop_frame_scope_stamp` | `loop_local_method_temp` | mir-error |
| `mir_checker_linear_use_after_transfer` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_inline_alloc_mismatch` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_aggregate_child_alloc` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_cleanup_source_owns` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_call_contracts` | `mir_checker_negative_matrix` | unexpected pass |
| `hold_lock_across_yield_policy` | `diagnostic_policy_matrix` | unexpected pass |
| `fn_type_reentrant_constraint` | `diagnostic_policy_matrix` | unexpected pass |
| `tight_loop_admission_policy` | `diagnostic_policy_matrix` | unexpected pass |
| `move_mark_emission` | `call_ownership_contract_matrix`, `takes_move_modality`, `cleanup_control_matrix` | fail |
| `capture_promise_handle_by_value` | `promise_handle_capture` | mir-error |
| `bg_lifetime_all_captures_independent` | `lifetimed_return` | unexpected pass |
| `or_rescue_catch_allocator_identity` | `catch_allocator_matrix` | fail |
| `escape_identifier_heap_placement` | `escape_mechanism_matrix` | mir-error |
| `ownership_surface_finalization` | `mir_checker_negative_matrix` | unexpected pass |
| `union_match_drops_payload_capture` | `union_lowering_cleanup_matrix` | fail |
| `fsm_suspend_returns_done` | `fsm_suspension_matrix` | fail |

## Layout

    tools/fuzz/
      run.rb            # driver
      generator.rb      # template registry + tuple iteration
      surface_registry.rb
      coverage_model.rb
      coverage.rb
      mutants/          # manual targeted safety mutants
      templates/*.rb    # one file per template
    transpile-tests/fuzz/
      fuzz_<name>_<hash>.clear   # generated programs (gitignored)

Each template registers itself with `FuzzGenerator.register(name, cells:) { |params| ... }`,
declaring its parameter cells (the matrix it owns) and a renderer that turns a
cell into a complete `.clear` source string with embedded `ASSERT` oracles. A
template may also return `{ kind: :mir_checker, source:, error_code: }` for
malformed-MIR negative cells; those run the checker directly and fail if the
expected hard error is absent.

## Current templates

| Template                    | Active cells | Stresses |
|-----------------------------|--------------|----------|
| `escape_via_return`         | 64           | E2 :always_returned, :heap_ptr_return |
| `loop_carry_collection`     | 32           | E2 :loop_carry_string + frame-rewind invariant |
| `mutable_collection_param`  | 24           | E2 :mutable_list_param_escape, INV-CROSS-FRAME-PARAM-ALLOC |
| `nested_loop_escape`        | 48           | Loop-local list/map escape -> outer container (commit 9fa21926). `wrap_kind` axis (`:bare` / `:struct_field`) per docs/agents/bug9-forensic.md: struct-wrapped escapes fail today as designed, pass once escape-analysis walkers are unified. |
| `collection_shape_smoke`    | 14           | Shape/admission smoke coverage for every collection form named in the surface registry, including direct `String[]@list` cleanup coverage. |
| `tuple_collection_composition_matrix` | 19 | Recursive Tuple composition in both directions across collections and capable layers, plus optional/fallible/future tense binding on the Tuple, its fields, and nested collections. |
| `c_ffi_type_matrix` | 54 | Target-resolved signed/unsigned C aliases across fixed arrays, lists, pools, sets, maps, and streams; foreign pointers require a scoped `WITH UNSAFE VIEW ... LENGTH ...` boundary and reject direct indexing, safe views, legacy method views, invalid lengths, and escaping aliases. |
| `generic_map_protocol_matrix` | 14 | Static Map bounds and `M::Key`/`M::Value` projections across string/numeric maps, specialization-selected associated-key storage, generic allocator forwarding, cleanup-bearing value copies, value-shaped optional captures, borrowed-value rejection, nested type syntax, and declaration-time constraint diagnostics. |
| `generic_shared_map_capability_matrix` | 8 | `SHARED Map` specialization across locked, read/write-locked, versioned, and sharded maps; direct or non-polymorphic access is rejected before Zig. |
| `ownership_surface_smoke`   | 35           | Global smoke coverage for cleanup shapes, escape sinks, and MIR ownership contracts. |
| `escape_mechanism_matrix`   | 30           | Direct AST-bound escape mechanisms: return, yield, BG/BG STREAM/DO capture, enclosing assignment, field/index stores, collection/aggregate stores, recursive aggregate returns, TAKES/GIVE, loop carry, and call-return receiver stores. |
| `takes_move_modality`       | 48           | EVERY :cleanup_value_shapes member passed to a TAKES param via GIVE / bare(implicit) / COPY. Registry-driven (no hand-picked shapes). |
| `return_value_modality`     | 64              | EVERY :cleanup_value_shapes member returned from direct / branch / OR-fallback / call-forward return contexts. Breadth axis complementing heap_ownership_transfer's depth on list/string. |
| `struct_field_store_modality` | 54          | EVERY :cleanup_value_shapes member stored into `STRUCT Box { f: T }` via GIVE / COPY / bare. Registry-driven (18 shapes including frame_*). |
| `list_append_modality`     | 54           | EVERY :cleanup_value_shapes member appended to `MUTABLE container: T[]@list = []` via GIVE / COPY / bare. Registry-driven; unsupported element shapes are explicit compile-error cells. |
| `heap_ownership_transfer`   | 89              | ret_form (ident/literal/call/give/or_rescue) x bind_form (bare/or_raise/or_fallback/discard/discard_or_raise/onward) x decl (T/!T) -- the depth axis for :heap_list and :string returns (ported from origin/register-machine #13 manifest). |
| `bg_capture_typing`         | 20              | Type-inference cells for BG-block captures. |
| `bg_copy_param_reentrant`   | 8               | COPY of @list param into BG calling reentrant function. |
| `infallible_signature`      | 60              | Cells exercising infallible (non-`!T`) function signature lowering. |
| `binary_op_matrix`         | 45           | Binary operator lowering/admission combinations, including AND/OR short-circuiting and scalar/managed single-fallback `!?T` collapse. |
| `capability_wrap_matrix`   | 26           | Capability wrapper construction/admission cells, including observable scoped views and rejected direct observable index, operator, field, and method access. |
| `catch_allocator_matrix`   | 20           | Error/catch paths that preserve allocator identity. |
| `catch_reassign_matrix`    | 16           | Catch/fallback reassignment ownership cells. |
| `destructuring_assignment_matrix` | 6      | Fixed-shape destructuring declaration, typed/mutable targets, reassignment, mixed declaration, and discard. |
| `indexed_assignment_matrix`| 20           | Indexed assignment into lists/maps across value shapes. |
| `indirect_recursive_union` | 12           | Recursive union payloads through indirect storage. |
| `match_matrix`             | 18           | MATCH lowering over union/scalar shapes plus AS payload bindings. |
| `mir_lowering_shape_matrix` | 87          | MIR lowering shape coverage for list/hash literals, var declarations, returns, branch locals, function args, loop locals, and node dispatch shapes. |
| `stream_into_boundary`      | 66           | NEXT value passed across BG / DO / BG STREAM boundary, all sync wrappers |
| `lifetimed_return`          | 36           | BG handle escape rejection — exercises bg_lifetime_sources stamping |
| `link_resolve_matrix`       | 7            | Managed Rc/Arc weak-link liveness, repeated resolution, list storage, and dead-owner behavior. |
| `managed_payload_capability_matrix` | 22   | String-owning payloads through generic Rc/Arc construction, COPY, collection, optional, union, and cleanup operations. |
| `auto_ownership_transport_matrix` | 19   | DEFAULT move/borrow/materialization plus binding/field, nested-place, stdlib, user-method, user-function, branch, loop, Rc, nested-boundary, lambda-capture, and shadowing cases. Mutation comes from resolved contracts and binding IDs, never a name list or custom walker. |
| `node_graph_matrix`         | 7            | Managed `@node` cycles, replacement, optional chains, handle reuse, 5,000-node growth, and lexical teardown. |
| `shared_node_graph_matrix`  | 6            | Guarded `@shared:node` cycles, replacement, managed reads, 5,000-node growth, parallel mutation, and local-node rejection. |
| `recursive_execution_boundary_matrix` | 14 | Recursive aggregate admission across `@multiowned`/`@shared` fields and parallel BG boundaries. |
| `stateful_container_matrix` | 16           | Numeric/string maps under overwrite, delete/reinsert, COPY, and active-borrow invalidation. |
| `access_gate`               | 100             | WITH-alias escape rules — 5 alias-perm tuples × 10 patterns |
| `polymorphic_sync_admission`| 30              | Which (callee × caller binding) tuples are admitted |
| `execution_boundary`        | 81              | What can / can't cross BG / DO / BG STREAM × @parallel / @pinned |
| `promise_handle_capture`    | 9               | Plain `~T` promise handles moved into BG consumers and rejected on outer reuse |
| `loop_cleanup`              | 40              | INV-2 / INV-6: alloc-cleanup pairing under loop disruptors (break, continue, return, raise) |
| `error_cleanup`             | 24              | INV-9: alloc-cleanup pairing on error paths (OR PASS / RAISE / DEFAULT) |
| `branch_cleanup`            | 48              | INV-2: alloc-cleanup pairing across IF/ELSE branches with optional early-return |
| `or_positional`             | 60              | `expr OR <action>` in every syntactic position × action × inner outcome |
| `cond_or_fallback`          | 12              | `(maybe(...) OR fallback) <cmp> baseline` inside IF / WHILE conditions. Surfaces bug #1 (lower_if hoist ordering) per docs/agents/clear-bug123-forensic.md — `:heap_string` cells fail today, pass once lower_if isolates cond `@pending_stmts`. |
| `loop_local_method_temp`    | 12              | Method-call result bound as a per-iteration temp inside WHILE / FOR. Surfaces bug #2 (FRAME_NO_REWIND lowering-synthesis gap) per docs/agents/clear-bug123-forensic.md — `:split` cells fail today, pass once `LoopFrameAnalysis.local_frame_decls` recognises stdlib-method frame returns. |
| `bind_capture_cleanup`      | 32              | Owned bind cleanup plus borrowed/owned Rc/Arc bindings across list, map, pool, optional field/local, calls, COPY, CLONE, SHARE, multi-bind, pop, and map-value materialization. |
| `rc_generic_collection_matrix` | 62           | Full ownership-sensitive generic list/pool/set/map and sharded materialization operation × Rc/Arc capability cross-product. |
| `rc_generic_value_matrix` | 12                | Recursive struct/union/optional/list/map COPY and materialization shapes × Rc/Arc capability cross-product. |
| `cleanup_classifier_shapes` | 20              | Cleanup-classifier shape coverage for struct/union/option/capability/pipeline payloads. |
| `cross_fiber_consumer`      | 21              | BG STREAM / observable producer values consumed across fiber boundaries. |
| `loop_local_cleanup_alloc`  | 16              | Loop-local allocation forms that must be cleaned or promoted consistently, including direct `String[]@list` locals. |
| `match_payload_cleanup`     | 8               | MATCH payload cleanup for owned payload variants/options. |
| `thunk_recursion_matrix`    | 43              | Direct and mutual `REENTRANT:THUNK` recursion across return/argument shapes, including owned accumulators and struct payloads. |
| `fsm_suspension_matrix`     | 38              | FSM splitter shapes: NEXT, WHILE/FOR/FOREACH, IF, WITH, BG STREAM YIELD, owned suspend results, lock segments, and stream cleanup. |
| `auto_inference_matrix`     | 15              | Explicit `Auto` inference and rejection paths across params, returns, locals, empty containers, ambiguity, unresolved slots, and parser-admission guards. |
| `fsm_edge_matrix`           | 8               | Additional FSM splitter edges around OR fallbacks, nested loop/branch suspension, stream branches, locks before NEXT, and known early-return lowering failures. |
| `diagnostic_policy_matrix`  | 16              | Policy-heavy front-end diagnostics for reentrancy, hold-lock-across-yield, lock ordering, handlers, and ownership/fixable rejection paths. |
| `pipeline_source_shape_matrix` | 44           | Pipeline source/terminal shapes across range, BG STREAM, bounded promises, strings, and observable terminals. |
| `pipeline_gap_matrix`        | 8            | Focused pipeline operator gaps: TAKE_WHILE, SKIP, WINDOW(time), UNNEST bindings, and CONCURRENT terminals. |
| `pipeline_value_block_matrix` | 7            | Source-level value blocks in SELECT, WHERE, ORDER_BY, and lambda positions, including missing-result and bad-predicate rejection cells. |
| `call_ownership_contract_matrix` | 73         | Normal calls, TAKES bare/COPY/GIVE, owned/fallible returns, receiver mutation, BG calls, and pipeline call contracts across string/list/struct/union/nested owned shapes. |
| `collection_iteration_storage_matrix` | 43    | Collection iteration/storage across arrays, lists, sets, maps, pools, nested and SOA containers. |
| `mir_checker_negative_matrix` | 47            | Generated malformed-MIR cells for fail-closed ownership verification: double release/finalizer, implicit move, UAF after transfer, unverifiable joins, aggregate allocator mismatch, return allocator invariants, MIR call contracts, InlineZig/RawZig allocator contracts, invalid allocator facts, missing cleanup finalizers, borrowed capture cleanup, structural Rc/Arc copies, unhoisted allocs, COPY_CLEANUP, and INDIRECT_DOUBLE_BOX. |
| `or_heap_destination_matrix` | 168            | Owned OR / TryCatch / optional branch results placed into return, local, field, list, call, and branch destinations across string/list/struct/union/nested owned shapes. |
| `owned_sink_destination_matrix` | 240         | Owned source expressions crossed with return, field, list, map, TAKES, and normal call sinks across string/list/struct/union/nested owned shapes. |
| `union_lowering_cleanup_matrix` | 36         | Union helper lowering and recursive cleanup for string/list/map/inline-struct/nested payload variants. |
| `builtin_emit_matrix`       | 16              | Source-level builtin emission through strings, collections, union active tags, and pipeline terminals. |
| `bg_capture_transfer_matrix` | 144            | BG / DO / BG STREAM capture-transfer roots across string/list/struct/union/nested owned shapes and borrow/COPY/GIVE/call/member/index/returned-handle modes. |
| `cast_lowering_matrix`      | 30              | Annotation-driven MIR cast/coercion lowering across var, return, call, list, and branch contexts. |
| `hoist_edge_matrix`          | 43              | Nested allocating expressions in return, local, field, list, call, branch, OR fallback, loop, match, collection literal, and nested aggregate contexts. |
| `access_path_expression_matrix` | 35          | Field/index/optional/map/nested access paths through local, return, call, branch, and loop contexts. |
| `collection_sink_escape_matrix` | 18          | Owned string/struct/union values stored into list/set/map/pool and collection-literal sinks. |
| `cleanup_control_matrix`     | 56           | Cleanup-bearing value shapes crossed with branch, loop, match, catch, return, move, GIVE, and discard. |
| `lowering_boundary_matrix`   | 28           | MIR lowering boundary coverage for call contracts, WITH variants, BG/DO/NEXT, and pipeline terminals. |
| `test_framework_matrix`      | 6            | TEST/WHEN/TEST THAT grammar through hooks, LET bindings, stubs, pending tests, benchmark, smash, and profile forms. |
| `extern_boundary_matrix`     | 6            | Negative extern declaration/call boundaries for free functions, trampolines, extern methods/resources, generic comptime calls, and tight-loop rejection. |
| `curated_gap_corpus`         | 477          | Self-contained `transpile-tests/*.clear` corpus reused as broad compile-mode fuzz coverage for parser, annotator, MIR lowering, and emission. |
| `tense_predicate_matrix`     | 11           | Postfix tense predicates, stacked refinement, readiness polling, and ambiguous optional-Boolean rejection. |

### `stream_into_boundary` matrix

Combinatoric set for "STREAM nexts passed in DO / BG / BG STREAM blocks".
Per-cell parameters:

- `consumer` ∈ {bg, do, bg_stream}
- `ownership` ∈ {local, shared}                 (per spec — @multiowned/@boxed cannot cross)
- `sync` ∈ {none, locked, write_locked, atomic, versioned}
- `move` ∈ {borrow, copy, give, clone, lend}    (CLONE only for @shared/@split)
- `value` ∈ {int, string, struct}               (struct used for non-atomic @shared cells)

**Phase A** (12 active): `@local` × {borrow, copy} × {int, string} × 3 consumers.
DO+@local+borrow+string is expected `:compile_error`; DO+@local+copy+string is legal
because each branch receives its own owned copy.

**Phase B** (36 active): `@shared` with each of 4 sync wrappers ×
{borrow, copy, clone} × 3 consumers. Per-sync value: `@atomic` uses Int64 (bare
Atomic, no Arc); `@locked` / `@writeLocked` / `@versioned` use a Counter struct.
Access dispatch: WITH EXCLUSIVE for locked/writeLocked, WITH SNAPSHOT for versioned,
direct read for atomic primitives.

Findings encoded as `:compile_error` (matrix runs cleanly today):
- DO + @shared (any move): DO branches don't capture outer @shared bindings.
- CLONE + (atomic | locked | writeLocked | versioned): "CLONE only supported on
  @split streams, @shared promises, owned shared handles". Bare Atomic primitives
  and sync-wrapped structs aren't recognized as Arc'd by CLONE.

Outstanding `:pass` failures (real findings the matrix surfaces):
- (BG | BG STREAM) + atomic + (borrow | copy) + Int64: BG body capture yields
  `*AtomicInt(i64)` instead of auto-loading. Workaround in test corpus (test 339)
  is to call a helper fn with `REQUIRES c: ATOMIC` rather than read directly.
- (BG, versioned, copy, struct): single edge case currently MIR-fails.

LEND is not included because it is not a CLEAR keyword. When LEND lands, its
escape-poisoning rules must be added directly as active negative-test cells
(`expected: :compile_error`).

### `access_gate` matrix

Verifies CLAUDE.md's non-escaping rule: aliases bound by `WITH (EXCLUSIVE |
BORROWED | RESTRICT | SNAPSHOT)` cannot escape their block. The legal
exception is `RETURN COPY alias`.

5 alias-perm tuples (alias kind forces the permission):

| Alias | Permission | Notes |
|---|---|---|
| `EXCLUSIVE` | `@locked`, `@writeLocked` | mutable, exclusive |
| `BORROWED`  | plain (no perm)            | read-only borrow |
| `RESTRICT`  | plain (no perm)            | mutable borrow on a MUTABLE source |
| `SNAPSHOT`  | `@versioned`               | read-only snapshot |

× 10 patterns per cell (2 baselines + 8 escape attempts) = **50 cells**.

Patterns:

- `baseline_use` — `WITH ... { x = ref.value }` (no escape) — `:pass`
- `baseline_copy_return` — `WITH ... { RETURN COPY ref }` — `:pass`
- `return_alias` — `RETURN ref` — must reject
- `return_field` — `RETURN ref.value` — must reject (CLAUDE.md: any
  GetField/GetIndex chain rooted at non-escaping symbol)
- `bg_capture` — `RETURN BG { ref.value }` — must reject
- `do_capture` — `append(handles, BG { ref.value })` inside WITH — must reject
- `bg_stream_capture` — `RETURN BG STREAM { YIELD ref.value }` — must reject
- `takes_consume` — `consume!(GIVE ref)` — must reject
- `store_field` — `outer.field = ref` — must reject
- `list_append` — `list.append(ref)` — must reject

**Findings on the current tree** (4 cells `:pass`-marked but currently fail):

The escape-rule rejection is solid — all 40 negative cells properly
reject with the right diagnostic ("Cannot RETURN 'ref' from inside a WITH
block. WITH aliases are borrows..."). The bugs surfaced are in the LEGAL
path:

- `(exclusive, locked, baseline_copy_return)` — Zig codegen error
  "expected error_union, found *T". `RETURN COPY ref` lowers to a `*T`
  pointer instead of a Counter value.
- `(exclusive, write_locked, baseline_copy_return)` — same
- `(restrict,  plain,        baseline_copy_return)` — same
- `(snapshot,  versioned,    baseline_copy_return)` — same
- `(borrowed,  plain,        baseline_copy_return)` — **passes** (the
  one alias kind where COPY return is correctly lowered)

The unit test `spec/with_alias_escape_spec.rb` "allows RETURN COPY of an
EXCLUSIVE alias" stops at annotation and never observes the codegen-
level type mismatch. The matrix end-to-end run does. This is exactly
the gap the harness was added for.

### Cleanup-correctness matrices (B1: three focused templates)

`loop_cleanup`, `error_cleanup`, and `branch_cleanup` share a common
dimensions module (`templates/_cleanup_dimensions.rb`) so adding a new
allocation kind propagates to all three. Each template owns its
control-flow dimension (loop disruptors, error patterns, branch shapes)
since those are template-specific.

The shared module exposes `ALLOC_KINDS` (`:heap_list`, `:heap_string`,
`:frame_string_concat`, `:frame_list`), `VALUE_DESTS`, and helpers for
emitting allocation declarations and use statements.

Together these stress INV-2 (every alloc has a cleanup on every path),
INV-6 (loop bodies that frame-allocate have per-iteration mark/rewind),
and INV-9 (error paths preserve allocator identity). The matrix surfaces
many findings — see `docs/agents/formal-verification-bugs.md` for the
catalogue.

### `execution_boundary` matrix

Verifies the modifier × ownership rules from `src/ast/diagnostic_registry.rb`.
Cross-product:

- `boundary` ∈ {bg, do, bg_stream}
- `modifier` ∈ {none, @parallel, @pinned}
- `ownership` ∈ {@local, @shared:locked, @multiowned}

= **27 cells**.

Expected (per docs/sharing-capabilities.md + diagnostic registry):

- `(any boundary, @parallel, @local)` → reject ("@local variable cannot
  be used in @parallel block")
- `(any boundary, @parallel, @multiowned)` → reject ("@multiowned (Rc)
  variable cannot be used in @parallel block")
- `(any boundary, @parallel, @shared:locked)` → accept
- All `(none | @pinned)` cells → accept

**Findings on the current tree** (8 cells fail end-to-end):

- `DO + @local` and `DO + @multiowned` (modifier none or @pinned, 4 cells):
  DO branches lower to inner Zig fns that don't close over outer @local /
  @multiowned bindings. Existing test corpus only uses DO with
  `@shared:locked` state. Either DO should learn to capture these, or the
  docs should clarify that DO requires @shared.
- `BG STREAM + @parallel` and `BG STREAM + @pinned` (4 cells): the BG
  STREAM parser has no equivalent of `parse_bg_prefix` — modifier sigils
  inside the stream body don't parse. Inconsistent with BG which does
  accept them. Either BG STREAM should accept modifiers OR the
  diagnostic registry should document the limitation.

The @parallel-with-@local and @parallel-with-@multiowned rejections fire
correctly across all 3 boundaries — diagnostic enforcement is solid for
those rules.

### `polymorphic_sync_admission` matrix

Verifies which (callee signature × caller binding) combinations the
annotator admits. Cross-references the `LOCAL` family viralization
concern: should `LOCAL` stay admissible alongside `LOCKED` in the same
REQUIRES clause?

6 callee forms × 6 caller bindings = **36 cells**.

Callee forms:

- `:concrete` — `FN tick!(MUTABLE c: Counter) RETURNS Void`
- `:shared_param` — `FN tick!(MUTABLE c: SHARED Counter) RETURNS Void`
- `:req_locked` — `REQUIRES c: LOCKED`, body `WITH POLYMORPHIC EXCLUSIVE`
- `:req_versioned` — `REQUIRES c: VERSIONED`, body `WITH SNAPSHOT ... ON MvccConflict RAISE`
- `:req_local` — `REQUIRES c: LOCAL`, body `WITH POLYMORPHIC c`
- `:req_locked_or_local` — `REQUIRES c: LOCKED | LOCAL`, body `WITH MATCH`

Caller bindings: `@locked`, `@writeLocked`, `@versioned`, `@local`,
`@multiowned`, plain.

Expected admissions per docs/sharing-capabilities.md:

| Callee | Admits |
|---|---|
| `:concrete` | plain only |
| `:shared_param` | locked, writeLocked, versioned (any `@shared:*`) |
| `:req_locked` | locked, writeLocked |
| `:req_versioned` | versioned |
| `:req_local` | local, multiowned, plain |
| `:req_locked_or_local` | union of LOCKED + LOCAL |

**Findings on the current tree** (1 UNEXPECTED-PASS + 12 MIR-FAILs):

- `(concrete, @local)` UNEXPECTED-PASS — concrete callee accepts `@local`.
  Per docs it should only accept plain `T`. Either documentation gap or
  admission too lax. This is the canonical viralization-risk surface from
  the language design discussion.
- `SHARED T` rejects `@locked` / `@writeLocked` / `@versioned` short
  forms (3 cells) — short forms don't coerce to `@shared:*` at call sites.
  Test 349 uses the explicit `@shared:locked` form which works.
- `WITH MATCH` syntax not parsed — "Unknown WITH capability 'MATCH'"
  (5 cells, all `:req_locked_or_local`). CLAUDE.md describes this; parser
  doesn't accept it yet.
- Codegen issues for some legitimately-admitted cells (`req_locked +
  @locked`, `req_versioned + @versioned`, `req_local + @local`) —
  pointer-deref / error-union-ignored Zig errors. These are the same
  patterns test 349 uses successfully with `@shared:locked` full form;
  short forms (`@locked`) trip a different lowering path.

The unit specs (`spec/sync_polymorphism_integration_spec.rb`,
`polymorphic_transaction_acceptance_spec.rb`) verify dispatch path
selection via Zig string-grep. They don't observe these end-to-end
codegen failures because they stop at annotation or at string-grep
of the emitted Zig.

### `lifetimed_return` matrix

Verifies `bg_lifetime_sources` stamping (`src/annotator.rb:6449`) translates
into ENFORCEMENT — i.e., a BG handle that captures a lifetime-bound source
(@local / @shared:atomic-primitive / @multiowned / @locked) is rejected on
escape attempts.

Cell parameters: `consumer` ∈ {bg, bg_stream} × `ownership` ∈ {local,
atomic_int, locked} × `escape` ∈ {await_in_scope, return_handle,
store_in_field}.

All 18 cells are active. `await_in_scope` is the positive baseline; both
`return_handle` and `store_in_field` must compile-error because the returned
BG handle, or a struct containing it, would outlive the captured source.

### `fsm_lowering` matrix

Stresses CLAUDE.md invariant #13 — "FSM emission is ONE general transform"
— by exhausting cross-products of suspend kinds × control-flow wrappers ×
placements. The 23 named transpile-tests (273-295) cover specific shapes
one-at-a-time; this matrix exercises their cross-products.

Cell parameters:
- `suspend` ∈ `{pure, next, sleep, lock}` — pure (no suspend), NEXT promise,
  IoSuspend (sleep), LockSuspend (WITH EXCLUSIVE on @locked)
- `control_flow` ∈ `{linear, if_branch, while_body, for_range, with_block,
  nested}` — wrap the suspend in each control-flow shape
- `placement` ∈ `{only, two_suspends}` — single suspend or two in sequence
  (cross-segment liveness)

= 4 × 6 × 2 = **48 cells; 6 pruned** (`:pure + :two_suspends` is meaningless
since pure has no suspend) → **42 active cells**, all currently passing.

FSM lowering verified per-cell by checking the emitted Zig contains
`FsmTask` / `submitFsmSpawn` / `spawnFsm` / `tryLockForFsm` markers (vs
the stackful-fiber `submitSpawn` path).

### Cell expectations

Each cell carries an `expected:` annotation:

- `:pass` (default) — must compile, run, and not leak.
- `:compile_error` — must fail compilation (CLEAR-level or Zig-level codegen). Used for
  documented capability boundaries (e.g., `(DO + @local)` — DO branches lower to inner
  Zig fns that don't close over enclosing locals; DO is meant for @shared state).
No inactive or skipped expectation exists. Registration rejects every status
other than `:pass` and `:compile_error`.

The runner reports `UNEXPECTED-PASS` when a `:compile_error` cell compiles successfully —
that's the signal a feature has landed and the cell should be flipped to `:pass`.

Adding a new template = drop a new file under `templates/`. The generator
auto-loads everything in that directory at startup.

## When a fuzz run finds a bug

1. The failing `.clear` is named by content hash, so it's reproducible across
   runs given the same seed and template.
2. Move the failing file from `transpile-tests/fuzz/` into `transpile-tests/`
   with a descriptive name (e.g. `382_loop_local_map_escape.clear`). It becomes
   a permanent regression test caught by `./clear test transpile-tests/`.
3. Fix the underlying bug in `src/`.
4. Re-run the fuzz suite. The newly added permanent test runs as part of the
   main suite; the fuzz suite confirms no other shapes regressed.

## Verification

The system was validated by reverting commit `9fa21926` (loop frame promotion
fix for lists/maps/arrays) in the working tree: `nested_loop_escape` immediately
reported 8/8 failures with `[FRAME_NO_REWIND]` MIR errors. With the fix in
place, the full matrix passes 36/36.

## Design notes

- **Template-based, not grammar-based.** Random AST generation produces 90%
  trivial syntax that doesn't reach MIR. Templates target the bug shapes that
  actually slip through hand-written tests.
- **Per-file `clear test` invocation.** Each generated `.clear` is run through
  `./clear test <file>` which uses `gen.rb --single`. Slower than batching but
  trivial to integrate; switch to a bundled runner if matrix size grows past
  ~200 programs.
- **Static + dynamic oracles.** The MIR checker (9 invariants) catches most
  bugs before codegen; `std.testing.allocator` catches anything that survives
  to runtime as a leak.
- **No formal verification.** The MIR checker already encodes a quasi-formal
  proof of 9 invariants. Going further would cost months for marginal gain
  over randomized stress testing of those same invariants.
