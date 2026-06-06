# Architectural Issues — Compiler State Audit

Conducted 2026-06-02 against the current implementation (load-bearing commit).

## TL;DR

```
src/README.md                B-   stale, too trivial to motivate MIR
src/annotator/README.md      B+   honest about mess, gaps in file map + examples
src/mir/README.md            A-   best structured, stale file paths in stage 5
gems/espalier/architecture.yml     machine artifact, not a human doc
```

The core compiler (annotator + MIR + lowering) is well-designed at the phase ordering
level but has sharply deteriorating cohesion inside the annotator itself. The MIR pipeline
is the strongest architectural decision in the codebase.

---

## 1. `src/README.md` — Top-Level Compiler Overview

### Accuracy

| Claim | Verdict |
|---|---|
| 6 stages: lexer → parser → annotation → pipeline desugar → MIR → emit | True, but hides 8 MIR sub-stages |
| File references exist | True |
| `add_one` example shows `storage: :stack`, `symbol: <resolved...>` | Matches `visit_BindExpr` output |
| Typo: `src/annoator/annotator.rb` | Missing `t` |

### Staleness / Gaps

- **Stage 4 ("MIR Pass / Hoisting / Control Flow") is a black hole.** The actual
  pipeline from `MIRPassState` has 8 distinct sub-stages with enforced ordering:
  `hoisted → premir_type_checked → escape_analyzed → cleanup_classified → loop_frame_analyzed
  → needs_rt_finalized → mir_pass_complete → mir_lowered → mir_checked`. None of this is
  visible from the top-level overview.

- **The example is too trivial to motivate MIR.** `add_one()` uses a stack `Int64`,
  zero ownership complexity, zero allocation, zero branches. A reader finishes the doc
  doubting MIR's reason to exist. The MIR README's `UNION Data` example is much better.

- **No pass ordering diagram.** The MIR and annotator READMEs both have one (text table
  with dependency ordering). This one doesn't.

- **Stage 3** says "pipeline fusion & string concat desugaring" but doesn't mention
  the MIR pipeline lowerers in `src/mir/lower/pipeline` for non-fusable
  pipeline shapes.

### Why It Matters

The top-level README is the first thing new contributors read. If it can't explain *why*
MIR exists, they won't trust the architecture.

---

## 2. `src/annotator/README.md` — Annotator Architecture

### Accuracy

| Claim | Verdict |
|---|---|
| `annotate!` flow: `visit → finalize_auto_types! → run_whole_program_semantics! → run_deferred_validations! → mark_annotation_complete!` | Matches `annotator.rb:423` exactly |
| `visit_Program` sub-steps: imports → types → signatures → reentrance → errors → sync → bodies → finalize | Matches `annotator.rb:534` exactly |
| Type state table (Parsed → Local → Declaration → Auto-resolved → Function → MIR-ready) | Matches implementation |
| "Current Messy Areas" self-assessment | Verifiably honest |

### Staleness / Gaps

- **File map omits `domains/` (7 files, ~16K lines) and `phases/` (12 files, ~2K lines).**
  These are the annotator's actual decomposition. The README lists helpers but ignores the
  two directories that give the annotator real structure.

  Actual directories:
  ```
  src/annotator/domains/
    control_flow.rb        (857 lines)  — IF, MATCH, WHILE, FOR, branches + OG merges
    errors.rb              (753 lines)  — RAISE, CATCH, sync policy, error registration
    execution_boundaries.rb(968 lines)  — RETURN, YIELD, BG, fiber boundaries
    expressions.rb         (443 lines)  — binary ops, unary ops, literals
    lifetimes.rb           (1261 lines) — lifetime tracking, tied lifetimes, non-escaping
    member_access.rb       (545 lines)  — field access, method calls, index ops
    variables.rb           (741 lines)  — declaration, assignment, move, borrow

  src/annotator/phases/
    annotation_boundary.rb (38 lines)  — MIR boundary verification
    auto_finalization.rb   (21 lines)  — Auto inference dispatch
    body_analysis.rb       (85 lines)  — function body dispatch
    builtin_environment.rb (29 lines)  — builtin registration
    declaration_index.rb   (72 lines)  — AST statement classification
    deferred_validation.rb (77 lines)  — WITH post-pass replay
    expression_domains.rb  (288 lines) — visitor dispatch for expression node types
    program_finalization.rb(83 lines)  — whole-program metadata finalization
    signature_registration.rb(54 lines) — signature hoisting entry point
    signature_registry.rb  (86 lines)  — signature construction
    type_registration.rb   (155 lines) — struct/union/enum/resource registration
    whole_program_semantics.rb(138 lines) — caller sync, effects, WITH MATCH, concurrency
  ```

