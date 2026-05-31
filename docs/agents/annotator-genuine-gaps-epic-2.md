# Annotator Genuine Gaps Burndown Epic 2

## Baseline

Current comparison point:
`tmp/decomplex-4-audit/after-borrow-source-resolver-20260530-155343`

- SlopCop: 272 genuine gaps, 356 type_norm, 438 diagnostic, 83 dead, 8 defensive.
- Boobytrap hotspots:
  - `src/annotator/helpers/function_analysis.rb`: 83/436 uncovered branches.
  - `src/annotator/helpers/method_analysis.rb`: 11/64 uncovered branches.
  - `src/annotator/helpers/capabilities.rb`: 120/453 uncovered branches.
  - `src/annotator/annotator.rb`: 532/2385 uncovered branches.
  - `src/annotator/helpers/generic_analysis.rb`: 30/260 uncovered branches.
- Target for this epic: close about 40 branches, with genuine gaps moving materially down.

## What The Last Epic Proved

Low-yield pattern:

- One-off unit specs closed 1-2 genuine gaps per item.
- Direct private-method coverage helped branch coverage, but did not address the architecture that created the branches.
- Capability and borrow-source edge-case tests were worth keeping only because they were compact and did not regress other categories.

High-yield pattern:

- Contract tightening had the best return. The collection method registry contract dropped method-analysis uncovered branches from 31/100 to 11/64 with little production code.
- Source simplification beat test expansion. Narrowing impossible assignment target shapes and deleting duplicate optional paths improved true/type_norm/boobytrap while reducing source code.
- The strongest prior branch work in `decomplex-3` and `mir-hardening` deleted duplicated walkers or moved repeated decisions behind an existing fact contract:
  - `Replace annotator capture walkers`: large source deletion and fewer capture-specific branches.
  - `Collapse duplicate MIR ownership walkers`: removed duplicate traversal code instead of testing each traversal arm.
  - MIR placement/type hardening: made downstream code consume facts instead of re-deriving ownership/type shape.

## Epic Strategy

Do not start with tests. Start by proving which top-ranked branches are impossible, duplicated, or already represented by a stamped fact. Add tests only after a branch survives that audit as a real semantic language case.

For each item:

1. Snapshot current reports.
2. Inspect SlopCop rows, branch arms, and Decomplex convergence for the target.
3. Try to delete duplicated shape checks or tighten the local contract.
4. Run focused specs and Sorbet.
5. Regenerate full coverage and all three reports.
6. Keep the item only if genuine gaps, type_norm, Boobytrap, or source LOC move convincingly in the right direction.

## Work Items

### 1. Function And Call Signature Contracts

Target:
`src/annotator/helpers/function_analysis.rb`, especially `resolve_call`, `verify_function_signature!`, `verify_param_lifetime!`.

Why first:
Boobytrap ranks this as the highest-risk annotator file. Decomplex points at repeated `params`, `return_type`, `return_lifetime`, and shape guards. This resembles the MIR wins: one contract fix can remove downstream branching.

Plan:
Audit all call sites that still treat function signatures, params, or lifetime sources as loose shapes. If construction already normalizes them, delete downstream guards. If not, move normalization to the signature seam and add one invariant spec.

Expected impact:
10-15 branch closures if the loose-shape guards are truly legacy.

### 2. Pipeline Fact Derivation

Target:
`src/annotator/helpers/pipe_analysis.rb` and the top SlopCop rows around named-function, identifier, select-family, distinct, shard, and concurrent operators.

Why second:
Many top genuine gaps cluster in pipe analysis, but previous direct tests were modest. A table/fact contract or small fuzz expansion can hit many related paths.

Plan:
First look for repeated derivation of input type, receiver type, function signature, and sharding facts. If a helper can return one typed pipe fact already implied by the AST, use that to delete branches. If the branches are semantic operator variants, add a compact fuzz matrix that crosses operator family with input shape.

Expected impact:
10-20 branch closures if the repeated pipe fact derivation collapses.

### 3. WITH Clause Validation Simplification

Target:
`visit_WithBlock`, `validate_lock_error_clause!`, `retryable_with_fallible_sources`, `visit_pre_clauses!`, `visit_post_clauses!`.

Why third:
The current top rows show several WITH/lock/fallible clause gaps. These are likely real semantics, but Decomplex also flags repeated protocol checks around matched stdlib defs and clause scanning.

Plan:
Check whether pre/post/fallible clause handling can share one normalized clause fact instead of branching over raw AST shapes repeatedly. If not, add one integration matrix around WITH mode x clause form x error action.

Expected impact:
8-12 branch closures.

### 4. Field And Index Access Target Facts

Target:
`visit_GetField`, `visit_GetIndex`, assignment field/index helpers.

Why fourth:
These remain top-ranked after several rounds, which means small local edits are not enough. The likely win is making target/root/access mode a reusable fact, not adding more isolated tests.

Plan:
Audit whether `root_identifier`, `get_path_to_root`, `chain_root_name`, receiver type, indirect field state, and container borrow state are re-derived separately. Delete repeated receiver guards only if the AST contract proves the shape.

Expected impact:
6-12 branch closures.

### 5. Cleanup And Lifetime Optional Guards

Target:
`set_cleanup_alloc!`, `init_value_contents_heap?`, `verify_tied_return!`, `resolve_borrow_source`.

Why fifth:
These had low return when tested directly. Only proceed if reports show optional guards that are impossible after current annotation invariants.

Plan:
Audit branches as dead/semantic/classifier noise. Delete only dead contract guards. If branches are semantic, defer unless one compact test covers several.

Expected impact:
0-8 branch closures; this is a stop-loss item, not a primary bet.

## Stop Conditions

- Stop an item early if it adds production code without deleting equivalent or larger branch surface.
- Reject one-off tests unless they cover at least several branches or protect a dangerous bug class.
- Do not add new walkers.
- Do not move conditionals into another helper without reducing total decision count.
- Do not cram statements onto one line to improve LOC optics.

## Outcome

Final report set:
`tmp/decomplex-4-audit/epic-2-final-20260530-173337`

Coverage regenerated with specs, transpile generation, full fuzz matrix, bc-lower coverage, and collation.

- SlopCop genuine: 272 -> 268.
- SlopCop type_norm: 356 -> 355.
- SlopCop dead: 83 -> 81.
- SlopCop diagnostic: 438 -> 441.
- Boobytrap annotator uncovered branches: 1223 -> 1219.
- Decomplex cross-detector convergence: 381 -> 377.
- Decomplex missing abstractions: 41 -> 38.
- Decomplex derived-state staleness: 13 -> 12.
- Decomplex neglected path conditions: 536 -> 532.
- Decomplex broken protocols: 765 -> 759.

Assessment:
This epic was directionally correct but low-yield. The useful source simplification was the local deletion of impossible type/shape guards in function and field handling. The fuzz matrix additions compiled and are broad enough to keep, but they did not materially close the high-ranked pipe gaps. The remaining pipe gaps are mostly structural Decomplex findings, not cheaply burned down by adding a few pipeline examples.
