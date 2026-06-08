# Architectural Review

Branch basis: `architectural-review` from `origin/master` at `7d13c7743`.

Scratch evidence generated during this review, not checked in:

- `tmp/architectural-review-decomplex.md`
- `tmp/architectural-review-espalier.md`
- `tmp/architectural-review-boobytrap.md`
- `tmp/architectural-review-slopcop.md`

Ratings use the requested scale where Rust's and Clojure's current
implementations would be `A+`, and Go 1.0 would be roughly `A-` / `B+`.
The rating is architectural/design quality for the file as it exists now, not
a judgement of whether the file is useful.

## Major Red Flags Before Release

1. `src/mir/fsm_transform/emit.rb` still has memory-safety cleanup relocation
   paths that manipulate rendered or template Zig strings (`close_zig`,
   `defer ` stripping, `rt.` replacement) while building FSM destroy behavior.
   This should become structural MIR cleanup/finalization data before a memory
   safety release. The code has improved and now checks MIR cleanup nodes in
   places, but this remaining string-template cleanup path is still too brittle
   for a critical ownership boundary.

No other reviewed issue looked like an immediate release-stopping "obviously
will not work in general" problem. The remaining concerns are mostly
complexity, lifecycle pressure, typed-boundary debt, and coverage prioritization.

## Overall Component Ratings

| Component from `src/README.md` | Rating | Outstanding issues |
| --- | --- | --- |
| Lexer | `A-` | Small and direct, but token rules are regex-order-sensitive and should keep maximal-munch tests for every new token family. |
| Parser | `C+` | Large mutable recursive-descent owner, rule tables use untyped/dynamic construction, and `Parser.gradual_mode` is process-global. |
| Annotation | `B-` | The phase/domain split is real progress, but `SemanticAnnotator`, capability validation, branch ownership state, and pipe analysis still have broad lifecycle and state-based branch pressure. |
| Pipeline Fusion and Desugaring | `B` | MIR pipeline lowering now has typed plans and lowerers; the AST rewriter still has branchy recursive special cases and pipeline semantic decisions are split between annotator analysis, rewriter, and MIR plan builder. |
| MIR Preparation / Hoisting / Ownership Analysis | `B-` | Cleanup, CFG, and ownership facts are explicit, but hoist and MIR pass remain high-churn, high-gap, state-heavy correctness surfaces. |
| MIR Lowering | `B-` | The mega-owner work paid off, but `MIRLowering` remains the broadest delegator and several lowering modules still encode large decision tables as branch hubs. |
| MIR Emission / Zig Transpilation | `B` | The emitter is mostly mechanical, but raw/stdlib Zig templates and FSM cleanup string relocation still leak backend text into semantic safety paths. |

Overall architecture/design: `B`. Overall implementation: `B-`.

## Cross-Cutting Outstanding Issues

- `SemanticAnnotator`, `Type`, `SymbolEntry`, `Scope`, `MIRLowering`,
  `MIRChecker`, and `FunctionSignature` remain implicit lifecycle owners with
  many public state-dependent operations.
- `src/ast/std_lib.rb` and intrinsic registries are still large raw contract
  tables with `T.untyped` values. They need typed contract records if they keep
  carrying allocation, ownership, fallibility, and backend emission metadata.
- The top current fix-risk files are `src/annotator/domains/control_flow.rb`,
  `src/mir/lowering/capabilities.rb`, `src/mir/fsm_lowering.rb`,
  `src/ast/ast.rb`, and `src/mir/hoist.rb`.
- The highest current state-based branch hotspots include `AST` construction,
  FSM recursive emission, cleanup classification, intrinsic lowering, return
  handling, parser function parsing, and formatter spacing/expansion.
- The largest remaining multi-file fix blast-radius signal still points at
  `src/mir/mir_lowering.rb`, even though its local state pressure is much lower
  than before.

## File-by-File Review