- **Line count of `annotator.rb` in README:** says 1323 lines, actual is 1175 (stale).

- **Zero concrete examples for capability features.** WITH blocks, capability acquisition,
  BG capture classification — all described in prose with zero schematic code. The MIR
  README shows Ruby/Zig snippets at every stage. This is a major asymmetry.

- **The example program (`demo`/`inc`) is too simple.** IF branches, function calls, and
  returns are the easy cases. The 3 hardest annotator domains — capabilities/WITH, effect
  inference, BG capture classification — are entirely absent from the example.

- **"Cleanup Direction" says** "smaller phase objects with explicit inputs/outputs" — the
  `phases/` directory partially achieves this, but the README doesn't reference that
  existing work as progress toward the goal.

---

## 3. `src/mir/README.md` — MIR Architecture

### Accuracy

| Claim | Verdict |
|---|---|
| 12-stage pipeline: `annotated → pipeline_rewritten → ... → mir_checked` | Matches `MIRPassState::STAGES` exactly |
| Pass ordering enforced by `MIRPassState` | Confirmed: `mark!` rejects out-of-order, `require!` rejects missing prereqs |
| Example program (`UNION Data`, `makeData`, `consume TAKES`, `demo` with IF) | Well-chosen — exercises heap alloc, ownership transfer, branch-sensitive cleanup, guarded moves |
| Schematic code at each stage shows evolving representation | Matches the lowering passes |
| "Two jobs" framing (ownership explicit for checking, printer-friendly tree) | Accurate |
| File Map correctly identifies shared analyses in `../semantic` | True |

### Staleness / Errors

- **Stage 5 files: wrong directory.** Says `src/mir/escape_analysis.rb` and
  `src/mir/bg_capture_classifier.rb`. Both live at `src/semantic/escape_analysis.rb`
  (81KB) and `src/semantic/bg_capture_classifier.rb`. The README **contradicts itself**:
  the File Map section at the bottom correctly points to `../semantic/`, but the stage
  description section has the stale paths.

- **`lowering/` subdirectory gets one line.** The 6 files under `src/mir/lowering/`
  (~12K lines total, 40% of MIR directory) are listed by name but never described:

  ```
  lowering/capabilities.rb    (1702 lines) — CapWrap, WithBlock, exclusive/shared acquisition
  lowering/concurrency.rb     (1253 lines) — BG/Fiber/Background lowering
  lowering/control_flow.rb    (1638 lines) — if/match/while/for MIR emission
  lowering/expressions.rb     (2546 lines) — binary/unary ops, calls, field access
  lowering/functions.rb       (2578 lines) — function entry/exit, params, return, cleanup
  lowering/literals.rb        (320 lines)  — literal value emission
  lowering/variables.rb       (1703 lines) — declaration, assignment, move, borrow emission
  ```

- **FSM files mentioned but not explained.** The file map lists `fsm_*` and
  `thunk_transform*` — 5 files totaling ~3K lines — with zero description of what
  background/asynchronous lowering does.

- **No loop frame analysis example.** Stage 7 says "this example has no loop, so nothing
  changes" and moves on. A second mini-example showing a `FOR` loop allocating inside a
  frame arena, and the before/after of frame-save/frame-restore insertion, would close a
  major documentation gap.

- **MIR-adjacent files missing from file map:**
  - `alloc.rb` (77 lines) — allocator type definitions
  - `materialization.rb` (103 lines) — temporary materialization for lowering
  - `fiber_ctx_builder.rb` (290 lines) — fiber context struct construction
  - `test_lowering.rb` (625 lines) — test-only MIR lowering

