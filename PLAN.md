# PLAN: Rust-Like Ownership Verification for CLEAR

## Foundation: What Makes Rust's System Work

Rust's memory safety comes from **one analysis** enforcing **three rules** at **every program point**.

### The One Analysis: Forward Ownership Dataflow

At every statement in the CFG, every variable has a known state:

```
State = :uninit | :live | :moved | :maybe_moved
```

Transitions:
- **Declaration**: `uninit -> live`
- **Move** (assign non-Copy, GIVE, TAKES arg, return): `live -> moved`
- **Branch merge**: `live + moved -> maybe_moved`

### The Three Rules

**Rule 1 - No use after move.** At every READ of variable `x`, state must be `:live`. If `:moved` or `:maybe_moved` -- compile error.

**Rule 2 - Cleanup at scope exit.** At every scope exit, for each variable in scope:
- `:live` with cleanup-needing type -> unconditional cleanup
- `:maybe_moved` -> conditional cleanup (runtime flag)
- `:moved` -> nothing
- `:uninit` -> nothing

**Rule 3 - No double free.** A `:moved` variable must never be cleaned up. Falls out of Rule 2 mechanically.

Leaks caught by Rule 2. Use-after-free caught by Rule 1. Double-free caught by Rule 3.

---

## How CLEAR Adapts This

CLEAR has a **frame arena** (bump allocator). This changes one thing about Rule 2:

### Not all live variables need explicit cleanup

- **Heap-allocated, any type** -> needs explicit cleanup
- **Frame-allocated, pure frame** (list, map, struct where everything is frame) -> **no cleanup**. Frame rewind bulk-frees.
- **Frame-allocated, has heap internals** (RC field, resource, mutex) -> needs cleanup of those internals

So:
```
needs_explicit_cleanup?(type, allocator) =
  false   if type is Copy (primitives, strings, enums)
  true    if allocator == :heap
  true    if type has heap internals (RC, resource, mutex) regardless of allocator
  false   otherwise (pure frame - arena rewind handles it)
```

### Promotion is an ownership transfer

```
promote(x) =
  heap_copy = CheatLib.promote(T, rt, &x)   # new heap allocation
  x -> :moved                                 # frame original abandoned
  return heap_copy                            # caller owns heap copy
```

Frame rewind handles the physical memory of the original. The caller owns the heap copy. PreserveAndRewind is the mechanism - it's correct and stays.

### CheatLib.cleanup is the unified drop

Already equivalent to Rust's `Drop::drop()`. Handles every type through Zig comptime dispatch. The 20+ cleanup kinds in CleanupClassifier are just routing to this one function. The runtime is correct.

---

## What's Broken in the Current System

### 1. No use-after-move checking
`OwnershipDataflow` tracks moves for cleanup decisions but never reports an error when a moved variable is used. Every use-after-free bug is invisible.

### 2. Cleanup decisions are separate from ownership state
`CleanupClassifier.classify` runs independently from `OwnershipDataflow`. It determines `needs_cleanup` and `has_moved_guard` from type context. Then `refine_moved_guards!` patches results using dataflow. When they disagree: leaks or double-frees.

### 3. Verification is global, not per-path
`MIRChecker` collects all `AllocMark` and `Cleanup` nodes into flat sets and checks set containment. A cleanup that exists on one branch but not another passes. A variable that leaks on an error path passes.

### 4. Too many concepts
Current pipeline: `PromotionClassifier` -> `CleanupClassifier` -> `OwnershipDataflow` -> `refine_moved_guards!` -> 7 MIR marker types -> `MIRChecker` with 13 error codes.

Target: `OwnershipState` -> 3 rules -> done.

---

## Phases

### Phase 1: Enrich OwnershipDataflow

**Current**: Tracks `{ var_name => :owned | :moved | :maybe_moved | :uninit }` per block.

**Target**: Tracks `{ var_name => OwnerEntry }` per statement.

```ruby
OwnerEntry = Struct.new(
  :state,          # :live, :moved, :uninit, :maybe_moved
  :allocator,      # :frame or :heap (fixed at declaration)
  :needs_cleanup   # bool - does this type+allocator need explicit cleanup?
)
```

Changes:
- `OwnershipDataflow#analyze!` stores per-statement snapshots
- `init_entry_state` populates allocator + needs_cleanup for TAKES params
- `transfer_stmt` for VarDecl/BindExpr sets allocator + needs_cleanup from type info
- Join logic carries allocator + needs_cleanup through merges