### `src/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `src/README.md` | `B+` | Keep it stable and high-level; detailed phase facts belong in subdirectory READMEs. |
| `src/annotator.rb` | `A` | Thin require shim; no architectural issue identified. |

### `src/annotator/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `src/annotator/README.md` | `B+` | Needs to keep reflecting the fact/work-product split as phase objects continue moving out of `SemanticAnnotator`. |
| `src/annotator/annotator.rb` | `B-` | `SemanticAnnotator` remains a temporal-ordering owner with many shared fields and public lifecycle methods. |

### `src/annotator/domains/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `control_flow.rb` | `C+` | Highest Boobytrap hotspot; branch ownership merging and loop visitors still carry dense state/control-flow decisions. |
| `errors.rb` | `B-` | Return and `OR`/error-union paths have state-based branch density around expected type, loop depth, and fallibility facts. |
| `execution_boundaries.rb` | `B` | BG/NEXT/WITH boundaries are better isolated, but `visit_NextExpr` and BG classification still branch over many async/capture state facts. |
| `expressions.rb` | `B+` | Mostly coherent expression domain; capability wrapper decisions are still a branch hotspot. |
| `lifetimes.rb` | `B-` | Ownership graph usage is centralized, but direct symbol/cleanup mutation still mixes semantic state stamping with validation. |
| `member_access.rb` | `B` | Struct/get-field logic is isolated, but field lookup and struct literal validation branch over many schema and ownership facts. |
| `variables.rb` | `C+` | Declaration finalization and assignment are high convergence/state-branch sites; typed declaration result objects could reduce condition scatter. |

### `src/annotator/helpers/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `auto_inference.rb` | `B` | Good internal objects, but evidence collection still uses callback/walk patterns and broad nil/type guard pressure. |
| `capabilities.rb` | `C+` | Capability validation, alias construction, predicate purity, audit, and lock facts still share a dense helper surface. |
| `effects.rb` | `B-` | Effect/fallibility/stack metadata are useful facts, but `EffectTracker` keeps mutable call graph/function maps as lifecycle state. |
| `fixable_helpers.rb` | `B` | Diagnostics are separated, but source-code state and fix generation are mixed into annotator behavior through a broad helper. |
| `function_analysis.rb` | `C+` | `resolve_call` and signature verification remain branch hubs across externs, methods, generics, storage, and capabilities. |
| `function_context.rb` | `A-` | Small context object; no major issue beyond continuing to keep fields typed and immutable where possible. |
| `function_return.rb` | `B+` | Compact return resolver; remaining nil/type guards should drop as return facts become stricter. |
| `function_signature.rb` | `B-` | Important typed representation, but still a temporal-ordering owner with many mutable metadata fields. |
| `generic_analysis.rb` | `B-` | Generic validation branches across type shape/capability/storage; typed request/result records would reduce repeated guard tuples. |
| `intrinsic_emit.rb` | `B` | Thin contract holder, but registry values feeding it are still loose. |
| `intrinsic_registry.rb` | `B-` | Converts loose stdlib hashes into signatures; should be replaced by typed intrinsic contract records at the source. |
| `lock_helper.rb` | `B` | Lock graph concepts are good, but held-lock/capability transition state still spans helpers and annotator fields. |
| `method_analysis.rb` | `B-` | Method resolution is compact but remains a state-based branch hotspot over registry contracts and receiver type shape. |
| `pipe_analysis.rb` | `C+` | Pipeline typing remains large and high-gap; `analyze_concurrent_op` is one of the strongest current convergence signals. |
| `reentrance.rb` | `B` | Recursion facts are separated, but some logic still depends on structural AST walks and cross-function metadata timing. |
| `test_annotation.rb` | `B+` | Test DSL validation is bounded; hooks create cross-parser/annotator/MIR state scatter but not a core architecture risk. |
| `union.rb` | `B` | Union access is isolated; remaining issue is loose schema/variant metadata rather than file-local shape. |
| `with_match_check.rb` | `B` | Requirement checking is bounded; capability predicates still depend on broader capability state finalization. |