- **The example Zig output is schematic only.** The README acknowledges this ("The real
  generated Zig may introduce temporaries"), but a side-by-side of schematic-vs-real for a
  small program would calibrate contributor expectations. Without it, new contributors
  can't distinguish "intended MIR shape" from "incidental emission details."

---

## 4. `gems/espalier/architecture.yml`

64,740 lines, 364 modules, 105 classes with `@state` entries. Machine-generated by the
espalier state-audit gem. Exhaustively accurate by construction, but not an architecture
document — it's a verification artifact listing every instance variable, method
signature, and delegation across the entire codebase. Useful for automated conformance
checks, not for human understanding.

---

## Implementation Weaknesses (Cross-Cutting)

### High Severity

| Issue | Details | Files |
|---|---|---|
| **SemanticAnnotator is a God class** | 1175 lines, 33 `include`s, ~25 shared instance variables. Despite `phases/` and `domains/` splitting into separate files, `SemanticAnnotator` mixes them all via Ruby `include` — all shared mutable state is on one object. | `src/annotator/annotator.rb` |
| **Capability handling is deeply interleaved** | Validation, alias construction, effect recording, audit, and lock-graph updates share the same visitor paths. A capability change requires understanding 4+ cross-cutting concerns. The README itself calls this out. | `src/annotator/helpers/capabilities.rb` (1389 lines), `lock_helper.rb` (533 lines), `with_match_check.rb` (530 lines) |

### Medium Severity

| Issue | Details | Files |
|---|---|---|
| **Scope deep-copy contract** | `Scope#dup` deep-copies `SymbolEntry` for branch isolation. Post-pass mutations on canonical entries create stale branch-local copies. Mitigated via `live_param_syms` helpers. This is an acknowledged architectural smell. | `src/ast/scope.rb` |
| **Pipeline rewriter's pass state enforcement is external** | Every other pass calls `MIRPassState.for!(ast).mark!(:stage)` inside its own method. Pipeline rewriter does not — consumers (`compiler_frontend.rb:51`, `importer.rb:182`) call `mark!` after the rewriter returns. This breaks the self-documenting pattern. | `src/backends/pipeline_rewriter.rb`, `src/backends/compiler_frontend.rb` |
| **MIR node definitions monolithic** | `mir.rb` is 3973 lines, all MIR node types in one file. | `src/mir/mir.rb` |
| **annotator `domains/` and `phases/` directories undocumented** | The annotator README's file map ignores these directories entirely. | `src/annotator/README.md` |

### Low Severity

| Issue | Details |
|---|---|
| **Stale file paths in MIR README** | `src/mir/escape_analysis.rb` should be `src/semantic/escape_analysis.rb`. Doc contradicts its own File Map section. |
| **Stale line count** | `annotator/README.md` says `annotator.rb` is 1323 lines, actual is 1175. |
| **`src/README.md` typo** | `src/annoator/annotator.rb` missing `t`. |

---

## README Comparison to Industry Benchmarks

Measured against what you'd find in `rustc-dev-guide`, `go/src/cmd/compile/README`, or
`zig/src/architecture.txt`:

| Quality | rustc | Go | Zig | src/README | annotator README | mir README |
|---|---|---|---|---|---|---|
| Pass ordering documented | Yes (query system) | Yes (ordered list) | Yes (pipeline diagram) | No | Yes (text) | Yes (stages table) |
| Phase input/output contracts | Yes (queries) | Yes (IR forms) | Yes (Sema→ZIR→AIR) | No | Partial | Yes (pass states) |
| Concrete examples per phase | Yes (MIR/HIR examples) | Yes (SSA snippets) | Yes (ZIR→AIR lowering) | Trivial only | Text only, no code | Yes (Ruby+Zig) |
| Self-assessment of mess | Rare | No | No | No | Yes (section) | No |
| File map with responsibilities | Yes | Partial | Yes | No | Partial | Yes |
| Stale references | Machine-checked | Occasional | Occasional | Yes (minor) | Yes | Yes (2 paths) |
| Honest about complexity | Yes ("typeck is hard") | Limited | Limited | No | Yes | Yes |

The MIR README is closest to Zig's pipeline documentation quality — clean pass ordering,
schematic per-stage intermediate results, explicit file map with responsibilities. Falls
short mainly on stale paths and the undocumented `lowering/` subdirectory.

The annotator README is unusual in having an explicit "Current Messy Areas" section — this
is more honest than 95% of industrial compiler docs, which typically don't acknowledge
their own deterioration.

The top-level README is below industry standard — no pass ordering diagram, no phase
contracts, no defense of the MIR decision.

---

## Recommended README Fixes (Priority Order)

### `src/README.md`

1. Replace `add_one` with a program that exercises `TAKES`/`GIVE` and a heap type
   (e.g., `UNION Maybe { None, Some: String }`). Show why MIR is necessary.
2. ASCII pass ordering diagram spanning all 14 actual stages from annotation through
   emission.
3. Fix the `annoator` typo.

### `src/annotator/README.md`

1. Add a WITH block + capability example — CLEAR source to stamped AST.
2. Add a BG block example showing capture classification output.
3. Document the `domains/` directory (7 files, with 1-line responsibilities).
4. Document the `phases/` directory (12 files, with 1-line responsibilities).
5. Update line count: `annotator.rb` is 1175 lines, not 1323.

### `src/mir/README.md`

1. Fix file paths for `escape_analysis.rb` and `bg_capture_classifier.rb` in Stage 5
   (should be `src/semantic/`, not `src/mir/`).
2. Add a loop frame analysis mini-example: `FOR` loop with frame allocation →
   before/after `FrameSave`/`FrameRestore` insertion.
3. Add 1-paragraph-per-file descriptions for `lowering/` subdirectory.
4. Add an FSM lowering section: minimal `BG DO` body with `YIELD` → resulting state
   machine MIR skeleton.
5. Side-by-side schematic-vs-real Zig output for a small program.

---

## 2026-06-02 Follow-Up Assessment

### What Should Become Action Items Now

1. **Update `src/README.md`.**
   This is the highest-value documentation fix. It has a typo
   (`src/annoator/annotator.rb`), no real compiler pass diagram, and an example too
   small to justify MIR. Replace the toy `add_one` example with ownership/allocation
   behavior that explains why MIR exists.

2. **Update `src/annotator/README.md`.**
   The README should document the current `domains/` and `phases/` directories and add
   examples for `WITH`, capability checking, BG capture classification, and deferred
   validation. This is documentation debt, not a reason to restart the annotator
   refactor.

3. **Update `src/mir/README.md`.**
   Fix stale `escape_analysis.rb` / `bg_capture_classifier.rb` paths, describe
   `lowering/*`, and add sections for FSM and thunk lowering. This is especially
   important now that FSM/Thunk lowering has an architectural invariant banning regex
   and regex-driven rewrites.

4. **Consider moving `pipeline_rewritten` marking behind the PipelineRewriter API.**
   The current external marking in `compiler_frontend.rb` and `importer.rb` is a small
   footgun. This is a contained code action if done carefully: callers should not be
   responsible for remembering a pass-state mark that belongs to the producer.

### What Should Not Become Action Items Now

1. **Do not split `src/mir/mir.rb` only because it is large.**
   The file is big, but splitting node definitions without changing boundaries is mostly
   organization churn. It should wait until there is a concrete ownership boundary or
   generated-node registry need.

2. **Do not start another broad SemanticAnnotator phase-object rewrite right now.**
   The report is correct that the annotator still uses many mixins over one shared
   object, but recent work already made the phase/domain layout v0.1-ready. Further
   isolation is useful, not urgent.

3. **Do not tackle `Scope#dup` as a quick cleanup.**
   The deep-copy SymbolEntry contract is a real smell, but it is documented and mitigated
   through `Scope.live_param_syms`. Replacing it is high risk and should be its own
   design effort with branch-flow tests.

### Inaccurate Or Stale Claims

- `annotator.rb` is currently about 1.2K lines, not the older values cited elsewhere.
- `mir.rb` is currently about 3.5K lines, not 3.9K.
- The annotator `domains/` total is about 6.5K lines, not 16K.
- Capability helper sizes are stale after recent refactors.
- FSM/Thunk findings are stale: regex/text rewrite removal is complete for FSM/Thunk
  lowering, and the architecture invariant now passes.

### What The Report Missed

1. **The `src/semantic/` layer deserves first-class architecture documentation.**
   Escape analysis, BG capture classification, effect inference, and ownership graph are
   load-bearing compiler phases, not incidental helpers.

2. **Pass handoffs are the most important architecture surface.**
   A useful architecture doc should show annotator -> semantic passes -> MIR pass state
   -> lowering -> checker -> emitter, including who is allowed to mutate which facts.

3. **Espalier is a state inventory, not a pass-order review.**
   It is helpful for finding stateful modules and ivars, but it should be paired with
   pass-state invariants and "single writer" rules to catch real compiler architecture
   hazards.

4. **FSM/Thunk lowering should be called out as an async-lowering subsystem.**
   The current docs mention these files only lightly. They now have enough architectural
   structure to document: structural context references, no regex rewrites, typed FSM op
   paths, and MIR-based cleanup validation.