Stays the same:
- CFG construction
- Transfer functions for moves (GIVE, was_moved, BG captures)
- Join rules (live+moved=maybe_moved)
- Copy type detection

**Files**: `src/control_flow.rb` (OwnershipDataflow class)

#### Tasks
- [x] 1.1: Define OwnerEntry struct with state/allocator/needs_cleanup
- [x] 1.2: Add per-statement snapshot storage to OwnershipDataflow (`@point_states`)
- [x] 1.3: Populate allocator + needs_cleanup in `init_entry_state` for TAKES params
- [x] 1.4: Populate allocator + needs_cleanup in `transfer_stmt` for VarDecl/BindExpr
- [x] 1.5: Carry allocator + needs_cleanup through join logic (merge preserves these fields)
- [x] 1.6: Store state snapshot after each statement in `apply_transfer`
- [x] 1.7: Update `cleanup_summary` to read from enriched OwnerEntry
- [x] 1.8: Tests: verify enriched dataflow produces identical cleanup_summary as current for all existing tests
- [x] 1.9: Implement `needs_explicit_cleanup?` helper: Copy->false, heap->true, frame+heap_internals->true, else false

### Phase 2: Use-After-Move Checking (Rule 1)

New verification pass that walks every expression and checks:

```ruby
def check_use_after_move!(fn_node)
  # For each statement at each program point:
  #   For each Identifier read in the statement:
  #     Look up state in point_states
  #     If :moved -> error: "use of moved variable"
  #     If :maybe_moved -> error: "use of possibly moved variable"
end
```

Catches:
- `GIVE x` followed by `print(x)` -> use after move
- `RETURN x` in one branch, `x.append(y)` after the if -> use of maybe_moved
- `foo(GIVE x)` followed by `bar(x)` -> use after move

**Files**: `src/control_flow.rb` (new method on OwnershipDataflow or companion class)

#### Tasks
- [x] 2.1: Implement expression walker that collects all Identifier reads from a statement
- [x] 2.2: Implement `check_use_after_move!` that walks statements and checks each read against point_state
- [x] 2.3: Handle edge cases: CopyNode (source NOT consumed), was_moved args (legitimate move at call site)
- [x] 2.4: Report errors with source location (line/col from token)
- [x] 2.5: Wire into compilation pipeline (after OwnershipDataflow.analyze!, before MIR insertion)
- [x] 2.6: Tests: write spec cases for use-after-move, use-after-GIVE, use-of-maybe-moved, valid-use-after-COPY
- [x] 2.7: Run full test suite - fix false positive (union constructor vs method call in collect_ownership_transfers)

### Phase 3: Derive Cleanup Decisions from Ownership State (Rule 2)

Replace CleanupClassifier's needs_cleanup/has_moved_guard logic with ownership state.

New method on OwnershipDataflow:
```ruby
def cleanup_decisions
  decisions = {}
  exit_states.each do |name, entry|
    case entry.state
    when :live
      decisions[name] = { needs_cleanup: true, has_moved_guard: false, allocator: entry.allocator } if entry.needs_cleanup
    when :maybe_moved
      decisions[name] = { needs_cleanup: true, has_moved_guard: true, allocator: entry.allocator } if entry.needs_cleanup
    end
  end
  decisions
end
```

CleanupClassifier reduced to template lookup only:
```ruby
# Given type + allocator, return the cleanup kind (Zig template selector)
# Purely about HOW to clean up, not WHETHER.
def self.cleanup_template(type, allocator, schema_lookup)
  return :resource if type.resource?(schema_lookup)
  return :list if type.list_collection?
  return :rc if type.any_rc? || type.link?
  # ... same type dispatch, no ownership context
end
```

Deleted:
- `CleanupClassifier`'s needs_cleanup / has_moved_guard logic
- `refine_moved_guards!`
- `pre_mark_bg_resource_captures!`

**Files**: `src/control_flow.rb`, `src/promotion_plan.rb`

#### Tasks
- [x] 3.1: Implement `cleanup_decisions!` method on OwnershipDataflow
- [ ] 3.2: Implement `cleanup_template(type, allocator, schema_lookup)` - pure type->kind lookup (deferred: incremental)
- [x] 3.3: Validation gate: 2070 specs + 269 transpile tests pass with cleanup_decisions!
- [x] 3.4: Update `MIRPass#transform_function!` to use `cleanup_decisions!`
- [x] 3.5: MIRPass now calls `df.cleanup_decisions!(fn, bindings)` directly
- [x] 3.6: Delete `refine_moved_guards!` method from MIRPass
- [ ] 3.7: Delete `pre_mark_bg_resource_captures!` method (deferred: redundant but harmless)
- [ ] 3.8: Simplify CleanupClassifier: remove ownership-dependent logic (deferred: incremental)
- [ ] 3.9: Delete `walk_takes_params` ownership logic (deferred: incremental)
- [ ] 3.10: Delete `walk_match_as_bindings` ownership logic (deferred: incremental)
- [x] 3.11: Full test suite validated - all pass with identical output