### `src/annotator/phases/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `annotation_boundary.rb` | `A-` | Good small phase boundary; keep pass-state writes centralized. |
| `auto_finalization.rb` | `A-` | Small phase object; no file-local issue beyond dependency on broad auto inference helper. |
| `body_analysis.rb` | `B+` | Useful phase shell; still delegates into the large annotator state object. |
| `builtin_environment.rb` | `A-` | Thin phase wrapper; no issue identified. |
| `declaration_index.rb` | `B+` | Good indexing phase; dependency on broad AST declaration variants remains. |
| `deferred_validation.rb` | `B+` | Good phase concept; deferred validation records should stay typed and avoid hash growth. |
| `expression_domains.rb` | `B` | Keeps visitor dispatch organized, but static/intrinsic call paths are state-branch hotspots. |
| `program_finalization.rb` | `B+` | Small boundary; no local issue beyond relying on broad post-pass helpers. |
| `signature_registration.rb` | `B+` | Small registration phase; no local issue identified. |
| `signature_registry.rb` | `B+` | Good wrapper around signature storage; ensure future registry entries are strongly typed. |
| `type_registration.rb` | `B+` | Focused phase; remaining complexity is the loose type/schema model it registers into. |
| `whole_program_semantics.rb` | `B+` | Good phase shell; dependency on effect/capability helpers keeps actual state wider than this file. |

### `src/ast/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `ast.rb` | `C+` | Large node/fact surface with many optional slots; top state-based branch hotspot is AST initialization and traversal. |
| `async_result_shape.rb` | `A` | Small typed value object; no architectural issue identified. |
| `diagnostic_buckets.rb` | `B` | Useful typed grouping; coverage gap is high relative to size. |
| `diagnostic_examples.rb` | `B-` | Test-example scanner uses file IO and parsing heuristics; acceptable for tooling, not core compiler logic. |
| `diagnostic_registry.rb` | `B-` | Large static registry with loose hash values; should eventually be typed diagnostic records. |
| `error_registry.rb` | `B` | Structured enough, but selector rows still use loose nested hashes. |
| `fixable_error.rb` | `B` | Good diagnostic objects; collector lifecycle remains mutable but bounded. |
| `lexer.rb` | `A-` | Small maximal-munch scanner; regex ordering must stay heavily tested. |
| `parser.rb` | `C+` | Very large mutable parser with untyped rule DSL, dynamic construction, and process-global gradual mode. |
| `schemas.rb` | `B` | Schema helpers are simple, but repeated enum/resource/struct/union predicates show alias pressure. |
| `scope.rb` | `B-` | Binding/type storage is clearer after wrapping, but `Scope#dup`/branch-copy semantics can stale nested symbol references. |
| `source_error.rb` | `C+` | Error helper reaches into including objects with `instance_variable_get`/`T.unsafe`; brittle but diagnostic-only. |
| `std_lib.rb` | `C+` | Core intrinsic/std-lib contracts are still raw hash + Zig template data carrying ownership/fallibility semantics. |
| `symbol_entry.rb` | `C+` | Binding identity, flow, storage, sync, lifetime, and layout are still mutable on one public lifecycle object. |
| `syntax_typo_scanner.rb` | `B` | Bounded typo helper; no major issue beyond some untyped scanner inputs. |
| `type.rb` | `C+` | Type parsing, semantic capabilities, placement, resource flags, and Zig type computation remain coupled in one mutable owner. |