### Phase 4: Flow-Based Verification (Replace MIRChecker)

Rewrite MIRChecker to use per-statement state.

```ruby
class FlowChecker
  def check_fn!(fn_def, point_states)
    # At each MIR::Drop: verify variable is live or maybe_moved (not :moved without guard)
    # At each MIR::SuppressCleanup: verify variable was actually moved
    # At function exit: verify no live cleanup-needing variable lacks a Drop
  end
end
```

Error codes reduce from 13 to 5:
1. `USE_AFTER_MOVE` - from Phase 2
2. `LEAK` - live variable without cleanup at scope exit
3. `DOUBLE_FREE` - cleanup of moved variable without guard
4. `ORPHAN_SUPPRESS` - suppress on non-moved variable
5. `FRAME_OVERFLOW` - loop without rewind (unchanged)

Gone: `ALLOC_MISMATCH` (allocator fixed at declaration), `ESCAPE`/`FRAME_ESCAPE`/`BG_ESCAPE` (promotion modeled as move), `GUARD_NO_SUPPRESS` (guards from state), `REASSIGN_LEAK`/`FIELD_LEAK` (Rule 2 handles), `HPT_LEAK` (simple expression check), `RAW_CONTRACT` (deprecated).

**Files**: `src/mir_checker.rb` (rewrite)

#### Tasks
- [x] 4.1: Analyzed MIRChecker (post-lowering, set-based) - FlowChecker operates at AST level (pre-lowering, ownership-aware)
- [x] 4.2: Implemented LEAK check: every needs_cleanup binding must have MIR::Drop in AST
- [x] 4.3: Implemented ORPHAN_DROP check: every MIR::Drop must correspond to needs_cleanup binding
- [x] 4.4: Implemented ORPHAN_GUARD check: SuppressCleanup for never-moved variable (via dataflow)
- [x] 4.5: Ported FRAME_OVERFLOW to AST level (WhileLoop.mark_per_iter, ForRange.mark_per_iter, tight loops exempt)
- [x] 4.6: HPT_LEAK stays in MIRChecker (requires lowered MIR expression analysis)
- [x] 4.7: FlowChecker wired into MIRPass.transform_function! alongside post-lowering MIRChecker
- [x] 4.8: Both checkers pass on 2070 specs + 269 transpile tests + 0 leaks
- [x] 4.9: Decision: keep both as defense-in-depth (FlowChecker pre-lowering + MIRChecker post-lowering)
- [x] 4.10: Full test suite validated

### Phase 5: Model Promotion as Move in Dataflow

Ensure `OwnershipDataflow` correctly models promotion as ownership transfer.

Key finding: CLEAR's arena model means promotion = copy, not move. The annotator wraps
values in CopyNode for frame-to-heap promotion. CopyNode does NOT consume the source --
the frame original stays alive until frame rewind. This differs from Rust where `return x`
moves x.

Promotion paths and their dataflow modeling:
- `RETURN x` (direct identifier) -> x marked as :moved by collect_binding_moves
- `RETURN Struct{ field: x }` -> x wrapped in CopyNode, stays :owned (copy semantics)
- `GIVE x` on @list -> x wrapped in CopyNode, stays :owned (frame-to-heap copy)
- `GIVE x` on heap type -> x has was_moved flag, marked as :moved
- BG capture of resource x -> x marked as :moved via capture_analysis
- Container store -> value copied/promoted, stays :owned (no ownership transfer)

PromotionClassifier, upgrade_always_escaped_to_heap!, upgrade_bg_captures_to_heap! are
performance optimizations only. Safety is enforced by OwnershipDataflow regardless.

**Files**: `src/control_flow.rb` (verified), `src/promotion_plan.rb` (documented)

#### Tasks
- [x] 5.1: Audit transfer_stmt for ReturnNode: direct identifiers marked :moved, struct literal fields wrapped in CopyNode stay :owned
- [x] 5.2: Audit transfer_stmt for BG captures: resource_captures marked :moved, string captures are Copy
- [x] 5.3: Container store: NOT needed -- CLEAR copies/promotes values into containers, frame original stays alive
- [x] 5.4: Verified upgrade_always_escaped_to_heap! as optimization (dataflow marks returns as moved regardless)
- [x] 5.5: Verified upgrade_bg_captures_to_heap! as optimization (dataflow marks captures as moved regardless)
- [x] 5.6: Documented PromotionClassifier + upgrade methods as performance optimizations
- [x] 5.7: Tests: 6 new specs verify promotion-as-move modeling (direct return, struct literal, CopyNode, GIVE, assignment, TAKES)

### Phase 6: Borrow Checking

Track borrows in the ownership state. WITH blocks create borrows. Borrows prevent moves.

```ruby
# In state: { borrows: { source_name => [borrow_entries] } }

# Can't move while borrowed
if state.borrows[name]
  error("MOVE_WHILE_BORROWED: #{name}")
end

# Can't create mutable borrow while any borrow exists
if WITH RESTRICT && state.borrows[source]
  error("ALIAS_VIOLATION: #{source}")
end
```

**Files**: `src/control_flow.rb` (extend OwnershipDataflow state)

#### Tasks
- [x] 6.1: BorrowChecker class: AST-walk with stack-based borrow tracking (not CFG -- WITH blocks are lexically scoped)
- [x] 6.2: Track RESTRICT as mutable borrow, BORROWED as immutable borrow (EXCLUSIVE/multiowned/shared use runtime protection)
- [x] 6.3: Borrow release on WITH block scope exit (LIFO stack pop)
- [x] 6.4: MOVE_WHILE_BORROWED: check at every move (GIVE, non-Copy assignment, return, BG capture)
- [x] 6.5: ALIAS_VIOLATION: mutable+any overlap or any+mutable overlap (multiple immutable borrows OK)
- [x] 6.6: Nested WITH blocks: stack-based tracking handles naturally
- [x] 6.7: 22 tests: 14 valid programs (no false positives), 4 MOVE_WHILE_BORROWED, 4 ALIAS_VIOLATION
- [x] 6.8: Full suite: 2105 specs + 269 transpile tests + 0 leaks

---

## What Stays, What Changes, What's Deleted

### Stays exactly as-is
- Frame arena strategy (allocate on frame, promote if escaped)
- `CheatLib.cleanup(T, alloc, &var)` - the unified drop
- `CheatLib.promote(T, rt, &var)` - frame-to-heap promotion
- `PreserveAndRewind` - return mechanism
- CFG construction (`FunctionCFG.build`)
- MIR nodes (`MIR::Drop`, `MIR::Alloc`, `MIR::Promote`, `MIR::SuppressCleanup`)
- Transpiler emission (`emit_cleanup_from_entry` and all Zig templates)
- Runtime header (runtime-header.zig, runtime.zig)
- `upgrade_always_escaped_to_heap!` / `upgrade_bg_captures_to_heap!` (optimizations)

### Changes
- `OwnershipDataflow`: enriched state (allocator, needs_cleanup), per-statement snapshots
- `CleanupClassifier`: simplified to template lookup only (no ownership decisions)
- `MIRChecker`: reduced to 2 post-lowering checks (HPT_LEAK, INLINE_ALLOC_MISMATCH)
- `MIRPass#transform_function!`: cleanup decisions from dataflow, not classifier

### Deleted
- `refine_moved_guards!` (dataflow handles it)
- `pre_mark_bg_resource_captures!` (dataflow handles BG as moves)
- `CleanupClassifier`'s needs_cleanup / has_moved_guard logic
- 11 MIRChecker error codes (`LEAK`, `ORPHAN`, `ALLOC_MISMATCH`, `ESCAPE`, `FRAME_ESCAPE`, `BG_ESCAPE`, `GUARD_NO_SUPPRESS`, `REASSIGN_LEAK`, `FIELD_LEAK`, `RAW_CONTRACT`, `FRAME_OVERFLOW`) -- replaced by FlowChecker/UseAfterMoveChecker/BorrowChecker pre-lowering

### New
- Use-after-move checking (Rule 1) - the critical missing piece
- Per-statement ownership snapshots
- Flow-based verification
- Borrow checking (Phase 6)

---

## Dependency Order

```
Phase 1 (enrich dataflow) --> Phase 2 (use-after-move)
                          --> Phase 3 (cleanup from state)
                          --> Phase 4 (flow-based checker)
                          --> Phase 5 (promotion as move)
                          --> Phase 6 (borrows) [after Phase 2]
```

Phase 1 is the foundation. Phases 2-5 can be done in any order after Phase 1. Phase 6 depends on Phase 2.