### `src/backends/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `compiler_frontend.rb` | `B` | Frontend orchestration is compact; type declaration variant handling is still a fat-union candidate. |
| `importer.rb` | `B-` | Path/import resolution is bounded but relies on string/path heuristics and loose dependency maps. |
| `pipeline_rewriter.rb` | `C+` | Recursive pipeline rewrite is still a branch hub with structural clone/condition pressure. |
| `string_concat_rewriter.rb` | `B+` | Focused desugaring pass; no major issue identified. |
| `transpiler.rb` | `B-` | CLI/frontend/module orchestration, output, and test mode state are mixed in one object. |
| `zig_type.rb` | `B+` | Small wrapper; no major issue beyond keeping fallible-return rules synchronized with `Type`. |
| `zig_type_mapper.rb` | `B+` | Thin mapper; no major issue identified. |

### `src/lsp/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `README.md` | `B+` | Keep in sync with compiler pass boundaries if analyzer behavior changes. |
| `analyzer.rb` | `B` | Compact integration; depends on global/compiler state staying reentrant. |
| `code_actions.rb` | `B-` | Useful but untyped JSON/RPC-shaped data remains loose. |
| `diagnostics.rb` | `B` | Diagnostic conversion is bounded; JSON fields remain stringly typed. |
| `document_store.rb` | `B` | Simple state owner; no major issue identified. |
| `hover.rb` | `B` | Bounded feature; depends on analyzer exposing stable typed facts. |
| `logger.rb` | `A-` | Small wrapper; no issue identified. |
| `position.rb` | `B` | Position conversion is bounded; LSP hashes remain loose. |
| `rpc.rb` | `B-` | Protocol JSON handling is intentionally loose but should stay isolated. |
| `server.rb` | `B-` | Server owns mutable logger/document/analyzer state and an analysis mutex; acceptable but not highly isolated. |

### `src/mir/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `README.md` | `B+` | Must keep tracking explicit fact/plan boundaries as lowering internals move. |
| `alloc.rb` | `B` | Small mixin, but annotation-side storage helpers living under MIR are a boundary smell. |
| `cleanup_classifier.rb` | `B-` | Cleanup facts are explicit, but classification branches over many symbol/type/storage facts and remains high-gap. |
| `cleanup_entry.rb` | `A-` | Strong cleanup recipe object; keep new lifecycle metadata here rather than in hashes. |
| `control_flow.rb` | `B-` | CFG/ownership dataflow is essential, but active borrow and transfer checks still have broad state scatter. |
| `fiber_ctx_builder.rb` | `B` | Good shared capture materializer; capture cleanup/fresh-copy output should continue moving from strings to MIR facts. |
| `fsm_lowering.rb` | `C+` | FSM step/result/lock-error lowering has high fix risk and uncovered branch pressure. |
| `fsm_ops.rb` | `B` | DSL improves FSM templates, but string/code fragments still exist at the boundary. |
| `fsm_transform.rb` | `B` | Good facade; no major local issue. |
| `fsm_wrapper_emitter.rb` | `B` | Mostly mechanical wrapper emission; keep semantic decisions out. |
| `hoist.rb` | `C+` | High SlopCop/Boobytrap risk; anonymous allocation hoisting and cleanup target stamping remain complex branch surfaces. |
| `materialization.rb` | `A-` | Good packet abstraction for allocation/binding/cleanup emission. |
| `mir.rb` | `C+` | Large IR/fact definition file; `@result_type` lifecycle and many node classes make it hard to isolate ownership shape changes. |
| `mir_checker.rb` | `B-` | Critical safety gate with explicit facts, but `check_fn!` and `@errors` lifecycle remain broad. |
| `mir_emitter.rb` | `B` | Mostly mechanical; still a broad delegator and must not absorb semantic decisions from lowering. |
| `mir_lowering.rb` | `B-` | Much less stateful than before, but still the top broad delegator and largest multi-file fix blast-radius file. |
| `mir_pass.rb` | `B-` | Useful phase coordinator; return allocator, BG resource capture, and consumed-walk logic still have branch/coverage pressure. |
| `placement.rb` | `A-` | Small typed placement helper; no major issue identified. |
| `pre_mir_type_check.rb` | `B+` | Good invariant boundary; coverage should stay high for new AST node kinds. |
| `test_lowering.rb` | `B` | Test DSL lowering is bounded; active stub state creates some state scatter. |
| `thunk_transform.rb` | `A-` | Thin facade; no issue identified. |

### `src/mir/fsm_transform/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `emit.rb` | `D+` | Major red flag: critical FSM cleanup relocation still manipulates Zig strings/templates instead of only structural MIR facts. |
| `liveness.rb` | `B` | Liveness facts are isolated; fat-union candidate around assignment/bind/var-decl common fields. |
| `recursive_splitter.rb` | `C+` | Recursive splitter uses loose context hashes and untyped segment values; many helper paths still depend on broad lowering APIs. |
| `segments.rb` | `B` | Segment records are a good shape; split helpers still branch over many AST statement variants. |
| `suspend_resolvers.rb` | `B` | Bounded resolver module; uncovered lock/stream suspend arms need targeted tests. |

### `src/mir/lower/pipeline/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `pipeline_batch_window_lowerer.rb` | `B+` | Focused lowerer; ensure batch/window ownership tests keep covering terminal variants. |
| `pipeline_binding_chain_lowerer.rb` | `B+` | Good typed chain object; still depends on callback host functions for MIR visits. |
| `pipeline_concurrent_lowerer.rb` | `B` | Much better than host-owned concurrency, but still large and callback-heavy around captures/runtime/body lowering. |
| `pipeline_context.rb` | `B+` | Good context-state object; named-binding substitution should stay structural and tested. |
| `pipeline_each_lowerer.rb` | `B+` | Focused side-effecting terminal lowerer; no major issue identified. |
| `pipeline_host.rb` | `B-` | Split succeeded, but host still owns many lowerer dependencies, counters, and current label/context state. |
| `pipeline_list_lowerer.rb` | `B` | Focused materialized-list lowerer; ownership temp/cleanup behavior still depends on host callbacks. |
| `pipeline_lowering_bridge.rb` | `B` | Typed adapter is the right boundary, but it still exposes many `MIRLowering` lifecycle operations. |
| `pipeline_materializer.rb` | `B` | Good materialization owner; allocation fact and inline-source behavior need continued branch coverage. |
| `pipeline_placeholder_usage.rb` | `A-` | Small helper; no issue identified. |
| `pipeline_plan.rb` | `A-` | Strong typed plan/fact split; terminal/execution mapping should stay exhaustive as new ops land. |
| `pipeline_range_lowerer.rb` | `B` | Large but domain-focused; lazy range and observable fold paths remain branchy. |
| `pipeline_records.rb` | `A-` | Small typed records; no issue identified. |
| `pipeline_scalar_lowerer.rb` | `B+` | Focused scalar terminal lowering; no major issue identified. |
| `pipeline_set_index_lowerer.rb` | `B+` | Focused index/distinct lowerer; ensure ownership insert facts stay tested. |

### `src/mir/lowering/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `capabilities.rb` | `B-` | Sorted lock acquisition and capability alias maps remain high-risk uncovered branch surfaces. |
| `concurrency.rb` | `B` | BG/DO/NEXT lowering is explicit, but stream and capture paths still branch over many async/runtime facts. |
| `control_flow.rb` | `B-` | Loop/match plans help, but `for_each_loop_stmt` remains a high conditional-delegation hub. |
| `counters.rb` | `A` | Small typed counter state; no issue identified. |
| `expressions.rb` | `B-` | Copy, cast, index, smooth, and OR/error lowering still carry dense type/state decisions. |
| `functions.rb` | `B-` | Function and intrinsic lowering are broad branch hubs over stdlib contracts, ownership, alloc metadata, and runtime needs. |
| `literals.rb` | `B` | Literal plans are useful; list/hash ownership and collection shape branches still need coverage. |
| `ownership_scanner.rb` | `B+` | Good focused scanner; no major issue identified. |
| `schema_registry.rb` | `B` | Small registry, but mutable replacement/registration lifecycle is still temporal-ordering pressure. |
| `state.rb` | `A-` | Good typed phase-state records; no major issue identified. |
| `variables.rb` | `B-` | Declaration/assignment lowering still has strong convergence and state-branch pressure around allocation and ownership. |

### `src/mir/thunk_transform/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `emit.rb` | `B-` | Trampoline emission still has loose values and template-like output decisions. |
| `recursive_splitter.rb` | `C+` | Splitter remains untyped/hash-heavy and should converge toward the typed FSM segment-plan style. |

### `src/semantic/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `bg_capture_classifier.rb` | `B+` | Good shared semantic classifier; no major issue identified. |
| `capture_strategy.rb` | `B+` | Typed capture strategy objects are a good boundary. |
| `concurrency_checks.rb` | `B` | Useful semantic checks; some inputs remain loose AST/function metadata. |
| `effect_inference.rb` | `B+` | Small inference helper; no major issue identified. |
| `effect_set.rb` | `B+` | Small effect value; branch coverage is low because it is tiny and should be easy to close. |
| `escape_analysis.rb` | `B-` | Important shared phase, but caller sync, placement, and lambda capture logic remain broad and high-gap. |
| `local_binding_facts.rb` | `B+` | Good local fact object; no major issue identified. |
| `ownership_graph.rb` | `B-` | Centralizing move/borrow facts is right, but graph/node lifecycle is still a temporal-ordering surface. |
| `pass_state.rb` | `A-` | Good explicit pass-state contract; keep new phases registered here rather than inferred. |
| `pass_work_profiler.rb` | `B` | Useful instrumentation; no core compiler risk, but profiling state is mutable and broad. |

### `src/tools/`

| File | Rating | Outstanding issues |
| --- | --- | --- |
| `atomic_escape_suggester.rb` | `B+` | Bounded tool; no major issue identified. |
| `atomic_migration_suggester.rb` | `B` | Bounded tool; keep AST rewrites token-aware. |
| `atomic_ptr_migration_suggester.rb` | `B` | Bounded tool; keep migration matching syntax-aware. |
| `clear_build_support.rb` | `B` | Build signature support is useful; dependency/package parsing remains string/path driven. |
| `clear_fix_support.rb` | `B` | Fix support is organized; edits and source spans must stay covered to avoid brittle rewrites. |
| `completions.rb` | `B+` | Small support file; no major issue identified. |
| `doctor.rb` | `C` | Large profiling/parser tool with extensive regex/string parsing; acceptable as a tool, not a model for compiler phases. |
| `fmt_verifier.rb` | `B-` | Normalization uses regex against generated text; acceptable for verification, not source semantics. |
| `formatter.rb` | `C+` | Large token formatter with high state-based branch density and uncovered fix-churn; not memory-safety critical. |
| `lint_fix_rewriter.rb` | `B` | Source rewrite spans are necessarily delicate; oversized predicate around annotation span detection should be extracted/tested. |
| `method_rewriter.rb` | `B` | Migration matcher is bounded; complex predicate matching should stay AST-based. |
| `migration_suggester_helpers.rb` | `B` | Shared helper is bounded; no major issue identified. |
| `multi_statement_linter.rb` | `B+` | Small lint helper; no major issue identified. |
| `pprof.rb` | `B-` | Profile builder is a temporal-ordering owner; acceptable tool debt. |
| `pprof_converter.rb` | `B` | Conversion tool uses text parsing; acceptable but should stay away from compiler semantics. |
| `predicate_rewriter.rb` | `B-` | Predicate rewrite spans use source-character walking; acceptable for migration tooling but needs targeted tests. |
| `stack_verifier.rb` | `C+` | Assembly/DWARF parsing is regex-heavy and brittle by nature; acceptable as a verifier, not release-core logic. |
