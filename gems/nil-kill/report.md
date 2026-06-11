# Nil Kill Report

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hygiene Overview](#hygiene-overview)
  - [Type Soundness](#type-soundness)
  - [Untyped Cause Breakdown](#untyped-cause-breakdown)
  - [Union Decomplexity](#union-decomplexity)
  - [Deterministic Guard Collapse](#deterministic-guard-collapse)
  - [Node-Union Alias Candidates](#node-union-alias-candidates)
  - [Untyped Evidence Gaps](#untyped-evidence-gaps)
  - [Signature Slot Evidence](#signature-slot-evidence)
  - [Return Hygiene](#return-hygiene)
- [Review Actions (1634)](#review-actions-1634)
  - [Nil Source Fixes (149)](#nil-source-fixes-149)
  - [Union / `T.any` Candidates (419)](#union-tany-candidates-419)
  - [Missing Sigs Needing Manual Review (91)](#missing-sigs-needing-manual-review-91)
  - [Other Review Actions (975)](#other-review-actions-975)
- [High-Confidence Actions (0)](#high-confidence-actions-0)
- [Gap Actions (0)](#gap-actions-0)
- [Untyped Slots](#untyped-slots)
  - [Param `T.untyped` Buckets](#param-tuntyped-buckets)
  - [Return `T.untyped` Buckets](#return-tuntyped-buckets)
  - [Param `T.untyped` Source Categories](#param-tuntyped-source-categories)
  - [Return `T.untyped` Source Categories](#return-tuntyped-source-categories)
  - [Param Unknown Expression Causes](#param-unknown-expression-causes)
  - [Return Unknown Expression Causes](#return-unknown-expression-causes)
- [Nil origins](#nil-origins)
- [Nilability Pressure By Root Callsite](#nilability-pressure-by-root-callsite)
- [Union Pressure Downgraded To `T.untyped`](#union-pressure-downgraded-to-tuntyped)
- [`T.any` Downgrades By Signature](#tany-downgrades-by-signature)
- [Return Origin Pressure](#return-origin-pressure)
- [Input Param Origin Backflow](#input-param-origin-backflow)
- [Foreign Scalar Inputs Into Object-Typed Params](#foreign-scalar-inputs-into-object-typed-params)
- [Type Normalizer Sites](#type-normalizer-sites)
- [Struct Shape Report](#struct-shape-report)
  - [Struct Field Slot Breakdown](#struct-field-slot-breakdown)
  - [Struct Field Type Candidates](#struct-field-type-candidates)
- [Collection Type Report](#collection-type-report)
  - [Hash Record Struct Candidates (Shapes + Pressure)](#hash-record-struct-candidates-shapes-pressure)
  - [Weak Collection Slots With Runtime Candidates](#weak-collection-slots-with-runtime-candidates)
  - [Weak Collection Slots Without Candidate](#weak-collection-slots-without-candidate)
  - [Collection Blocker Pressure](#collection-blocker-pressure)
  - [Runtime Collection Mutation Observations](#runtime-collection-mutation-observations)
  - [Collection Index Lookup Provenance](#collection-index-lookup-provenance)
  - [Unknown Or Weak Index Lookups By Receiver Origin](#unknown-or-weak-index-lookups-by-receiver-origin)
- [Tuple-Like Array Report](#tuple-like-array-report)
  - [Runtime Tuple-Like Array Slots](#runtime-tuple-like-array-slots)
- [Run Summary](#run-summary)

## Project Prioritization
- [Nil Source Fixes (149)](#nil-source-fixes-149): 147 action item(s), 149 `T.nilable` slot(s); top source affects 2 slot(s), 1815 source calls
- [Union / `T.any` Candidates (419)](#union-tany-candidates-419): 393 action item(s), 419 union slot(s); top source affects 3 slot(s), 0 source calls
- [Hash Record Struct Candidates (Shapes + Pressure)](#hash-record-struct-candidates-shapes-pressure): 156 struct candidate(s), 189 pressure record(s); top candidate AddrsRecord has pressure 18; 54 pressure record(s) without a literal shape cluster

## Hygiene Overview

### Type Soundness

| Slot category | Total | Strong | Weak | Untyped | Nilable |
|---|---|---|---|---|---|
| Param inputs | 6459 | 5654 (87.5%) | 171 (2.6%) | 634 (9.8%) | 752 (11.6%) |
| Returns | 3772 | 3563 (94.5%) | 36 (1.0%) | 173 (4.6%) | 728 (19.3%) |
| Struct/class fields & ivars | 1580 | 787 (49.8%) | 22 (1.4%) | 771 (48.8%) | 183 (11.6%) |
| Arrays/Sets/Hashmaps | 2159 | 1803 (83.5%) | 356 (16.5%) | 0 (0.0%) | 216 (10.0%) |

Total = Strong + Weak + Untyped. Nilable is a cross-cut sub-count (a `T.nilable(String)` slot is Strong and Nilable, not a fourth bucket). Collection-typed slots (`T::Array[...]` etc.) are counted only in the Arrays/Sets/Hashmaps row, so the four categories are mutually exclusive. The Param/Returns/Struct Untyped columns equal the per-row denominators in the Untyped Cause Breakdown below.

### Untyped Cause Breakdown

| Slot category | Refused/Pending | PropagationGap | WeakEvidence | Heterogeneous | NoEvidence |
|---|---|---|---|---|---|
| Param inputs (634 untyped) | 189 (29.8%) | 123 (19.4%) | 75 (11.8%) | 194 (30.6%) | 53 (8.4%) |
| Returns (173 untyped) | 53 (30.6%) | 8 (4.6%) | 48 (27.7%) | 59 (34.1%) | 5 (2.9%) |
| Struct/class fields & ivars (771 untyped) | 422 (54.7%) | 132 (17.1%) | 14 (1.8%) | 47 (6.1%) | 156 (20.2%) |
| Arrays/Sets/Hashmaps (305 untyped) | 65 (21.3%) | 16 (5.2%) | 33 (10.8%) | 110 (36.1%) | 81 (26.6%) |

- **Refused/Pending**: type IS determinable from local evidence (single observed runtime type, void/unused, boolean pair) -- untyped only because the fix is unapplied or conservatively refused
- **PropagationGap**: type is determinable elsewhere but needs cross-method/whole-program flow (forwarded return, ivar-from-param capture, callee untyped-but-resolvable, coherent collection needing the typed-collection rewrite)
- **WeakEvidence**: a type is known but only weakly (T::Array[`T.untyped`], a union wider than policy) -- the weak-collection / union-policy axis
- **Heterogeneous**: slot legitimately holds many unrelated types/shapes (AST/MIR node grab-bags, dynamic dispatch) -- `T.untyped` is the correct type
- **NoEvidence**: never observed at runtime AND no static expression/callsite to infer from -- needs a test or a hand-written sig

Actionable by more nil-kill work: PropagationGap (and the policy half of WeakEvidence). Inherent (correct `T.untyped` or needs human/tests): Heterogeneous + NoEvidence. Refused/Pending is resolvable today but unapplied or conservatively declined.

### Union Decomplexity
- Each entry is a canonical origin contract (an accessor like `.type_info`, a hash key like `[:type]`, an ivar, a call) and the TOTAL `is_a?(Type)` guards that collapse if that one contract is given a concrete type. Guards are aggregated across every method that reads the contract. Producer types come from runtime evidence for that contract; `unattributed` = no runtime trace yet for it.
- 22 guards collapse | `.type` (accessor) across 18 method(s) -> via @type assignments (runtime) {Symbol, Type, NilClass, T.nilable(Type)}: tighten that contract
  - methods: `EscapeAnalysis#propagate_caller_sync!`, `MIRLoweringFunctions#lower_lambda`, `MethodAnalysis#narrow_collection_type!`, `Annotator::Domains::ControlFlow#annotate_struct_pattern!`, `Annotator::Domains::ControlFlow#loop_value_copyable?`, `AutoUnifier#stamp_map_pairs!`, +12 more
  - guards at: [src/semantic/escape_analysis.rb:311](../../src/semantic/escape_analysis.rb#L311), [src/semantic/escape_analysis.rb:329](../../src/semantic/escape_analysis.rb#L329), [src/mir/lowering/functions.rb:1975](../../src/mir/lowering/functions.rb#L1975), [src/mir/lowering/functions.rb:1976](../../src/mir/lowering/functions.rb#L1976), [src/annotator/helpers/method_analysis.rb:44](../../src/annotator/helpers/method_analysis.rb#L44)
- 16 guards collapse | `full_type!()` (call) across 12 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `Annotator::Domains::Lifetimes#share_consumes_source?`, `Annotator::Domains::Lifetimes#visit_CopyNode`, `Annotator::Phases::ExpressionDomains#resolve_extern_method_call!`, `Annotator::Domains::ControlFlow#visit_ForEach`, `Annotator::Domains::Errors#visit_ReturnNode`, `Annotator::Domains::Expressions#visit_BinaryOp`, +6 more
  - guards at: [src/annotator/domains/lifetimes.rb:1154](../../src/annotator/domains/lifetimes.rb#L1154), [src/annotator/domains/lifetimes.rb:1155](../../src/annotator/domains/lifetimes.rb#L1155), [src/annotator/domains/lifetimes.rb:129](../../src/annotator/domains/lifetimes.rb#L129), [src/annotator/domains/lifetimes.rb:140](../../src/annotator/domains/lifetimes.rb#L140), [src/annotator/phases/expression_domains.rb:232](../../src/annotator/phases/expression_domains.rb#L232)
- 7 guards collapse | `.return_type` (accessor) across 7 method(s) -> via @return_type assignments (runtime) {Type, Symbol, T.nilable(Type)}: tighten that contract
  - methods: `EffectTracker#compute_can_fail!`, `EffectTracker#compute_needs_rt!`, `EffectTracker#compute_stack_tiers!`, `MIRLoweringFunctions#call_owned_return?`, `MIRLoweringVariables#tied_shared_family_return_param`, `PipeAnalysis#analyze_pipe_to_named_function`, +1 more
  - guards at: [src/annotator/helpers/effects.rb:487](../../src/annotator/helpers/effects.rb#L487), [src/annotator/helpers/effects.rb:409](../../src/annotator/helpers/effects.rb#L409), [src/annotator/helpers/effects.rb:1003](../../src/annotator/helpers/effects.rb#L1003), [src/mir/lowering/functions.rb:1458](../../src/mir/lowering/functions.rb#L1458), [src/mir/lowering/variables.rb:91](../../src/mir/lowering/variables.rb#L91)
- 6 guards collapse | `` (hash-key) across 6 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `Annotator::Domains::ControlFlow#match_payload_struct_schema`, `Annotator::Domains::MemberAccess#visit_StructLit`, `MIRLoweringConcurrency#capture_ownership_mirror_nodes`, `MIRLoweringExpressions#lower_union_variant_lit`, `TypeShape#resolved`, `UnionAnalysis#validate_union_fields!`
  - guards at: [src/annotator/domains/control_flow.rb:573](../../src/annotator/domains/control_flow.rb#L573), [src/annotator/domains/member_access.rb:296](../../src/annotator/domains/member_access.rb#L296), [src/mir/lowering/concurrency.rb:207](../../src/mir/lowering/concurrency.rb#L207), [src/mir/lowering/expressions.rb:1591](../../src/mir/lowering/expressions.rb#L1591), [src/ast/type.rb:314](../../src/ast/type.rb#L314)
- 4 guards collapse | `.resolved_type` (accessor) across 2 method(s) -> via @resolved_type assignments (runtime) {Type, NilClass}: tighten that contract
  - methods: `CapabilityHelper#validate_capability_transition!`, `MIRLoweringControlFlow#match_lowering_facts`
  - guards at: [src/annotator/helpers/capabilities.rb:206](../../src/annotator/helpers/capabilities.rb#L206), [src/annotator/helpers/capabilities.rb:219](../../src/annotator/helpers/capabilities.rb#L219), [src/mir/lowering/control_flow.rb:708](../../src/mir/lowering/control_flow.rb#L708), [src/mir/lowering/control_flow.rb:711](../../src/mir/lowering/control_flow.rb#L711)
- 4 guards collapse | `.full_type!` (accessor) across 4 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `FsmLowering#lower_step_stmts`, `MIRLoweringControlFlow#for_each_plan`, `MIRLoweringExpressions#lower_share`, `MIRLoweringFunctions#lower_lambda`
  - guards at: [src/mir/fsm_lowering.rb:108](../../src/mir/fsm_lowering.rb#L108), [src/mir/lowering/control_flow.rb:322](../../src/mir/lowering/control_flow.rb#L322), [src/mir/lowering/expressions.rb:2101](../../src/mir/lowering/expressions.rb#L2101), [src/mir/lowering/functions.rb:1969](../../src/mir/lowering/functions.rb#L1969)
- 2 guards collapse | `param `b` (AutoUnifier#types_equal?)` (param) across 1 method(s) -> always `AutoConstraintCollector::ObservedType`: collapse, all 2 die
  - methods: `AutoUnifier#types_equal?`
  - guards at: [src/annotator/helpers/auto_inference.rb:601](../../src/annotator/helpers/auto_inference.rb#L601), [src/annotator/helpers/auto_inference.rb:603](../../src/annotator/helpers/auto_inference.rb#L603)
- 2 guards collapse | `param `expected_type` (Annotator::Domains::Lifetimes#ensure_owned_value!)` (param) across 1 method(s) -> 50.0% `Type` + 2 outlier producer(s)
  - methods: `Annotator::Domains::Lifetimes#ensure_owned_value!`
  - guards at: [src/annotator/domains/lifetimes.rb:76](../../src/annotator/domains/lifetimes.rb#L76), [src/annotator/domains/lifetimes.rb:80](../../src/annotator/domains/lifetimes.rb#L80)
  - outlier producer `T::Hash[T.untyped, T.untyped]` at [src/annotator/helpers/function_analysis.rb:656](../../src/annotator/helpers/function_analysis.rb#L656) `facts.param.type`
  - outlier producer `T.nilable(Type)` at [src/annotator/helpers/union.rb:202](../../src/annotator/helpers/union.rb#L202) `expected_fields[fname]`
- 2 guards collapse | `param `a` (AutoUnifier#types_equal?)` (param) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `AutoUnifier#types_equal?`
  - guards at: [src/annotator/helpers/auto_inference.rb:601](../../src/annotator/helpers/auto_inference.rb#L601), [src/annotator/helpers/auto_inference.rb:602](../../src/annotator/helpers/auto_inference.rb#L602)
- ... and 21 more (run with `--full` to see all)

### Deterministic Guard Collapse
- `static_proven` rows are predicates nil-kill can prove from source/type facts. `contract_proven` rows are guard clusters that collapse when the named origin is typed to its observed singleton producer. Runtime-only dominance is review material, not an autofix proof.
- Contract-proven collapses: 11
  - contract_proven: 2 guard(s) collapse | `param `b` (AutoUnifier#types_equal?)` (param) -> always `AutoConstraintCollector::ObservedType`
    - methods/sites: `AutoUnifier#types_equal?`; [src/annotator/helpers/auto_inference.rb:601](../../src/annotator/helpers/auto_inference.rb#L601), [src/annotator/helpers/auto_inference.rb:603](../../src/annotator/helpers/auto_inference.rb#L603)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `input` (TypeHelper#to_type)` (param) -> always `Type`
    - methods/sites: `TypeHelper#to_type`; [src/ast/type.rb:3545](../../src/ast/type.rb#L3545)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `type` (FixableHelper#auto_type_source_form)` (param) -> always `Symbol`
    - methods/sites: `FixableHelper#auto_type_source_form`; [src/annotator/helpers/fixable_helpers.rb:1625](../../src/annotator/helpers/fixable_helpers.rb#L1625)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `t` (AutoUnifier#widen_byte_array_to_string)` (param) -> always `AutoConstraintCollector::ObservedType`
    - methods/sites: `AutoUnifier#widen_byte_array_to_string`; [src/annotator/helpers/auto_inference.rb:590](../../src/annotator/helpers/auto_inference.rb#L590)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `type_obj` (FiberCtxBuilder#needs_move_capture_cleanup?)` (param) -> always `Type`
    - methods/sites: `FiberCtxBuilder#needs_move_capture_cleanup?`; [src/mir/fiber_ctx_builder.rb:413](../../src/mir/fiber_ctx_builder.rb#L413)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `right` (GenericAnalysis#same_generic_binding?)` (param) -> always `Type`
    - methods/sites: `GenericAnalysis#same_generic_binding?`; [src/annotator/helpers/generic_analysis.rb:437](../../src/annotator/helpers/generic_analysis.rb#L437)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `to_type` (MIRLowering#mir_cast)` (param) -> always `Type`
    - methods/sites: `MIRLowering#mir_cast`; [src/mir/mir_lowering.rb:2684](../../src/mir/mir_lowering.rb#L2684)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `sink_type` (MIRLowering#owned_sink_plan)` (param) -> always `T.nilable(Type::TypeInput)`
    - methods/sites: `MIRLowering#owned_sink_plan`; [src/mir/mir_lowering.rb:3555](../../src/mir/mir_lowering.rb#L3555)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `t` (ModuleImporter#auto_type?)` (param) -> always `Type`
    - methods/sites: `ModuleImporter#auto_type?`; [src/backends/importer.rb:165](../../src/backends/importer.rb#L165)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `type` (Parser#synthesize_default_for_type)` (param) -> always `T.nilable(Type)`
    - methods/sites: `Parser#synthesize_default_for_type`; [src/ast/parser.rb:952](../../src/ast/parser.rb#L952)
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `target_type` (Type#coerce_error)` (param) -> always `CoerceTypeInput`
    - methods/sites: `Type#coerce_error`; [src/ast/type.rb:549](../../src/ast/type.rb#L549)
    - producer evidence: param origins
- Static-proven branch predicates: 30
  - static_proven: [src/annotator/domains/control_flow.rb:427](../../src/annotator/domains/control_flow.rb#L427) `Annotator::Domains::ControlFlow#analyze_match_case!` `pattern.is_a?(AST::StructPattern)` -> always true (if takes body)
    - pattern has static type AST::StructPattern; is_a?(AST::StructPattern) is always true
  - static_proven: [src/annotator/helpers/function_signature.rb:154](../../src/annotator/helpers/function_signature.rb#L154) `FunctionSignature#from_function_def` `raw_sig.is_a?(FunctionSignature)` -> always true (if takes body)
    - raw_sig has static type FunctionSignature; is_a?(FunctionSignature) is always true
  - static_proven: [src/annotator/helpers/function_signature.rb:477](../../src/annotator/helpers/function_signature.rb#L477) `FunctionSignature#normalize_lifetime` `val.nil?` -> always false (if takes else)
    - val has static type LifetimeInput; .nil? is always false
  - static_proven: [src/annotator/helpers/pipe_analysis.rb:1229](../../src/annotator/helpers/pipe_analysis.rb#L1229) `PipeAnalysis#auto_detect_sharded_access` `each_op.is_a?(AST::EachOp)` -> always true (unless takes else)
    - each_op has static type AST::EachOp; is_a?(AST::EachOp) is always true
  - static_proven: [src/annotator/helpers/reentrance.rb:131](../../src/annotator/helpers/reentrance.rb#L131) `ReentranceBridge#offer_plain_reentrant_variant_fix!` `suggestion.nil?` -> always false (if takes else)
    - suggestion has static type String; .nil? is always false
  - static_proven: [src/ast/parser.rb:2889](../../src/ast/parser.rb#L2889) `Parser#type_annotation_source` `type.is_a?(Type)` -> always true (if takes body)
    - type has static type Type; is_a?(Type) is always true
  - static_proven: [src/ast/symbol_entry.rb:498](../../src/ast/symbol_entry.rb#L498) `SymbolEntry#type=` `val.nil?` -> always false (if takes else)
    - val has static type TypeInput; .nil? is always false
  - static_proven: [src/ast/symbol_entry.rb:512](../../src/ast/symbol_entry.rb#L512) `SymbolEntry#normalize_lifetime` `value.nil?` -> always false (if takes else)
    - value has static type LifetimeInput; .nil? is always false
  - static_proven: [src/ast/symbol_entry.rb:520](../../src/ast/symbol_entry.rb#L520) `SymbolEntry#normalize_lifetime` `sources.nil?` -> always false (if takes else)
    - sources has static type LifetimeInput; .nil? is always false
  - static_proven: [src/ast/type.rb:2305](../../src/ast/type.rb#L2305) `Type#observable_array_future?` `tt.is_a?(Type)` -> always true (unless takes else)
    - tt has static type Type; is_a?(Type) is always true
  - static_proven: [src/ast/type.rb:2676](../../src/ast/type.rb#L2676) `Type#copyable?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: [src/ast/type.rb:2705](../../src/ast/type.rb#L2705) `Type#bg_capture_is_value_copy?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: [src/ast/type.rb:2707](../../src/ast/type.rb#L2707) `Type#bg_capture_is_value_copy?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: [src/ast/type.rb:2732](../../src/ast/type.rb#L2732) `Type#implicitly_copyable?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: [src/ast/type.rb:2735](../../src/ast/type.rb#L2735) `Type#implicitly_copyable?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: [src/mir/control_flow.rb:127](../../src/mir/control_flow.rb#L127) `FunctionCFG#build_body` `stmts.is_a?(Array)` -> always true (unless takes else)
    - stmts has static type T::Array[`T.untyped`]; is_a?(Array) is always true
  - static_proven: [src/mir/control_flow.rb:1980](../../src/mir/control_flow.rb#L1980) `BorrowChecker#transfer_collector` `@fn_node.is_a?(AST::FunctionDef)` -> always true (if takes body)
    - @fn_node has static type AST::FunctionDef; is_a?(AST::FunctionDef) is always true
  - static_proven: [src/mir/fsm_ops.rb:189](../../src/mir/fsm_ops.rb#L189) `FsmOps::DSL#io_submit` `waiter.is_a?(String)` -> always true (if takes body)
    - waiter has static type String; is_a?(String) is always true
  - static_proven: [src/mir/fsm_transform/recursive_splitter.rb:206](../../src/mir/fsm_transform/recursive_splitter.rb#L206) `FsmTransform::RecursiveSplitter#split` `entry.nil?` -> always false (if takes else)
    - entry has static type Integer; .nil? is always false
  - static_proven: [src/mir/fsm_transform/segments.rb:271](../../src/mir/fsm_transform/segments.rb#L271) `FsmTransform::Segments#split_while_loop_next` `cond_node.nil?` -> always true (if takes body)
    - cond_node has static type NilClass; .nil? is always true
  - static_proven: [src/mir/hoist.rb:97](../../src/mir/hoist.rb#L97) `Hoist#hoist_body!` `body.is_a?(Array)` -> always true (unless takes else)
    - body has static type T::Array[AST::Node]; is_a?(Array) is always true
  - static_proven: [src/mir/lowering/functions.rb:1211](../../src/mir/lowering/functions.rb#L1211) `MIRLoweringFunctions#stdlib_coerce_type` `resolved.is_a?(Symbol)` -> always false (if takes else)
    - resolved has static type T::Hash[`T.untyped`, `T.untyped`]; is_a?(Symbol) is always false
  - static_proven: [src/mir/lowering/functions.rb:1458](../../src/mir/lowering/functions.rb#L1458) `MIRLoweringFunctions#call_owned_return?` `raw_ti.is_a?(Type)` -> always true (if takes body)
    - raw_ti has static type Type; is_a?(Type) is always true
  - static_proven: [src/mir/mir_emitter.rb:330](../../src/mir/mir_emitter.rb#L330) `MIREmitter#emit_do_block` `plan.is_a?(MIR::DoBlockPlan)` -> always true (if takes body)
    - plan has static type MIR::DoBlockPlan; is_a?(MIR::DoBlockPlan) is always true
  - static_proven: [src/mir/mir_lowering.rb:1165](../../src/mir/mir_lowering.rb#L1165) `MIRLowering#append_lowered_statement_packet!` `packet_mir.is_a?(Array)` -> always true (if takes body)
    - packet_mir has static type T::Array[`T.untyped`]; is_a?(Array) is always true
  - static_proven: [src/mir/mir_lowering.rb:2683](../../src/mir/mir_lowering.rb#L2683) `MIRLowering#mir_cast` `from_type.is_a?(Type)` -> always true (if takes body)
    - from_type has static type Type; is_a?(Type) is always true
  - static_proven: [src/mir/mir_pass.rb:449](../../src/mir/mir_pass.rb#L449) `MIRPass#transform_body` `stmts.is_a?(Array)` -> always true (unless takes else)
    - stmts has static type T::Array[`T.untyped`]; is_a?(Array) is always true
  - static_proven: [src/mir/thunk_transform/emit.rb:255](../../src/mir/thunk_transform/emit.rb#L255) `ThunkTransform::Emit#return_type_info` `rt.nil?` -> always false (if takes else)
    - rt has static type Type; .nil? is always false
  - static_proven: [src/mir/thunk_transform/emit.rb:256](../../src/mir/thunk_transform/emit.rb#L256) `ThunkTransform::Emit#return_type_info` `rt.is_a?(Type)` -> always true (if takes body)
    - rt has static type Type; is_a?(Type) is always true
  - static_proven: [src/semantic/local_binding_facts.rb:48](../../src/semantic/local_binding_facts.rb#L48) `MIR::LocalBindingAnalysis#each_direct_loop_node` `body.is_a?(Array)` -> always true (unless takes else)
    - body has static type T::Array[`T.untyped`]; is_a?(Array) is always true

### Node-Union Alias Candidates
- Heterogeneous param slots whose every observed class is in ONE namespace. Each namespace below collapses to a single `T.type_alias` (e.g. `AstNode = T.type_alias { T.any(AST::...) }`); applying it types every listed param at once. `classes` = distinct node types observed at that slot (small = a precise sub-union; large = the full node grab-bag).
- 135 of 192 Heterogeneous params (70%) collapse to 3 alias(es).
- `AstNode` (AST::*): 78 param slot(s)
  - [src/ast/ast.rb:838](../../src/ast/ast.rb#L838) `AST#_expr_each_concurrent_capture` param `node` (82 node types)
  - [src/mir/control_flow.rb:276](../../src/mir/control_flow.rb#L276) `FunctionCFG#stmt_can_fail?` param `node` (65 node types)
  - [src/semantic/escape_analysis.rb:130](../../src/semantic/escape_analysis.rb#L130) `EscapeAnalysis::EscapeSink#matches?` param `node` (53 node types)
  - [src/semantic/escape_analysis.rb:592](../../src/semantic/escape_analysis.rb#L592) `EscapeAnalysis#unwrap_value` param `node` (41 node types)
  - [src/ast/ast.rb:662](../../src/ast/ast.rb#L662) `AST#wrapped_children` param `expr` (37 node types)
  - [src/ast/ast.rb:726](../../src/ast/ast.rb#L726) `AST#_bg_visit_recursive` param `node` (34 node types)
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` param `ast_value` (31 node types)
  - [src/mir/lowering/variables.rb:306](../../src/mir/lowering/variables.rb#L306) `MIRLoweringVariables#optional_nil_initializer?` param `value` (31 node types)
  - [src/mir/lowering/variables.rb:314](../../src/mir/lowering/variables.rb#L314) `MIRLoweringVariables#owned_binding_source_alloc` param `value` (31 node types)
  - [src/semantic/escape_analysis.rb:826](../../src/semantic/escape_analysis.rb#L826) `EscapeAnalysis#borrow_return_expr?` param `expr` (31 node types)
  - [src/ast/type.rb:3557](../../src/ast/type.rb#L3557) `TypeHelper#check_prefixed_int_range!` param `node` (30 node types)
  - [src/mir/mir_pass.rb:487](../../src/mir/mir_pass.rb#L487) `MIRPass#recurse_branches!` param `stmt` (30 node types)
  - [src/mir/cleanup_classifier.rb:1035](../../src/mir/cleanup_classifier.rb#L1035) `CleanupClassifier#optional_empty_initializer?` param `value` (29 node types)
  - [src/mir/hoist.rb:116](../../src/mir/hoist.rb#L116) `Hoist#child_bodies` param `stmt` (27 node types)
  - [src/mir/hoist.rb:602](../../src/mir/hoist.rb#L602) `MIRHoistLowering#hoist_alloc` param `ast_node` (27 node types)
  - [src/semantic/escape_analysis.rb:744](../../src/semantic/escape_analysis.rb#L744) `EscapeAnalysis#heap_binding_carries_sources?` param `value` (27 node types)
  - [src/mir/control_flow.rb:1319](../../src/mir/control_flow.rb#L1319) `UseAfterMoveChecker#check_stmt_reads` param `stmt` (26 node types)
  - [src/mir/hoist.rb:320](../../src/mir/hoist.rb#L320) `Hoist#concat?` param `node` (26 node types)
  - [src/mir/cleanup_classifier.rb:901](../../src/mir/cleanup_classifier.rb#L901) `CleanupClassifier#contains_call?` param `node` (23 node types)
  - [src/mir/fsm_transform.rb:252](../../src/mir/fsm_transform.rb#L252) `FsmTransform#local_entry_for_node` param `node` (23 node types)
  - [src/annotator/helpers/function_analysis.rb:1253](../../src/annotator/helpers/function_analysis.rb#L1253) `FunctionAnalysis#return_is_borrow?` param `node` (21 node types)
  - [src/mir/hoist.rb:396](../../src/mir/hoist.rb#L396) `Hoist#ast_access_path?` param `ast_node` (21 node types)
  - [src/mir/lowering/control_flow.rb:1209](../../src/mir/lowering/control_flow.rb#L1209) `MIRLoweringControlFlow#call_union_return_needs_hoist?` param `ast_node` (20 node types)
  - [src/mir/hoist.rb:1160](../../src/mir/hoist.rb#L1160) `MIRHoistLowering#hoist_cleanup_entry` param `ast_node` (19 node types)
  - [src/mir/lowering/control_flow.rb:1178](../../src/mir/lowering/control_flow.rb#L1178) `MIRLoweringControlFlow#collect_returned_binding_names` param `expr` (18 node types)
  - [src/mir/mir_lowering.rb:2598](../../src/mir/mir_lowering.rb#L2598) `MIRLowering#placement_for_node` param `node` (18 node types)
  - [src/ast/parser.rb:1947](../../src/ast/parser.rb#L1947) `Parser#parse_suffixes` param `lhs` (17 node types)
  - [src/semantic/escape_analysis.rb:1012](../../src/semantic/escape_analysis.rb#L1012) `EscapeAnalysis#owning_return_type` param `expr` (16 node types)
  - [src/semantic/escape_analysis.rb:688](../../src/semantic/escape_analysis.rb#L688) `EscapeAnalysis#ownership_bearing_transfer_expr?` param `arg` (16 node types)
  - [src/semantic/escape_analysis.rb:975](../../src/semantic/escape_analysis.rb#L975) `EscapeAnalysis#borrowed_return?` param `expr` (16 node types)
  - [src/mir/mir_lowering.rb:2587](../../src/mir/mir_lowering.rb#L2587) `MIRLowering#symbol_storage_for_node` param `node` (15 node types)
  - [src/semantic/escape_analysis.rb:702](../../src/semantic/escape_analysis.rb#L702) `EscapeAnalysis#heap_owned_transfer_source?` param `arg` (15 node types)
  - [src/semantic/escape_analysis.rb:793](../../src/semantic/escape_analysis.rb#L793) `EscapeAnalysis#ownership_transferring_expr?` param `expr` (15 node types)
  - [src/semantic/escape_analysis.rb:834](../../src/semantic/escape_analysis.rb#L834) `EscapeAnalysis#expr_has_heap_identifier?` param `expr` (15 node types)
  - [src/mir/lowering/functions.rb:1144](../../src/mir/lowering/functions.rb#L1144) `MIRLoweringFunctions#borrowed_ownership_operand?` param `arg` (14 node types)
  - [src/mir/mir_lowering.rb:2368](../../src/mir/mir_lowering.rb#L2368) `MIRLowering#moved_arg_root` param `arg` (14 node types)
  - [src/semantic/escape_analysis.rb:557](../../src/semantic/escape_analysis.rb#L557) `EscapeAnalysis#mark_expr_roots_heap!` param `expr` (14 node types)
  - [src/ast/parser.rb:1795](../../src/ast/parser.rb#L1795) `Parser#parse_binary_op` param `lhs` (13 node types)
  - [src/backends/pipeline_rewriter.rb:590](../../src/backends/pipeline_rewriter.rb#L590) `PipelineRewriter#build_terminal_action` param `terminal` (13 node types)
  - [src/mir/lowering/control_flow.rb:1224](../../src/mir/lowering/control_flow.rb#L1224) `MIRLoweringControlFlow#universal_poly_arg_needs_addr?` param `arg_node` (13 node types)
  - [src/mir/lowering/functions.rb:1304](../../src/mir/lowering/functions.rb#L1304) `MIRLoweringFunctions#wants_ptr?` param `a` (13 node types)
  - [src/mir/fsm_transform/segments.rb:357](../../src/mir/fsm_transform/segments.rb#L357) `FsmTransform::Segments#suspend_for` param `v` (12 node types)
  - [src/mir/lowering/variables.rb:617](../../src/mir/lowering/variables.rb#L617) `MIRLoweringVariables#source_already_has_declared_capability?` param `source_node` (12 node types)
  - [src/backends/pipeline_rewriter.rb:396](../../src/backends/pipeline_rewriter.rb#L396) `PipelineRewriter#build_init` param `terminal` (11 node types)
  - [src/backends/pipeline_rewriter.rb:492](../../src/backends/pipeline_rewriter.rb#L492) `PipelineRewriter#build_recursive_body` param `terminal` (11 node types)
  - [src/mir/hoist.rb:1215](../../src/mir/hoist.rb#L1215) `MIRHoistLowering#cleanup_entry_for_owned_result` param `ast_node` (11 node types)
  - [src/mir/hoist.rb:29](../../src/mir/hoist.rb#L29) `MIRHoistFacts#container_borrow_expr?` param `ast_node` (11 node types)
  - [src/semantic/escape_analysis.rb:809](../../src/semantic/escape_analysis.rb#L809) `EscapeAnalysis#string_concat_expr?` param `expr` (11 node types)
  - [src/backends/pipeline_rewriter.rb:786](../../src/backends/pipeline_rewriter.rb#L786) `PipelineRewriter#replace_placeholder` param `node` (10 node types)
  - [src/mir/fsm_transform/segments.rb:291](../../src/mir/fsm_transform/segments.rb#L291) `FsmTransform::Segments#stmt_unsupported?` param `stmt` (10 node types)
  - [src/mir/lowering/expressions.rb:1201](../../src/mir/lowering/expressions.rb#L1201) `MIRLoweringExpressions#comptime_number_literal?` param `node` (10 node types)
  - [src/mir/lowering/expressions.rb:642](../../src/mir/lowering/expressions.rb#L642) `MIRLoweringExpressions#unit_variant_access` param `node` (10 node types)
  - [src/semantic/escape_analysis.rb:846](../../src/semantic/escape_analysis.rb#L846) `EscapeAnalysis#expr_has_owned_inline_value?` param `expr` (10 node types)
  - [src/backends/pipeline_rewriter.rb:724](../../src/backends/pipeline_rewriter.rb#L724) `PipelineRewriter#build_final_result` param `terminal` (9 node types)
  - [src/semantic/escape_analysis.rb:393](../../src/semantic/escape_analysis.rb#L393) `EscapeAnalysis#apply_escape_sink!` param `node` (9 node types)
  - [src/semantic/escape_analysis.rb:712](../../src/semantic/escape_analysis.rb#L712) `EscapeAnalysis#mark_receiver_scope_escapes!` param `receiver` (9 node types)
  - [src/ast/source_error.rb:81](../../src/ast/source_error.rb#L81) `ErrorHelper#note!` param `node_or_token` (8 node types)
  - [src/mir/lowering/expressions.rb:1928](../../src/mir/lowering/expressions.rb#L1928) `MIRLoweringExpressions#type_info_for` param `ast_node` (8 node types)
  - [src/tools/migration_suggester_helpers.rb:107](../../src/tools/migration_suggester_helpers.rb#L107) `MigrationSuggesterHelpers#classify_uses!` param `node` (8 node types)
  - [src/annotator/helpers/pipe_analysis.rb:1333](../../src/annotator/helpers/pipe_analysis.rb#L1333) `PipeAnalysis#sharded_get_index_access` param `node` (7 node types)
  - [src/mir/fsm_transform.rb:317](../../src/mir/fsm_transform.rb#L317) `FsmTransform#suspend_value?` param `value` (7 node types)
  - [src/mir/hoist.rb:208](../../src/mir/hoist.rb#L208) `Hoist#moved_arg?` param `node` (7 node types)
  - [src/ast/parser.rb:2059](../../src/ast/parser.rb#L2059) `Parser#extract_paren_bindings` param `node` (6 node types)
  - [src/mir/lowering/expressions.rb:987](../../src/mir/lowering/expressions.rb#L987) `MIRLoweringExpressions#or_fallback_access_path?` param `ast_node` (6 node types)
  - [src/mir/lowering/concurrency.rb:474](../../src/mir/lowering/concurrency.rb#L474) `MIRLoweringConcurrency#do_branch_stmt_nodes` param `expr` (5 node types)
  - [src/annotator/helpers/capabilities.rb:1107](../../src/annotator/helpers/capabilities.rb#L1107) `CapabilityHelper#record_capture_site!` param `node` (4 node types)
  - [src/annotator/helpers/pipe_analysis.rb:1172](../../src/annotator/helpers/pipe_analysis.rb#L1172) `PipeAnalysis#collect_sharded_names` param `node` (4 node types)
  - [src/ast/parser.rb:3976](../../src/ast/parser.rb#L3976) `Parser#deep_clone_node` param `node` (4 node types)
  - [src/mir/cleanup_classifier.rb:1145](../../src/mir/cleanup_classifier.rb#L1145) `CleanupClassifier#classify_struct_cleanup_fields` param `node` (4 node types)
  - [src/annotator/helpers/generic_analysis.rb:44](../../src/annotator/helpers/generic_analysis.rb#L44) `GenericAnalysis#validate_type_param_list!` param `node` (3 node types)
  - [src/mir/lowering/functions.rb:1439](../../src/mir/lowering/functions.rb#L1439) `MIRLoweringFunctions#call_owned_return?` param `node` (3 node types)
  - [src/annotator/helpers/function_analysis.rb:330](../../src/annotator/helpers/function_analysis.rb#L330) `FunctionAnalysis#resolve_call` param `node` (2 node types)
  - [src/annotator/helpers/test_annotation.rb:100](../../src/annotator/helpers/test_annotation.rb#L100) `TestAnnotation#visit_test_hook_bodies` param `node` (2 node types)
  - [src/annotator/helpers/test_annotation.rb:79](../../src/annotator/helpers/test_annotation.rb#L79) `TestAnnotation#visit_test_lets` param `node` (2 node types)
  - [src/ast/parser.rb:2081](../../src/ast/parser.rb#L2081) `Parser#validate_no_bare_bind!` param `node` (2 node types)
  - [src/ast/scope.rb:398](../../src/ast/scope.rb#L398) `Scope#get_path_to_root` param `node` (2 node types)
  - [src/mir/lowering/functions.rb:1215](../../src/mir/lowering/functions.rb#L1215) `MIRLoweringFunctions#matched_call_signature` param `node` (2 node types)
  - [src/mir/lowering/functions.rb:1263](../../src/mir/lowering/functions.rb#L1263) `MIRLoweringFunctions#finalize_call_result` param `node` (2 node types)
- `MirNode` (MIR::*): 54 param slot(s)
  - [src/mir/mir_checker.rb:1025](../../src/mir/mir_checker.rb#L1025) `MIRChecker#collect_linear_expr_ident_names` param `expr` (98 node types)
  - [src/mir/mir_checker.rb:988](../../src/mir/mir_checker.rb#L988) `MIRChecker#check_nested_linear_expr_bodies!` param `expr` (97 node types)
  - [src/mir/mir_checker.rb:2830](../../src/mir/mir_checker.rb#L2830) `MIRChecker#allocating_expr?` param `expr` (78 node types)
  - [src/mir/mir_checker.rb:575](../../src/mir/mir_checker.rb#L575) `MIRChecker#check_linear_stmt!` param `stmt` (76 node types)
  - [src/mir/hoist.rb:800](../../src/mir/hoist.rb#L800) `MIRHoistLowering#normalize_allocating_mir_stmt!` param `stmt` (69 node types)
  - [src/mir/mir_checker.rb:2738](../../src/mir/mir_checker.rb#L2738) `MIRChecker#check_stmt_for_unhoisted` param `node` (69 node types)
  - [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) `MIRHoistLowering#replace_mir_expr_child!` param `parent` (68 node types)
  - [src/mir/mir_checker.rb:1003](../../src/mir/mir_checker.rb#L1003) `MIRChecker#linear_expr_consumed_names` param `expr` (58 node types)
  - [src/mir/mir_checker.rb:965](../../src/mir/mir_checker.rb#L965) `MIRChecker#check_linear_expr_uses!` param `expr` (58 node types)
  - [src/mir/mir_checker.rb:1018](../../src/mir/mir_checker.rb#L1018) `MIRChecker#linear_expr_ident_names` param `expr` (57 node types)
  - [src/mir/hoist.rb:908](../../src/mir/hoist.rb#L908) `MIRHoistLowering#normalize_allocating_result_expr!` param `expr` (52 node types)
  - [src/mir/hoist.rb:783](../../src/mir/hoist.rb#L783) `MIRHoistLowering#consumes_owned_children?` param `node` (50 node types)
  - [src/mir/mir_checker.rb:2791](../../src/mir/mir_checker.rb#L2791) `MIRChecker#check_owned_expr_position_for_unhoisted` param `expr` (49 node types)
  - [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) `MIRHoistLowering#replace_mir_expr_child!` param `old_child` (48 node types)
  - [src/mir/hoist.rb:1025](../../src/mir/hoist.rb#L1025) `MIRHoistLowering#mir_consumes_owned_operands?` param `expr` (45 node types)
  - [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) `MIRHoistLowering#replace_mir_expr_child!` param `new_child` (45 node types)
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` param `init` (38 node types)
  - [src/mir/lowering/variables.rb:379](../../src/mir/lowering/variables.rb#L379) `MIRLoweringVariables#var_decl_suppression` param `init` (38 node types)
  - [src/mir/lowering/variables.rb:396](../../src/mir/lowering/variables.rb#L396) `MIRLoweringVariables#stamp_var_decl_init_target!` param `init` (38 node types)
  - [src/mir/hoist.rb:1160](../../src/mir/hoist.rb#L1160) `MIRHoistLowering#hoist_cleanup_entry` param `mir` (24 node types)
  - [src/mir/lowering/control_flow.rb:921](../../src/mir/lowering/control_flow.rb#L921) `MIRLoweringControlFlow#return_payload_pointer_value` param `value` (20 node types)
  - [src/mir/lowering/control_flow.rb:939](../../src/mir/lowering/control_flow.rb#L939) `MIRLoweringControlFlow#heap_carry_return_value` param `value` (20 node types)
  - [src/mir/lowering/control_flow.rb:952](../../src/mir/lowering/control_flow.rb#L952) `MIRLoweringControlFlow#heap_carry_recursive_param_value` param `value` (20 node types)
  - [src/mir/lowering/control_flow.rb:964](../../src/mir/lowering/control_flow.rb#L964) `MIRLoweringControlFlow#tail_call_return?` param `value` (20 node types)
  - [src/mir/mir_lowering.rb:2163](../../src/mir/mir_lowering.rb#L2163) `MIRLowering#with_ownership_consumption_for_value` param `value_mir` (18 node types)
  - [src/mir/lowering/control_flow.rb:970](../../src/mir/lowering/control_flow.rb#L970) `MIRLoweringControlFlow#return_with_transfer_marks` param `value` (17 node types)
  - [src/mir/lowering/functions.rb:990](../../src/mir/lowering/functions.rb#L990) `MIRLoweringFunctions#cross_boundary_arg` param `arg` (17 node types)
  - [src/mir/mir.rb:2726](../../src/mir/mir.rb#L2726) `MIR#initialize` param `source` (15 node types)
  - [src/mir/hoist.rb:882](../../src/mir/hoist.rb#L882) `MIRHoistLowering#normalize_used_expr_attr!` param `stmt` (12 node types)
  - [src/mir/mir.rb:2859](../../src/mir/mir.rb#L2859) `MIR#initialize` param `source` (12 node types)
  - [src/mir/lowering/variables.rb:794](../../src/mir/lowering/variables.rb#L794) `MIRLoweringVariables#fallible_self_fallback_reassign?` param `value` (11 node types)
  - [src/mir/hoist.rb:1015](../../src/mir/hoist.rb#L1015) `MIRHoistLowering#normalized_alloc_wrapper_alias?` param `expr` (10 node types)
  - [src/mir/mir_lowering.rb:764](../../src/mir/mir_lowering.rb#L764) `MIRLowering#place_owned_branch_value_for_destination` param `mir` (10 node types)
  - [src/mir/fsm_lowering.rb:183](../../src/mir/fsm_lowering.rb#L183) `FsmLowering#coerce_fsm_result_value` param `value` (9 node types)
  - [src/mir/hoist.rb:1079](../../src/mir/hoist.rb#L1079) `MIRHoistLowering#refresh_ownership_consumption_for_replaced_child!` param `parent` (9 node types)
  - [src/mir/hoist.rb:724](../../src/mir/hoist.rb#L724) `MIRHoistLowering#hoist_normalized_alloc_expr` param `expr` (9 node types)
  - [src/mir/lowering/control_flow.rb:100](../../src/mir/lowering/control_flow.rb#L100) `MIRLoweringControlFlow#loop_condition_expr` param `cond` (9 node types)
  - [src/mir/mir_emitter.rb:871](../../src/mir/mir_emitter.rb#L871) `MIREmitter#emit_flow_stmt` param `stmt` (9 node types)
  - [src/mir/mir_checker.rb:1366](../../src/mir/mir_checker.rb#L1366) `MIRChecker#value_constructor_expr?` param `node` (8 node types)
  - [src/mir/hoist.rb:1079](../../src/mir/hoist.rb#L1079) `MIRHoistLowering#refresh_ownership_consumption_for_replaced_child!` param `old_child` (7 node types)
  - [src/mir/mir.rb:3655](../../src/mir/mir.rb#L3655) `MIR#initialize` param `receiver` (7 node types)
  - [src/mir/mir_lowering.rb:1319](../../src/mir/mir_lowering.rb#L1319) `MIRLowering#place_discarded_owned_branch_value` param `mir` (7 node types)
  - [src/mir/mir_lowering.rb:3374](../../src/mir/mir_lowering.rb#L3374) `MIRLowering#try_catch_with_provenance` param `catch_body` (7 node types)
  - [src/mir/lowering/expressions.rb:972](../../src/mir/lowering/expressions.rb#L972) `MIRLoweringExpressions#materialize_or_fallback_value` param `value` (6 node types)
  - [src/mir/lowering/variables.rb:1016](../../src/mir/lowering/variables.rb#L1016) `MIRLoweringVariables#lower_map_indexed_assignment` param `idx` (6 node types)
  - [src/mir/mir.rb:2704](../../src/mir/mir.rb#L2704) `MIR#initialize` param `init` (6 node types)
  - [src/mir/hoist.rb:1250](../../src/mir/hoist.rb#L1250) `MIRHoistLowering#cleanup_entry_for_ownership_effect` param `mir` (5 node types)
  - [src/mir/lowering/concurrency.rb:474](../../src/mir/lowering/concurrency.rb#L474) `MIRLoweringConcurrency#do_branch_stmt_nodes` param `mir` (5 node types)
  - [src/mir/lowering/variables.rb:123](../../src/mir/lowering/variables.rb#L123) `MIRLoweringVariables#compose_capability_wrap` param `inner_mir` (5 node types)
  - [src/mir/mir.rb:2926](../../src/mir/mir.rb#L2926) `MIR#initialize` param `inner` (5 node types)
  - [src/mir/hoist.rb:1234](../../src/mir/hoist.rb#L1234) `MIRHoistLowering#typed_cleanup_entry_for_mir_result` param `mir` (4 node types)
  - [src/mir/hoist.rb:480](../../src/mir/hoist.rb#L480) `MIRHoistLowering#with_pending` param `node` (2 node types)
  - [src/mir/mir_emitter.rb:481](../../src/mir/mir_emitter.rb#L481) `MIREmitter#sharded_map_template` param `node` (2 node types)
  - [src/mir/mir_emitter.rb:488](../../src/mir/mir_emitter.rb#L488) `MIREmitter#sharded_map_substitute_common` param `node` (2 node types)
- `SchemasNode` (Schemas::*): 3 param slot(s)
  - [src/ast/schemas.rb:363](../../src/ast/schemas.rb#L363) `Schemas#union?` param `s` (4 node types)
  - [src/ast/schemas.rb:366](../../src/ast/schemas.rb#L366) `Schemas#enum?` param `s` (4 node types)
  - [src/ast/schemas.rb:369](../../src/ast/schemas.rb#L369) `Schemas#resource?` param `s` (4 node types)

### Untyped Evidence Gaps
- The residual NoEvidence, by category x WHY, then listed with locations. Each is a triage candidate (dead code / missing test / should-be-void / untraceable arg), not a classifier defect.

|  | unseen | arg untraced | only nil | discarded return | collection no elements | struct unobserved | Total |
|---|---|---|---|---|---|---|---|
| Params | 1 | 48 | 4 | 0 | 0 | 0 | 53 |
| Returns | 0 | 0 | 0 | 5 | 0 | 0 | 5 |
| Struct/ivar | 0 | 0 | 0 | 0 | 0 | 14 | 14 |
| Collections | 0 | 0 | 0 | 0 | 81 | 0 | 81 |
| **Total** | 1 | 48 | 4 | 5 | 81 | 14 | 153 |
- `unseen`: Not reached by the collect workload (a superset of every suite) and no runtime record -- genuinely dead/unreachable, or a real missing test. Investigate or delete.
- `arg untraced`: Block / kwarg / splat arg -- the tracer types only positional named args (these are ~always Proc; low value)
- `only nil`: Only ever nil at runtime -- likely unused / optional-dead; verify it is reachable with a real value
- `discarded return`: Return value never consumed -- likely should be `sig { ... .void }`
- `collection no elements`: Collection never observed holding an element -- only-empty, or built/consumed off any instrumented path
- `struct unobserved`: Struct/class field never observed assigned during collect -- the tracer signal for fields is struct_field_runtime/ivar_runtime, not line coverage, so the method-oriented coverage split does not apply. Either the class is never constructed by the workload, or the field is always left at its default.
- 1 unseen
  - [src/mir/mir_lowering.rb:3162](../../src/mir/mir_lowering.rb#L3162) `MIRLowering#importable_module_item?` param `item`
- 48 arg untraced
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls` param `block`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls` param `block`
  - [src/annotator/helpers/capabilities.rb:1076](../../src/annotator/helpers/capabilities.rb#L1076) `CapabilityHelper#with_fiber_capture_analysis` param `blk`
  - [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves` param `blk`
  - [src/annotator/helpers/capabilities.rb:41](../../src/annotator/helpers/capabilities.rb#L41) `Capabilities#validate!` param `error_handler`
  - [src/annotator/helpers/fixable_helpers.rb:752](../../src/annotator/helpers/fixable_helpers.rb#L752) `FixableHelper#emit_match_partial_fix!` param `kwargs`
  - [src/annotator/helpers/pipe_analysis.rb:144](../../src/annotator/helpers/pipe_analysis.rb#L144) `PipeAnalysis#lift_to_observable_if_terminal!` param `type_kwargs`
  - [src/annotator/helpers/pipe_analysis.rb:163](../../src/annotator/helpers/pipe_analysis.rb#L163) `PipeAnalysis#mark_observable_terminal!` param `type_kwargs`
  - [src/annotator/helpers/pipe_analysis.rb:1828](../../src/annotator/helpers/pipe_analysis.rb#L1828) `PipeAnalysis#with_soa_tracking` param `blk`
  - [src/ast/ast.rb:1068](../../src/ast/ast.rb#L1068) `AST::Locatable#finalize_storage!` param `schema_lookup`
  - [src/ast/ast.rb:117](../../src/ast/ast.rb#L117) `AST#initialize` param `kw`
  - [src/ast/ast.rb:1340](../../src/ast/ast.rb#L1340) `AST#initialize` param `args`
  - [src/ast/ast.rb:144](../../src/ast/ast.rb#L144) `AST#initialize` param `kw`
  - [src/ast/ast.rb:1502](../../src/ast/ast.rb#L1502) `AST#initialize` param `kw`
  - [src/ast/ast.rb:1536](../../src/ast/ast.rb#L1536) `AST#initialize` param `args`
  - [src/ast/ast.rb:1589](../../src/ast/ast.rb#L1589) `AST#initialize` param `args`
  - [src/ast/ast.rb:1721](../../src/ast/ast.rb#L1721) `AST#initialize` param `args`
  - [src/ast/ast.rb:1751](../../src/ast/ast.rb#L1751) `AST#initialize` param `args`
  - [src/ast/ast.rb:1882](../../src/ast/ast.rb#L1882) `AST#initialize` param `args`
  - [src/ast/ast.rb:194](../../src/ast/ast.rb#L194) `AST#initialize` param `kw`
  - [src/ast/ast.rb:2044](../../src/ast/ast.rb#L2044) `AST#initialize` param `kw`
  - [src/ast/ast.rb:2242](../../src/ast/ast.rb#L2242) `AST#initialize` param `args`
  - [src/ast/ast.rb:2266](../../src/ast/ast.rb#L2266) `AST#initialize` param `args`
  - [src/ast/ast.rb:2449](../../src/ast/ast.rb#L2449) `AST#initialize` param `args`
  - [src/ast/ast.rb:253](../../src/ast/ast.rb#L253) `AST#initialize` param `kw`
  - [src/ast/ast.rb:306](../../src/ast/ast.rb#L306) `AST#initialize` param `kw`
  - [src/ast/ast.rb:719](../../src/ast/ast.rb#L719) `AST#each_bg_block` param `block`
  - [src/ast/ast.rb:726](../../src/ast/ast.rb#L726) `AST#_bg_visit_recursive` param `block`
  - [src/ast/ast.rb:744](../../src/ast/ast.rb#L744) `AST#_expr_each_bg_block_recursive` param `block`
  - [src/ast/ast.rb:776](../../src/ast/ast.rb#L776) `AST#each_bg_block_in_stmt` param `block`
  - [src/ast/ast.rb:791](../../src/ast/ast.rb#L791) `AST#_expr_each_bg_block_shallow` param `block`
  - [src/ast/ast.rb:838](../../src/ast/ast.rb#L838) `AST#_expr_each_concurrent_capture` param `block`
  - [src/ast/parser.rb:54](../../src/ast/parser.rb#L54) `Parser#stmt` param `block`
  - [src/ast/parser.rb:70](../../src/ast/parser.rb#L70) `Parser#primary` param `block`
  - [src/ast/parser.rb:85](../../src/ast/parser.rb#L85) `Parser#suffix` param `block`
  - [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) `ErrorHelper#error!` param `kwargs`
  - [src/ast/type.rb:2610](../../src/ast/type.rb#L2610) `Type#slot_size` param `lookup_block`
  - [src/ast/type.rb:2663](../../src/ast/type.rb#L2663) `Type#copyable?` param `lookup_block`
  - [src/ast/type.rb:2695](../../src/ast/type.rb#L2695) `Type#bg_capture_is_value_copy?` param `lookup_block`
  - [src/ast/type.rb:2722](../../src/ast/type.rb#L2722) `Type#implicitly_copyable?` param `lookup_block`
  - [src/lsp/document_store.rb:82](../../src/lsp/document_store.rb#L82) `LSP::DocumentStore#each` param `block`
  - [src/mir/cleanup_classifier.rb:724](../../src/mir/cleanup_classifier.rb#L724) `CleanupClassifier#each_capture_binding` param `block`
  - [src/mir/cleanup_entry.rb:40](../../src/mir/cleanup_entry.rb#L40) `CleanupEntry#build` param `extra`
  - [src/mir/control_flow.rb:1691](../../src/mir/control_flow.rb#L1691) `LoopFrameAnalysis#walk_all_nodes` param `block`
  - [src/mir/fsm_transform/liveness.rb:258](../../src/mir/fsm_transform/liveness.rb#L258) `FsmTransform::Liveness#walk_idents` param `block`
  - [src/mir/mir.rb:4747](../../src/mir/mir.rb#L4747) `MIR::StdlibDefFsCoercion#initialize` param `args`
  - [src/mir/test_lowering.rb:167](../../src/mir/test_lowering.rb#L167) `TestLowering#with_test_that_bindings` param `blk`
  - [src/tools/migration_suggester_helpers.rb:85](../../src/tools/migration_suggester_helpers.rb#L85) `MigrationSuggesterHelpers#walk_recursive` param `visitor`
- 4 only nil
  - [src/ast/ast.rb:1727](../../src/ast/ast.rb#L1727) `AST#params=` param `val`
  - [src/ast/ast.rb:2274](../../src/ast/ast.rb#L2274) `AST#params=` param `val`
  - [src/mir/control_flow.rb:1308](../../src/mir/control_flow.rb#L1308) `UseAfterMoveChecker#check` param `can_fail_fns`
  - [src/mir/mir_checker.rb:347](../../src/mir/mir_checker.rb#L347) `MIRChecker#initialize` param `fn_name`
- 5 discarded return
  - [src/annotator/helpers/fixable_helpers.rb:1005](../../src/annotator/helpers/fixable_helpers.rb#L1005) `FixableHelper#emit_with_materialized_needs_tense!` return
  - [src/annotator/helpers/fixable_helpers.rb:860](../../src/annotator/helpers/fixable_helpers.rb#L860) `FixableHelper#emit_with_guard_all_bindings_need_as!` return
  - [src/ast/parser.rb:614](../../src/ast/parser.rb#L614) `Parser#emit_consume_error_with_fix` return
  - [src/ast/parser.rb:633](../../src/ast/parser.rb#L633) `Parser#emit_syntax_insert_end_of_line!` return
  - [src/ast/parser.rb:656](../../src/ast/parser.rb#L656) `Parser#emit_syntax_insert_before_token!` return
- ... and 2 more (run with `--full` to see all)

### Signature Slot Evidence
- primary reason: the single strongest current explanation for why this weak/untyped signature slot has not been safely strengthened
- evidence count: runtime observations plus static callsite/origin records feeding the slot
- candidate action: an existing nil-kill action that could rewrite this slot, if one exists

#### Param Slot Evidence
- blocked: unknown callsite expression: 220 slot(s); weak 0, untyped 220; evidence 4060
  - [src/mir/mir_lowering.rb:1862](../../src/mir/mir_lowering.rb#L1862) `MIRLowering#ownership_contract_source_node` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/mir_lowering.rb:1700](../../src/mir/mir_lowering.rb#L1700) expr; [src/mir/mir_lowering.rb:1719](../../src/mir/mir_lowering.rb#L1719) expr; src/mir/mir_ ...; evidence 126
  - [src/mir/mir_lowering.rb:2067](../../src/mir/mir_lowering.rb#L2067) `MIRLowering#ownership_contract_for_node` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/hoist.rb:1026](../../src/mir/hoist.rb#L1026) expr; [src/mir/mir_lowering.rb:2038](../../src/mir/mir_lowering.rb#L2038) surface_node; protocol hint  ...; evidence 126
  - [src/annotator/helpers/auto_inference.rb:242](../../src/annotator/helpers/auto_inference.rb#L242) `AutoConstraintCollector#record_constraint` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/annotator/helpers/auto_inference.rb:225](../../src/annotator/helpers/auto_inference.rb#L225) node; protocol hint dire ...; evidence 119
  - [src/mir/mir_checker.rb:1025](../../src/mir/mir_checker.rb#L1025) `MIRChecker#collect_linear_expr_ident_names` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/mir_checker.rb:1007](../../src/mir/mir_checker.rb#L1007) node; [src/mir/mir_checker.rb:1020](../../src/mir/mir_checker.rb#L1020) expr; src/mir/mir_che ...; evidence 102
  - [src/mir/mir_checker.rb:988](../../src/mir/mir_checker.rb#L988) `MIRChecker#check_nested_linear_expr_bodies!` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/mir_checker.rb:983](../../src/mir/mir_checker.rb#L983) expr; [src/mir/mir_checker.rb:996](../../src/mir/mir_checker.rb#L996) sub; protocol hint medi ...; evidence 100
  - [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) `MIRHoistLowering#each_mir_expr_in_value` value; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/hoist.rb:571](../../src/mir/hoist.rb#L571) value; [src/mir/hoist.rb:581](../../src/mir/hoist.rb#L581) child; [src/mir/hoist.rb:583](../../src/mir/hoist.rb#L583) child; protocol ...; evidence 99
  - [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231) `Hoist#each_call_like` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/hoist.rb:219](../../src/mir/hoist.rb#L219) node; [src/mir/hoist.rb:227](../../src/mir/hoist.rb#L227) node; [src/mir/hoist.rb:248](../../src/mir/hoist.rb#L248) c; protocol hint weak direct protocol ...; evidence 98
  - [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) `MIRHoistLowering#mir_expr_child?` value; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; [src/mir/hoist.rb:578](../../src/mir/hoist.rb#L578) value; protocol hint medium direct protocol #expr?; other potential options, n ...; evidence 97
- candidate: runtime-only param observation: 189 slot(s); weak 0, untyped 189; evidence 2466
  - [src/ast/schemas.rb:233](../../src/ast/schemas.rb#L233) Schemas::InlineStructVariant#== other; `T.untyped`; single observed type; narrow candidate; untyped instance variable; [src/annotator/domains/control_flow.rb:78](../../src/annotator/domains/control_flow.rb#L78) :moved; [src/annotator/domains/control_flow.rb:243](../../src/annotator/domains/control_flow.rb#L243) :Int64; s ...; evidence 1720
  - [src/mir/fsm_transform/segments.rb:171](../../src/mir/fsm_transform/segments.rb#L171) `FsmTransform::Segments#split` body; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; [src/annotator/annotator.rb:685](../../src/annotator/annotator.rb#L685) '::'; [src/annotator/domains/lifetimes.rb:497](../../src/annotator/domains/lifetimes.rb#L497) "."; src/annot ...; evidence 48
  - [src/mir/fsm_wrapper_emitter.rb:708](../../src/mir/fsm_wrapper_emitter.rb#L708) `FsmWrapperEmitter#indent_block` text; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; [src/mir/fsm_wrapper_emitter.rb:97](../../src/mir/fsm_wrapper_emitter.rb#L97) capture_fields; [src/mir/fsm_wrapper_emitter.rb:114](../../src/mir/fsm_wrapper_emitter.rb#L114) l; src ...; evidence 32
  - [src/ast/source_error.rb:122](../../src/ast/source_error.rb#L122) `ErrorHelper#fixable!` raise_in_collector; `T.untyped`; boolean pair; T::Boolean candidate; untyped literal/static expression; [src/annotator/domains/lifetimes.rb:691](../../src/annotator/domains/lifetimes.rb#L691) true; [src/annotator/domains/lifetimes.rb:759](../../src/annotator/domains/lifetimes.rb#L759) true; ...; evidence 25
  - [src/mir/fsm_transform.rb:302](../../src/mir/fsm_transform.rb#L302) `FsmTransform#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; [src/mir/fsm_transform.rb:296](../../src/mir/fsm_transform.rb#L296) body; [src/mir/fsm_transform.rb:308](../../src/mir/fsm_transform.rb#L308) body; src/mir/fsm_trans ...; evidence 20
  - [src/mir/fsm_transform/recursive_splitter.rb:320](../../src/mir/fsm_transform/recursive_splitter.rb#L320) `FsmTransform::RecursiveSplitter#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; [src/mir/fsm_transform.rb:296](../../src/mir/fsm_transform.rb#L296) body; src/mir/fsm_tr ...; evidence 20
  - [src/mir/fsm_transform/segments.rb:318](../../src/mir/fsm_transform/segments.rb#L318) `FsmTransform::Segments#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; [src/mir/fsm_transform.rb:296](../../src/mir/fsm_transform.rb#L296) body; [src/mir/fsm_transform.rb:308](../../src/mir/fsm_transform.rb#L308) body ...; evidence 20
  - [src/mir/mir_lowering.rb:549](../../src/mir/mir_lowering.rb#L549) `MIRLowering#place_value_for_destination` dest_type; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; [src/mir/fsm_lowering.rb:111](../../src/mir/fsm_lowering.rb#L111) expr_t; [src/mir/lowering/concurrency.rb:919](../../src/mir/lowering/concurrency.rb#L919) inner_t; src ...; evidence 17
- weak declared type: union: 157 slot(s); weak 157, untyped 0; evidence 5550
  - [src/mir/mir.rb:799](../../src/mir/mir.rb#L799) MIR::InlineAllocMetadata#[] key; T.any(Symbol, String); weak declared type: union; untyped instance variable; [src/annotator/annotator.rb:105](../../src/annotator/annotator.rb#L105) String; [src/annotator/annotator.rb:114](../../src/annotator/annotator.rb#L114) Type; [src/annotator/annotator.rb:118](../../src/annotator/annotator.rb#L118) Snap ...; evidence 4992
  - [src/mir/mir.rb:794](../../src/mir/mir.rb#L794) `MIR::InlineAllocMetadata#key?` key; T.any(Symbol, String); weak declared type: union; untyped forwarded return; [src/annotator/domains/control_flow.rb:211](../../src/annotator/domains/control_flow.rb#L211) f.name; [src/annotator/domains/control_flow.rb:229](../../src/annotator/domains/control_flow.rb#L229) f.name; src/annota ...; evidence 106
  - [src/semantic/ownership_identity.rb:34](../../src/semantic/ownership_identity.rb#L34) `OwnershipIdentity::PlaceId#from_path` path; T.any(String, Symbol, PlaceId); weak declared type: union; untyped forwarded return; [src/mir/cleanup_classifier.rb:66](../../src/mir/cleanup_classifier.rb#L66) name; [src/mir/cleanup_classifier.rb:75](../../src/mir/cleanup_classifier.rb#L75) na ...; evidence 20
  - [src/ast/ast.rb:133](../../src/ast/ast.rb#L133) `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; [src/annotator/domains/variables.rb:70](../../src/annotator/domains/variables.rb#L70) target_t; [src/annotator/helpers/auto_inference.rb:623](../../src/annotator/helpers/auto_inference.rb#L623) Type.new(:"#{element_ ...; evidence 15
  - [src/ast/ast.rb:1513](../../src/ast/ast.rb#L1513) `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; [src/annotator/domains/variables.rb:70](../../src/annotator/domains/variables.rb#L70) target_t; [src/annotator/helpers/auto_inference.rb:623](../../src/annotator/helpers/auto_inference.rb#L623) Type.new(:"#{element ...; evidence 15
  - [src/ast/ast.rb:1543](../../src/ast/ast.rb#L1543) `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; [src/annotator/domains/variables.rb:70](../../src/annotator/domains/variables.rb#L70) target_t; [src/annotator/helpers/auto_inference.rb:623](../../src/annotator/helpers/auto_inference.rb#L623) Type.new(:"#{element ...; evidence 15
  - [src/ast/ast.rb:1596](../../src/ast/ast.rb#L1596) `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; [src/annotator/domains/variables.rb:70](../../src/annotator/domains/variables.rb#L70) target_t; [src/annotator/helpers/auto_inference.rb:623](../../src/annotator/helpers/auto_inference.rb#L623) Type.new(:"#{element ...; evidence 15
  - [src/ast/ast.rb:162](../../src/ast/ast.rb#L162) `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; [src/annotator/domains/variables.rb:70](../../src/annotator/domains/variables.rb#L70) target_t; [src/annotator/helpers/auto_inference.rb:623](../../src/annotator/helpers/auto_inference.rb#L623) Type.new(:"#{element_ ...; evidence 15
- blocked: forwarded return argument: 137 slot(s); weak 0, untyped 137; evidence 4910
  - [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) `ErrorHelper#error!` node_or_token; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/annotator/annotator.rb:507](../../src/annotator/annotator.rb#L507) node; [src/annotator/domains/control_flow.rb:144](../../src/annotator/domains/control_flow.rb#L144) b.expr; src/annotator/ ...; evidence 467
  - [src/mir/mir_emitter.rb:53](../../src/mir/mir_emitter.rb#L53) `MIREmitter#emit` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/backends/importer.rb:235](../../src/backends/importer.rb#L235) item; [src/backends/importer.rb:236](../../src/backends/importer.rb#L236) item; [src/backends/transpiler.rb:110](../../src/backends/transpiler.rb#L110) program; prot ...; evidence 335
  - [src/mir/mir_lowering.rb:877](../../src/mir/mir_lowering.rb#L877) `MIRLowering#lower` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/mir/fsm_lowering.rb:110](../../src/mir/fsm_lowering.rb#L110) last_step.expr; [src/mir/fsm_lowering.rb:310](../../src/mir/fsm_lowering.rb#L310) step.expr; [src/mir/fsm_lowering.rb:490](../../src/mir/fsm_lowering.rb#L490) ...; evidence 264
  - [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) `AutoConstraintCollector#walk` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/annotator/helpers/auto_inference.rb:173](../../src/annotator/helpers/auto_inference.rb#L173) program_node; src/annotator/helpers/aut ...; evidence 149
  - [src/mir/mir_lowering.rb:1847](../../src/mir/mir_lowering.rb#L1847) `MIRLowering#ownership_fact_source` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/mir/mir_checker.rb:2332](../../src/mir/mir_checker.rb#L2332) fact; [src/mir/mir_lowering.rb:1574](../../src/mir/mir_lowering.rb#L1574) alloc_mark; src/mir/mir_loweri ...; evidence 137
  - [src/ast/type.rb:3006](../../src/ast/type.rb#L3006) `Type#from_node!` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/annotator/domains/lifetimes.rb:147](../../src/annotator/domains/lifetimes.rb#L147) node.value; [src/annotator/domains/lifetimes.rb:625](../../src/annotator/domains/lifetimes.rb#L625) info.type; src/annotator/doma ...; evidence 136
  - [src/mir/hoist.rb:548](../../src/mir/hoist.rb#L548) `MIRHoistLowering#mir_allocates?` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/mir/fsm_lowering.rb:112](../../src/mir/fsm_lowering.rb#L112) last_mir; [src/mir/hoist.rb:499](../../src/mir/hoist.rb#L499) expr; [src/mir/hoist.rb:554](../../src/mir/hoist.rb#L554) child; protocol h ...; evidence 100
  - [src/ast/ast.rb:838](../../src/ast/ast.rb#L838) `AST#_expr_each_concurrent_capture` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; [src/ast/ast.rb:833](../../src/ast/ast.rb#L833) node; [src/ast/ast.rb:846](../../src/ast/ast.rb#L846) node.left; [src/ast/ast.rb:847](../../src/ast/ast.rb#L847) node.right; protocol hint str ...; evidence 90
- weak declared type: array element evidence needed: 93 slot(s); weak 93, untyped 0; evidence 446
  - [src/ast/parser.rb:70](../../src/ast/parser.rb#L70) `Parser#primary` pattern; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped struct/array/collection value; [src/ast/parser.rb:229](../../src/ast/parser.rb#L229) ['CAST', '(', :expression, 'AS', :type_annotation,  ...; evidence 31
  - [src/mir/mir_emitter.rb:2644](../../src/mir/mir_emitter.rb#L2644) `MIREmitter#emit_body` stmts; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; [src/mir/mir_emitter.rb:230](../../src/mir/mir_emitter.rb#L230) plan.promoted_decls; [src/mir/mir_emitter.rb:660](../../src/mir/mir_emitter.rb#L660) stmts; src/ ...; evidence 29
  - [src/mir/mir_checker.rb:564](../../src/mir/mir_checker.rb#L564) `MIRChecker#check_linear_stmts!` stmts; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; [src/mir/mir_checker.rb:555](../../src/mir/mir_checker.rb#L555) body; [src/mir/mir_checker.rb:654](../../src/mir/mir_checker.rb#L654) stmt.b ...; evidence 26
  - [src/ast/diagnostic_registry.rb:2811](../../src/ast/diagnostic_registry.rb#L2811) `DiagnosticRegistry#format` args; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; [src/mir/lowering/capabilities.rb:879](../../src/mir/lowering/capabilities.rb#L879) b; [src/mir/pre_mir_type_check.rb:47](../../src/mir/pre_mir_type_check.rb#L47) n ...; evidence 18
  - [src/ast/ast.rb:28](../../src/ast/ast.rb#L28) `AST::BodySlot#replace` body; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; [src/mir/hoist.rb:902](../../src/mir/hoist.rb#L902) normalize_allocating_mir_body(slot.body); [src/mir/mir_checker.rb:950](../../src/mir/mir_checker.rb#L950) source ...; evidence 15
  - [src/mir/mir_checker.rb:1044](../../src/mir/mir_checker.rb#L1044) `MIRChecker#verify_move_mark_scope!` body; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; [src/mir/mir_checker.rb:443](../../src/mir/mir_checker.rb#L443) fn_def.body; [src/mir/mir_checker.rb](../../src/mir/mir_checker.rb) ...; evidence 14
  - [src/semantic/local_binding_facts.rb:47](../../src/semantic/local_binding_facts.rb#L47) `MIR::LocalBindingAnalysis#each_direct_loop_node` body; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; [src/mir/cleanup_classifier.rb:292](../../src/mir/cleanup_classifier.rb#L292) body; src/mir/c ...; evidence 13
  - [src/mir/mir_checker.rb:1127](../../src/mir/mir_checker.rb#L1127) `MIRChecker#check_aggregate_stmts!` stmts; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; [src/mir/mir_checker.rb:1123](../../src/mir/mir_checker.rb#L1123) body; [src/mir/mir_checker.rb:1142](../../src/mir/mir_checker.rb#L1142)  ...; evidence 12
- blocked: no static callsite evidence: 70 slot(s); weak 0, untyped 70; evidence 131
  - [src/mir/lowering/control_flow.rb:1209](../../src/mir/lowering/control_flow.rb#L1209) `MIRLoweringControlFlow#call_union_return_needs_hoist?` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none ...; evidence 24
  - [src/mir/lowering/control_flow.rb:1209](../../src/mir/lowering/control_flow.rb#L1209) `MIRLoweringControlFlow#call_union_return_needs_hoist?` ast_node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint strong direct pro ...; evidence 21
  - [src/mir/mir.rb:2726](../../src/mir/mir.rb#L2726) `MIR#initialize` source; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 15
  - [src/mir/mir.rb:2859](../../src/mir/mir.rb#L2859) `MIR#initialize` source; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 12
  - [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462) `SymbolEntry#initialize` reg; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in @reg ...; evidence 9
  - [src/mir/mir.rb:3655](../../src/mir/mir.rb#L3655) `MIR#initialize` receiver; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 7
  - [src/mir/mir.rb:2704](../../src/mir/mir.rb#L2704) `MIR#initialize` init; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 6
  - [src/mir/mir.rb:2926](../../src/mir/mir.rb#L2926) `MIR#initialize` inner; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 5
- weak declared type: hash key/value evidence needed: 36 slot(s); weak 36, untyped 0; evidence 93
  - [src/annotator/helpers/generic_analysis.rb:369](../../src/annotator/helpers/generic_analysis.rb#L369) `GenericAnalysis#apply_type_subst` subst; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; [src/annotator/domains/control_flow.rb:278](../../src/annotator/domains/control_flow.rb#L278) union_ ...; evidence 10
  - [src/annotator/helpers/pipe_analysis.rb:96](../../src/annotator/helpers/pipe_analysis.rb#L96) `PipeAnalysis#concurrent_parallel_enabled?` options; T::Hash[String, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; [src/annotator/helpers/pipe_analysis.rb:16](../../src/annotator/helpers/pipe_analysis.rb#L16) ...; evidence 5
  - [src/mir/cleanup_entry.rb:65](../../src/mir/cleanup_entry.rb#L65) `CleanupEntry#from` h; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; [src/mir/lower/pipeline/pipeline_range_lowerer.rb:433](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb#L433) T.must(entry.publish); src/mir/m ...; evidence 5
  - [src/mir/mir_checker.rb:2204](../../src/mir/mir_checker.rb#L2204) `MIRChecker#verify_callable_contract!` allocs; T::Hash[String, T::Array[`T.untyped`]]; weak declared type: hash key/value evidence needed; untyped unknown expression; [src/mir/mir_checker.rb:2191](../../src/mir/mir_checker.rb#L2191) allocs; src/mir/mir_c ...; evidence 5
  - [src/mir/test_lowering.rb:299](../../src/mir/test_lowering.rb#L299) `TestLowering#collect_identifier_refs` name_set; T::Hash[String, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; [src/mir/test_lowering.rb:275](../../src/mir/test_lowering.rb#L275) let_ast_map; src ...; evidence 5
  - [src/annotator/domains/errors.rb:350](../../src/annotator/domains/errors.rb#L350) `Annotator::Domains::Errors#emit_error_type_conflict!` conflict; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped unknown expression; [src/annotator/domains/errors.rb:3](../../src/annotator/domains/errors.rb#L3) ...; evidence 3
  - [src/annotator/helpers/generic_analysis.rb:338](../../src/annotator/helpers/generic_analysis.rb#L338) `GenericAnalysis#extract_type_bindings!` subst; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/annotator/helpers/generic ...; evidence 3
  - [src/annotator/helpers/reentrance.rb:724](../../src/annotator/helpers/reentrance.rb#L724) `ReentranceBridge#compute_reachable` graph; T::Hash[String, T::Set[`T.untyped`]]; weak declared type: hash key/value evidence needed; untyped forwarded return; [src/annotator/helpers/reentrance.rb:712](../../src/annotator/helpers/reentrance.rb#L712) func ...; evidence 3
- weak declared type: nested `T.untyped`: 18 slot(s); weak 18, untyped 0; evidence 9
  - [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231) `Hoist#each_call_like` matches; `T.proc`.params(candidate: `T.untyped`).returns(T::Boolean); weak declared type: nested `T.untyped`; untyped unknown expression; [src/mir/hoist.rb:219](../../src/mir/hoist.rb#L219) ->(candidate) { candidate.is_a?(AST::MethodCa ...; evidence 6
  - [src/mir/hoist.rb:246](../../src/mir/hoist.rb#L246) `Hoist#each_call_like_child` matches; `T.proc`.params(candidate: `T.untyped`).returns(T::Boolean); weak declared type: nested `T.untyped`; untyped unknown expression; [src/mir/hoist.rb:241](../../src/mir/hoist.rb#L241) matches; evidence 2
  - [src/ast/ast.rb:22](../../src/ast/ast.rb#L22) `AST::BodySlot#initialize` writer; `T.proc`.params(body: T::Array[`T.untyped`]).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 1
  - [src/ast/ast.rb:383](../../src/ast/ast.rb#L383) `AST#walk_body` visitor; `T.proc`.params(node: `T.untyped`).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - [src/ast/parser.rb:3937](../../src/ast/parser.rb#L3937) `Parser#parse_comma_seq` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - [src/ast/scope.rb:492](../../src/ast/scope.rb#L492) `ScopeHelper#with_new_scope` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - [src/mir/control_flow.rb:1999](../../src/mir/control_flow.rb#L1999) `BorrowChecker#walk_for_was_moved` blk; `T.proc`.params(node: `T.untyped`).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - [src/mir/hoist.rb:218](../../src/mir/hoist.rb#L218) `Hoist#each_method_call` blk; `T.proc`.params(arg0: `T.untyped`).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
- blocked: runtime union policy: 11 slot(s); weak 0, untyped 11; evidence 2209
  - [src/ast/type.rb:1369](../../src/ast/type.rb#L1369) Type#== other; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped instance variable; [src/annotator/domains/control_flow.rb:78](../../src/annotator/domains/control_flow.rb#L78) :moved; [src/annotator/domains/control_flow.rb:243](../../src/annotator/domains/control_flow.rb#L243) :Int64; src/annotator/domains/cont ...; evidence 1721
  - [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) `ErrorHelper#error!` code_or_message; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/annotator/annotator.rb:507](../../src/annotator/annotator.rb#L507) :WITH_SNAPSHOT_BODY_NOT_PURE; src/annotator/domains/control ...; evidence 403
  - [src/mir/hoist.rb:1160](../../src/mir/hoist.rb#L1160) `MIRHoistLowering#hoist_cleanup_entry` ast_node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/mir/hoist.rb:615](../../src/mir/hoist.rb#L615) ast_node; [src/mir/hoist.rb:730](../../src/mir/hoist.rb#L730) nil; [src/mir/hoist.rb:984](../../src/mir/hoist.rb#L984) nil; p ...; evidence 32
  - [src/backends/pipeline_rewriter.rb:294](../../src/backends/pipeline_rewriter.rb#L294) `PipelineRewriter#fuse_pipeline` terminal; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/backends/pipeline_rewriter.rb:173](../../src/backends/pipeline_rewriter.rb#L173) terminal; src/backends/pipeline_rewr ...; evidence 14
  - [src/mir/fsm_wrapper_emitter.rb:46](../../src/mir/fsm_wrapper_emitter.rb#L46) `FsmWrapperEmitter#render` body; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/lsp/server.rb:258](../../src/lsp/server.rb#L258) doc; [src/mir/fsm_ops.rb:424](../../src/mir/fsm_ops.rb#L424) "__ctx_#{@ctx_id}"; src/mir/mir_emitte ...; evidence 8
  - [src/mir/hoist.rb:1206](../../src/mir/hoist.rb#L1206) `MIRHoistLowering#deep_copy_zig_type` ast_node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/mir/hoist.rb:644](../../src/mir/hoist.rb#L644) nil; [src/mir/hoist.rb:1177](../../src/mir/hoist.rb#L1177) ast_node; protocol hint direct protoc ...; evidence 8
  - [src/mir/cleanup_classifier.rb:1145](../../src/mir/cleanup_classifier.rb#L1145) `CleanupClassifier#classify_struct_cleanup_fields` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/mir/cleanup_classifier.rb:587](../../src/mir/cleanup_classifier.rb#L587) nil; src/mir/cleanup_classifi ...; evidence 7
  - [src/lsp/document_store.rb:29](../../src/lsp/document_store.rb#L29) `LSP::DocumentStore#cached_findings=` value; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; [src/lsp/document_store.rb:55](../../src/lsp/document_store.rb#L55) nil; [src/lsp/server.rb:271](../../src/lsp/server.rb#L271) result; protocol hint dir ...; evidence 6
- blocked: collection/hash argument evidence: 7 slot(s); weak 0, untyped 7; evidence 84
  - [src/mir/mir_lowering.rb:1292](../../src/mir/mir_lowering.rb#L1292) `MIRLowering#materialize_statement_discard` stmt; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; [src/mir/lowering/concurrency.rb:907](../../src/mir/lowering/concurrency.rb#L907) expr; [src/mir/mir_lowering.rb:1271](../../src/mir/mir_lowering.rb#L1271) s ...; evidence 34
  - [src/annotator/helpers/pipe_analysis.rb:1299](../../src/annotator/helpers/pipe_analysis.rb#L1299) `PipeAnalysis#each_shard_scan_node` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; [src/annotator/helpers/pipe_analysis.rb:1174](../../src/annotator/helpers/pipe_analysis.rb#L1174) node; src/annotator/h ...; evidence 18
  - [src/mir/fsm_ops.rb:472](../../src/mir/fsm_ops.rb#L472) `FsmOps#walk` block; `T.untyped`; slot not observed: source index did not model this param shape; untyped struct/array/collection value; [src/annotator/helpers/auto_inference.rb:723](../../src/annotator/helpers/auto_inference.rb#L723) name_map; src/annotator/helpers/auto_inf ...; evidence 14
  - [src/mir/control_flow.rb:1691](../../src/mir/control_flow.rb#L1691) `LoopFrameAnalysis#walk_all_nodes` nodes; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; [src/mir/control_flow.rb:1703](../../src/mir/control_flow.rb#L1703) body; [src/mir/control_flow.rb:1727](../../src/mir/control_flow.rb#L1727) expr; protocol h ...; evidence 7
  - [src/annotator/helpers/fixable_helpers.rb:66](../../src/annotator/helpers/fixable_helpers.rb#L66) `FixableHelper#closest_name` candidates; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; [src/annotator/helpers/fixable_helpers.rb:110](../../src/annotator/helpers/fixable_helpers.rb#L110) candidates; src/annot ...; evidence 5
  - [src/mir/fsm_transform/segments.rb:216](../../src/mir/fsm_transform/segments.rb#L216) `FsmTransform::Segments#split_while_loop_next` body; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; [src/mir/fsm_transform/segments.rb:178](../../src/mir/fsm_transform/segments.rb#L178) body; protocol hint me ...; evidence 3
  - [src/mir/fsm_transform/segments.rb:402](../../src/mir/fsm_transform/segments.rb#L402) `FsmTransform::Segments#rewrite_pipeline_io` body; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; [src/mir/fsm_transform/segments.rb:176](../../src/mir/fsm_transform/segments.rb#L176) body; protocol hint weak ...; evidence 3
- ... and 1 more (run with `--full` to see all)

#### Return Slot Evidence
- weak declared type: array element evidence needed: 80 slot(s); weak 80, untyped 0; evidence 266
  - [src/ast/ast.rb:679](../../src/ast/ast.rb#L679) `AST#expression_children` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; static []; static []; typed_call [node.value].compact; evidence 16
  - [src/mir/fsm_transform/segments.rb:216](../../src/mir/fsm_transform/segments.rb#L216) `FsmTransform::Segments#split_while_loop_next` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped struct/array/collection value; nil nil; nil nil; nil nil;  ...; evidence 14
  - [src/backends/pipeline_rewriter.rb:396](../../src/backends/pipeline_rewriter.rb#L396) `PipelineRewriter#build_init` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [decl]; static [sum_decl, cnt_decl]; static [dec ...; evidence 9
  - [src/backends/pipeline_rewriter.rb:492](../../src/backends/pipeline_rewriter.rb#L492) `PipelineRewriter#build_recursive_body` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; typed_call build_terminal_action(terminal, current_val, re ...; evidence 9
  - [src/annotator/helpers/auto_inference.rb:817](../../src/annotator/helpers/auto_inference.rb#L817) `ShapeEvidenceCollector#record_index_assign` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; nil return; nil return; nil return; evidence 8
  - [src/annotator/helpers/auto_inference.rb:790](../../src/annotator/helpers/auto_inference.rb#L790) `ShapeEvidenceCollector#record_method_call` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; nil return; nil return; call_untyped  ...; evidence 7
  - [src/mir/hoist.rb:116](../../src/mir/hoist.rb#L116) `Hoist#child_bodies` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [stmt.body]; static [stmt.do_branch]; typed_call [stmt.then_branch, stmt.e ...; evidence 7
  - [src/ast/ast.rb:662](../../src/ast/ast.rb#L662) `AST#wrapped_children` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; typed_call (expr.fields&.values || []).compact; call_untyped (expr.items || []).compact; stati ...; evidence 6
- blocked: forwarded return chain: 72 slot(s); weak 0, untyped 72; evidence 981
  - [src/ast/parser.rb:1916](../../src/ast/parser.rb#L1916) `Parser#parse_unary` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; static AST::UnaryOp.new(op_token, AST::OP_TO_OP_CODE[v], right); static AST::CallSiteOverride.new(sigil_tok, `T.m` ...; evidence 63
  - [src/ast/parser.rb:2477](../../src/ast/parser.rb#L2477) `Parser#parse_primary` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped instance_exec(&rule); call_untyped parse_unary(); call_untyped parse_suffixes(lit); evidence 63
  - [src/mir/lowering/variables.rb:557](../../src/mir/lowering/variables.rb#L557) `MIRLoweringVariables#lower_var_decl_init` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped lower_next_expr(node.value, decl_alloc); call_untyped place_value_ ...; evidence 60
  - [src/ast/parser.rb:711](../../src/ast/parser.rb#L711) `Parser#parse_statement` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown result; call_untyped instance_exec(&rule); unknown expr; evidence 45
  - [src/mir/mir_lowering.rb:2545](../../src/mir/mir_lowering.rb#L2545) `MIRLowering#with_decl_alloc` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped blk.call; evidence 41
  - [src/mir/fsm_transform/liveness.rb:258](../../src/mir/fsm_transform/liveness.rb#L258) `FsmTransform::Liveness#walk_idents` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; nil return; nil return; nil return; evidence 30
  - [src/mir/lowering/control_flow.rb:939](../../src/mir/lowering/control_flow.rb#L939) `MIRLoweringControlFlow#heap_carry_return_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown value; unknown value; unknown value; evidence 27
  - [src/mir/lowering/control_flow.rb:921](../../src/mir/lowering/control_flow.rb#L921) `MIRLoweringControlFlow#return_payload_pointer_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown value; unknown value; unknown value; evidence 26
- weak declared type: union: 36 slot(s); weak 36, untyped 0; evidence 80
  - [src/annotator/domains/member_access.rb:407](../../src/annotator/domains/member_access.rb#L407) `Annotator::Domains::MemberAccess#visit_ListLit` return; T.nilable(T.any(Symbol, Type)); weak declared type: union; untyped literal/static expression; nil return; nil return; nil return; evidence 5
  - [src/mir/lower/pipeline/pipeline_host.rb:524](../../src/mir/lower/pipeline/pipeline_host.rb#L524) `PipelineHost#visit` return; T.any(String, MIR::Node); weak declared type: union; untyped forwarded return; typed_call visit_mir(node); unknown replacement; static "__soa_#{target.field}[__soa_i]"; evidence 5
  - [src/mir/mir.rb:1524](../../src/mir/mir.rb#L1524) `MIR::MutualThunkArm#fetch` return; T.any(String, T::Array[ThunkBaseCase], T::Array[ThunkFrameInit]); weak declared type: union; untyped forwarded return; static variant_name; call_untyped base_cases; call_untyped target_v ...; evidence 5
  - [src/mir/lowering/concurrency.rb:1000](../../src/mir/lowering/concurrency.rb#L1000) `MIRLoweringConcurrency#lower_bg_stream_block` return; T.any(MIR::BgBlock, MIR::BlockExpr, MIR::InlineBc, MIR::StreamSpawn); weak declared type: union; untyped literal/static expression; unknown spawn; sta ...; evidence 4
  - [src/mir/lowering/expressions.rb:666](../../src/mir/lowering/expressions.rb#L666) `MIRLoweringExpressions#union_variant_key` return; T.nilable(T.any(String, Symbol)); weak declared type: union; untyped struct/array/collection value; static field; static field_s; static field_sym; evidence 4
  - [src/mir/lowering/functions.rb:254](../../src/mir/lowering/functions.rb#L254) `MIRLoweringFunctions#lower_extern_struct` return; T.any(MIR::Node, T::Array[MIR::Node]); weak declared type: union; untyped forwarded return; call_untyped T.must(items.first); unknown items; static MIR::Noop ...; evidence 4
  - [src/annotator/domains/lifetimes.rb:1051](../../src/annotator/domains/lifetimes.rb#L1051) `Annotator::Domains::Lifetimes#get_lifetime_paths` return; T::Array[T.any(String, Symbol)]; weak declared type: union; untyped forwarded return; static []; static [:wildcard]; call_untyped sources.map { ...; evidence 3
  - [src/mir/lowering/capabilities.rb:579](../../src/mir/lowering/capabilities.rb#L579) `MIRLoweringCapabilities#lower_with_block` return; T.any(MIR::BlockExpr, MIR::ScopeBlock); weak declared type: union; untyped literal/static expression; typed_call lower_with_match_block(node); typed_call  ...; evidence 3
- candidate: runtime-only return observation: 32 slot(s); weak 0, untyped 32; evidence 103
  - [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) `IntrinsicRegistry#to_return_def` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; typed_call_inferred FunctionReturn.fixed(Type.new(:Void)); typed_c ...; evidence 7
  - [src/mir/mir_emitter.rb:1469](../../src/mir/mir_emitter.rb#L1469) `MIREmitter#reassign_success_only_expr` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; nil nil; nil nil; candidate action fix_sig_return (review); evidence 7
  - [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) `IntrinsicRegistry#fs` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; unknown x; typed_call convert_entry(name, x, registries); candidate  ...; evidence 6
  - [src/mir/mir_lowering.rb:2650](../../src/mir/mir_lowering.rb#L2650) `MIRLowering#root_receiver_node` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil nil; unknown root; call_untyped root_receiver_node(node.target); candidate action fix_sig_r ...; evidence 6
  - [src/annotator/helpers/intrinsic_registry.rb:61](../../src/annotator/helpers/intrinsic_registry.rb#L61) `IntrinsicRegistry#nested_emit` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; static IntrinsicEmit.new(registry: name || :unknown); static ...; evidence 5
  - [src/ast/source_error.rb:122](../../src/ast/source_error.rb#L122) `ErrorHelper#fixable!` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil return; call_untyped $stderr.puts "#{tag} #{message}#{loc}"; typed_call raise err_class.new(token, mes ...; evidence 5
  - [src/annotator/helpers/fixable_helpers.rb:947](../../src/annotator/helpers/fixable_helpers.rb#L947) `FixableHelper#emit_with_read_needs_write_lock!` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; typed_call_inferred error!(node, :WITH_READ_NEEDS_WRITE_LOCK, n ...; evidence 4
  - [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) `IntrinsicRegistry#normalize_lifetime` return; `T.untyped`; single observed type; narrow candidate; untyped struct/array/collection value; static []; unknown value; static [value]; candidate actio ...; evidence 4
- weak declared type: hash key/value evidence needed: 32 slot(s); weak 32, untyped 0; evidence 80
  - [src/lsp/hover.rb:31](../../src/lsp/hover.rb#L31) `LSP::Hover#render` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; nil nil; nil nil; nil nil; candidate action narrow_generic_re ...; evidence 6
  - [src/annotator/helpers/method_analysis.rb:169](../../src/annotator/helpers/method_analysis.rb#L169) `MethodAnalysis#resolve_index_op` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped forwarded return; nil nil; call_untyped `INDEX_OPS.dig` ...; evidence 4
  - [src/ast/parser.rb:1589](../../src/ast/parser.rb#L1589) `Parser#parse_requires_family_or_reentrance` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped forwarded return; static { family: T.must(tok).value.to_sym }; s ...; evidence 4
  - [src/ast/parser.rb:3090](../../src/ast/parser.rb#L3090) `Parser#parse_element_capability` return; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; static result; static result; static result; candidate act ...; evidence 4
  - [src/lsp/rpc.rb:32](../../src/lsp/rpc.rb#L32) `LSP::RPC#read_message` return; T.nilable(T::Hash[String, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped forwarded return; nil nil; call_untyped JSON.parse(body); evidence 4
  - [src/annotator/helpers/effects.rb:631](../../src/annotator/helpers/effects.rb#L631) `EffectTracker#enforce_fallible_returns!` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped forwarded return; nil return; call_untyped fn_nodes.e ...; evidence 3
  - [src/ast/diagnostic_registry.rb:2783](../../src/ast/diagnostic_registry.rb#L2783) `DiagnosticRegistry#lookup` return; T.nilable(T::Hash[Symbol, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped forwarded return; call_untyped DIAGNOSTICS[code]; evidence 3
  - [src/lsp/position.rb:47](../../src/lsp/position.rb#L47) `LSP::Position#range_for_span` return; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; static { start: { line: start_line, character: byte_to_utf16( ...; evidence 3
- blocked: runtime union policy: 29 slot(s); weak 0, untyped 29; evidence 324
  - [src/mir/mir_lowering.rb:1862](../../src/mir/mir_lowering.rb#L1862) `MIRLowering#ownership_contract_source_node` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static current; evidence 118
  - [src/mir/mir_checker.rb:1371](../../src/mir/mir_checker.rb#L1371) `MIRChecker#ownership_source_expr` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static current; evidence 30
  - [src/ast/parser.rb:2943](../../src/ast/parser.rb#L2943) `Parser#parse_concurrent_inner_op` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static AST::SelectOp.new(previous, expr); static AST::WhereOp.new(previous, expr); typed_ ...; evidence 17
  - [src/mir/lowering/expressions.rb:223](../../src/mir/lowering/expressions.rb#L223) `MIRLoweringExpressions#lower_identifier` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::FnRef.new(zig_safe_name(node.name)); static `MIR::Ident.ne` ...; evidence 13
  - [src/ast/parser.rb:991](../../src/ast/parser.rb#L991) `Parser#parse_visibility_decl` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; typed_call parse_function_def(visibility); typed_call parse_function_def(visibility, is_method ...; evidence 10
  - [src/mir/test_lowering.rb:325](../../src/mir/test_lowering.rb#L325) `TestLowering#stub_intercept_for` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; nil nil; static MIR::Ident.new(stub_info[:var]); static MIR::BlockExpr.new(label, su ...; evidence 10
  - [src/mir/lowering/expressions.rb:183](../../src/mir/lowering/expressions.rb#L183) `MIRLoweringExpressions#lower_literal` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::Lit.new("\"#{escaped}\""); static MIR::Lit.new(node.value.to ...; evidence 9
  - [src/mir/lowering/expressions.rb:683](../../src/mir/lowering/expressions.rb#L683) `MIRLoweringExpressions#lower_smooth` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; typed_call lower_complex_smooth(node); typed_call lower_collect_smooth(no ...; evidence 9
- blocked: unknown return expression: 26 slot(s); weak 0, untyped 26; evidence 438
  - [src/mir/mir_lowering.rb:877](../../src/mir/mir_lowering.rb#L877) `MIRLowering#lower` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown mir; typed_call apply_lowered_coercion(mir, node); evidence 79
  - [src/ast/parser.rb:1759](../../src/ast/parser.rb#L1759) `Parser#parse_expression` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown lhs; evidence 61
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown init; unknown init; unknown init; evidence 43
  - [src/semantic/escape_analysis.rb:592](../../src/semantic/escape_analysis.rb#L592) `EscapeAnalysis#unwrap_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown current; evidence 36
  - [src/mir/hoist.rb:602](../../src/mir/hoist.rb#L602) `MIRHoistLowering#hoist_alloc` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown expr; unknown expr; static MIR::Ident.new(plan.name); evidence 27
  - [src/mir/lowering/control_flow.rb:952](../../src/mir/lowering/control_flow.rb#L952) `MIRLoweringControlFlow#heap_carry_recursive_param_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown value; unknown value; unknown value; evidence 26
  - [src/ast/parser.rb:1947](../../src/ast/parser.rb#L1947) `Parser#parse_suffixes` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown lhs; evidence 19
  - [src/backends/pipeline_rewriter.rb:786](../../src/backends/pipeline_rewriter.rb#L786) `PipelineRewriter#replace_placeholder` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown node; typed_call replacement.dup; unknown new_node; evidence 13
- candidate: void return: 6 slot(s); weak 0, untyped 6; evidence 36
  - [src/mir/control_flow.rb:1319](../../src/mir/control_flow.rb#L1319) `UseAfterMoveChecker#check_stmt_reads` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped check_reads_in_expr(stmt.value, state); call_untyped check_reads_in_exp ...; evidence 13
  - [src/ast/ast.rb:776](../../src/ast/ast.rb#L776) `AST#each_bg_block_in_stmt` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; unknown yield stmt; typed_call _expr_each_bg_block_shallow(stmt.value, &block); nil implicit else; candid ...; evidence 9
  - [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped blk.call; candidate action fix_sig_return (review); evidence 5
  - [src/ast/scope.rb:375](../../src/ast/scope.rb#L375) `Scope#mark_read` return; `T.untyped`; void candidate; return value appears unused; untyped literal/static expression; nil return; typed_call_inferred entry.mark_read!; candidate action fix_sig_return (review); evidence 4
  - [src/annotator/annotator.rb:698](../../src/annotator/annotator.rb#L698) `SemanticAnnotator#visit_Program` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped finalize_program_semantics!(node); candidate action fix_sig_return (review ...; evidence 3
  - [src/mir/cleanup_classifier.rb:724](../../src/mir/cleanup_classifier.rb#L724) `CleanupClassifier#each_capture_binding` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped AST.walk_body(body) do |node| case node when AST::WhileBindLoop  ...; evidence 2
- blocked: collection/field return evidence: 5 slot(s); weak 0, untyped 5; evidence 39
  - [src/mir/control_flow.rb:952](../../src/mir/control_flow.rb#L952) `OwnershipDataflow#transfer_stmt` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call update_declared_owner!(state, stmt.name.to_s, stmt); typed_call update ...; evidence 15
  - [src/mir/mir_lowering.rb:2806](../../src/mir/mir_lowering.rb#L2806) `MIRLowering#lower_union_def` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call helper_structs + [generic_fn]; unknown generic_fn; typed_call helper_stru ...; evidence 7
  - [src/mir/test_lowering.rb:393](../../src/mir/test_lowering.rb#L393) `TestLowering#lower_stub_decl` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static MIR::Let.new(stub_var, val, false, nil, nil); static MIR::Let.new(cap_name,  ...; evidence 7
  - [src/annotator/helpers/generic_analysis.rb:338](../../src/annotator/helpers/generic_analysis.rb#L338) `GenericAnalysis#extract_type_bindings!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; unknown subst[p_res] = actual_binding; typed_call param_ ...; evidence 6
  - [src/mir/lowering/control_flow.rb:970](../../src/mir/lowering/control_flow.rb#L970) `MIRLoweringControlFlow#return_with_transfer_marks` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static ret; typed_call marks + [ret]; candidate action ...; evidence 4
- weak declared type: nested `T.untyped`: 3 slot(s); weak 3, untyped 0; evidence 15
  - [src/mir/hoist.rb:976](../../src/mir/hoist.rb#L976) `MIRHoistLowering#normalize_allocating_used_expr` return; [T::Array[`T.untyped`], `T.untyped`]; weak declared type: nested `T.untyped`; untyped struct/array/collection value; static [prefix, expr]; static [prefix, expr]; static ...; evidence 8
  - [src/mir/mir_lowering.rb:1292](../../src/mir/mir_lowering.rb#L1292) `MIRLowering#materialize_statement_discard` return; [`T.untyped`, T::Boolean]; weak declared type: nested `T.untyped`; untyped struct/array/collection value; static [mir, false]; static [mir, false]; static [mir, fals ...; evidence 5
  - [src/mir/hoist.rb:724](../../src/mir/hoist.rb#L724) `MIRHoistLowering#hoist_normalized_alloc_expr` return; [T::Array[`T.untyped`], MIR::Ident]; weak declared type: nested `T.untyped`; untyped struct/array/collection value; static [plan.statements, MIR::Ident.new(plan.name)]; evidence 2
- ... and 3 more (run with `--full` to see all)

### Return Hygiene
- control shape: whether the method return is branchless or depends on branching control flow
- return syntax: whether the method uses implicit return, explicit `return`, or a mix
- return value usage: whether static callsites use this method's return value, forward it, or ignore it
- return source kind: the kind of expression that produces the return value
- fixability: the report's estimate of whether the return is already addressed, directly fixable, cascading, or needs more evidence
- row percent: share of all return slots; strength percents: share within that row
- Return slots indexed: 5234
- Return slot strength: strong 4909 (93.8%); weak 152 (2.9%); untyped 173 (3.3%); nilable 834 (15.9%)

#### Control Shape

- branchless: total 3255 (62.2%) of all returns; strong 3143 (96.6%); weak 67 (2.1%); untyped 45 (1.4%); nilable 340 (10.4%) within row
- branching: total 1979 (37.8%) of all returns; strong 1766 (89.2%); weak 85 (4.3%); untyped 128 (6.5%); nilable 494 (25.0%) within row

#### Return Syntax

- implicit: total 3830 (73.2%) of all returns; strong 3649 (95.3%); weak 100 (2.6%); untyped 81 (2.1%); nilable 435 (11.4%) within row
- mixed: total 1398 (26.7%) of all returns; strong 1257 (89.9%); weak 52 (3.7%); untyped 89 (6.4%); nilable 397 (28.4%) within row
- explicit: total 6 (0.1%) of all returns; strong 3 (50.0%); weak 0 (0.0%); untyped 3 (50.0%); nilable 2 (33.3%) within row

#### Return Value Usage

- used as value: total 3127 (59.7%) of all returns; strong 2878 (92.0%); weak 92 (2.9%); untyped 157 (5.0%); nilable 553 (17.7%) within row
- ambiguous method name: total 1017 (19.4%) of all returns; strong 977 (96.1%); weak 31 (3.0%); untyped 9 (0.9%); nilable 111 (10.9%) within row
- declared void: total 710 (13.6%) of all returns; strong 710 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- no static callsites found: total 183 (3.5%) of all returns; strong 178 (97.3%); weak 3 (1.6%); untyped 2 (1.1%); nilable 60 (32.8%) within row
- unused statement-only: total 183 (3.5%) of all returns; strong 153 (83.6%); weak 26 (14.2%); untyped 4 (2.2%); nilable 108 (59.0%) within row
- unused via return-forwarding: total 10 (0.2%) of all returns; strong 9 (90.0%); weak 0 (0.0%); untyped 1 (10.0%); nilable 2 (20.0%) within row
- declared noreturn: total 4 (0.1%) of all returns; strong 4 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row

#### Return Source Kind

- collection lookup: total 1432 (27.4%) of all returns; strong 1289 (90.0%); weak 95 (6.6%); untyped 48 (3.4%); nilable 179 (12.5%) within row
- literal/static: total 1346 (25.7%) of all returns; strong 1314 (97.6%); weak 17 (1.3%); untyped 15 (1.1%); nilable 217 (16.1%) within row
- implicit/direct forwarded return: total 785 (15.0%) of all returns; strong 730 (93.0%); weak 19 (2.4%); untyped 36 (4.6%); nilable 148 (18.9%) within row
- Ruby stdlib call: total 557 (10.6%) of all returns; strong 554 (99.5%); weak 0 (0.0%); untyped 3 (0.5%); nilable 50 (9.0%) within row
- unknown source: total 496 (9.5%) of all returns; strong 476 (96.0%); weak 10 (2.0%); untyped 10 (2.0%); nilable 70 (14.1%) within row
- mixed sources: total 314 (6.0%) of all returns; strong 296 (94.3%); weak 2 (0.6%); untyped 16 (5.1%); nilable 84 (26.8%) within row
- mixed/direct forwarded return: total 250 (4.8%) of all returns; strong 199 (79.6%); weak 9 (3.6%); untyped 42 (16.8%); nilable 76 (30.4%) within row
- mutation/setter assignment: total 49 (0.9%) of all returns; strong 49 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 10 (20.4%) within row
- explicit/direct forwarded return: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row
- struct/class field or instance variable: total 2 (0.0%) of all returns; strong 2 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row

#### Fixability

- addressed: strong: total 4195 (80.1%) of all returns; strong 4195 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 778 (18.5%) within row
- addressed: void: total 710 (13.6%) of all returns; strong 710 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- addressed: weak: total 152 (2.9%) of all returns; strong 0 (0.0%); weak 152 (100.0%); untyped 0 (0.0%); nilable 56 (36.8%) within row
- cascade: forwarded return: total 43 (0.8%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 43 (100.0%); nilable 0 (0.0%) within row
- review action: void from runtime_void: total 19 (0.4%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 19 (100.0%); nilable 0 (0.0%) within row
- manual review: total 11 (0.2%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 11 (100.0%); nilable 0 (0.0%) within row
- needs collection/field evidence: total 8 (0.2%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 8 (100.0%); nilable 0 (0.0%) within row
- review action: Array from review: total 7 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 7 (100.0%); nilable 0 (0.0%) within row
- addressed: noreturn: total 4 (0.1%) of all returns; strong 4 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- review action: T.nilable(FunctionSignature) from review: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row
- ... and 72 more (run with `--full` to see all)

#### Top Return Hygiene Actions

- [src/annotator/annotator.rb:673](../../src/annotator/annotator.rb#L673) `SemanticAnnotator#visit`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return
- [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`: cascade: forwarded return; used as value; mixed/direct forwarded return
- [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return
- [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`: cascade: forwarded return; used as value; mixed/direct forwarded return
- [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`: cascade: forwarded return; used as value; mixed/direct forwarded return
- [src/ast/parser.rb:522](../../src/ast/parser.rb#L522) `Parser#run_action`: cascade: forwarded return; used as value; explicit/direct forwarded return
- [src/ast/parser.rb:711](../../src/ast/parser.rb#L711) `Parser#parse_statement`: cascade: forwarded return; used as value; mixed/direct forwarded return
- [src/ast/parser.rb:991](../../src/ast/parser.rb#L991) `Parser#parse_visibility_decl`: cascade: forwarded return; used as value; implicit/direct forwarded return
- [src/ast/parser.rb:1838](../../src/ast/parser.rb#L1838) `Parser#parse_or_rescue`: cascade: forwarded return; used as value; implicit/direct forwarded return
- [src/ast/parser.rb:1962](../../src/ast/parser.rb#L1962) `Parser#parse_var_id`: cascade: forwarded return; used as value; explicit/direct forwarded return
- ... and 10 more (run with `--full` to see all)


## Review Actions (1634)

### Nil Source Fixes (149)
- [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209): affects 2 of 149 nil source fixes; source calls 1815
  - [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) tight; candidate T::Boolean; top source [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209); source calls 1037
  - [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) mark_per_iter; candidate T::Boolean; top source [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209); source calls 778
- [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91): affects 2 of 149 nil source fixes; source calls 11
  - [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91) entry; candidate Hash; auto-default {}; top source [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91); source calls 6
  - [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91) example; candidate Hash; auto-default {}; top source [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91); source calls 5
- [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462): affects 1 of 149 nil source fix; source calls 1025642
  - [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462) reg; top source [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462); source calls 1025642
- [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215): affects 1 of 149 nil source fix; source calls 80341
  - [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) node; top source [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215); source calls 80341
- [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148): affects 1 of 149 nil source fix; source calls 70102
  - [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) value; candidate String; auto-default ""; top source [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148); source calls 70102
- [src/tools/lint_fix_rewriter.rb:213](../../src/tools/lint_fix_rewriter.rb#L213): affects 1 of 149 nil source fix; source calls 42944
  - [src/tools/lint_fix_rewriter.rb:213](../../src/tools/lint_fix_rewriter.rb#L213) n; top source [src/tools/lint_fix_rewriter.rb:213](../../src/tools/lint_fix_rewriter.rb#L213); source calls 42944
- [src/ast/parser.rb:70](../../src/ast/parser.rb#L70): affects 1 of 149 nil source fix; source calls 39732
  - [src/ast/parser.rb:70](../../src/ast/parser.rb#L70) pattern; candidate Array; auto-default []; top source [src/ast/parser.rb:70](../../src/ast/parser.rb#L70); source calls 39732
- [src/ast/parser.rb:54](../../src/ast/parser.rb#L54): affects 1 of 149 nil source fix; source calls 38528
  - [src/ast/parser.rb:54](../../src/ast/parser.rb#L54) pattern; candidate Array; auto-default []; top source [src/ast/parser.rb:54](../../src/ast/parser.rb#L54); source calls 38528
- [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577): affects 1 of 149 nil source fix; source calls 37940
  - [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) value; top source [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577); source calls 37940
- [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589): affects 1 of 149 nil source fix; source calls 37940
  - [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) value; top source [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589); source calls 37940
- ... and 11 more (run with `--full` to see all)

### Union / `T.any` Candidates (419)
- [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033): affects 3 of 419 union candidates; source calls 0
  - [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) new_child; observed MIR::AddressOf, MIR::AllocatorRef, MIR::ArrayInit, MIR::BinOp, MIR::BlockExpr, MIR::Call, MIR::CapabilityLockAddress, MIR::CapabilityLockTarget, ...; no source callsite
  - [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) old_child; observed MIR::AddressOf, MIR::AllocatorRef, MIR::ArrayInit, MIR::BinOp, MIR::BlockExpr, MIR::Call, MIR::CapabilityLockAddress, MIR::CapabilityLockTarget, ...; no source callsite
  - [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) parent; observed MIR::AddressOf, MIR::ArrayInit, MIR::AssertStmt, MIR::BgBlock, MIR::BinOp, MIR::Call, MIR::CapWrap, MIR::CapabilityLockAddress, ...; no source callsite
- [src/mir/lowering/variables.rb:1016](../../src/mir/lowering/variables.rb#L1016): affects 3 of 419 union candidates; source calls 0
  - [src/mir/lowering/variables.rb:1016](../../src/mir/lowering/variables.rb#L1016) idx; observed MIR::Call, MIR::ConcatStr, MIR::DeepCopy, MIR::Ident, MIR::Lit, MIR::RegistryCall; no source callsite
  - [src/mir/lowering/variables.rb:1016](../../src/mir/lowering/variables.rb#L1016) target; observed MIR::FieldGet, MIR::Ident; no source callsite
  - [src/mir/lowering/variables.rb:1016](../../src/mir/lowering/variables.rb#L1016) target_node; observed AST::GetField, AST::Identifier; no source callsite
- [src/mir/lowering/variables.rb:1077](../../src/mir/lowering/variables.rb#L1077): affects 3 of 419 union candidates; source calls 0
  - [src/mir/lowering/variables.rb:1077](../../src/mir/lowering/variables.rb#L1077) idx; observed MIR::FieldGet, MIR::Ident, MIR::Lit; no source callsite
  - [src/mir/lowering/variables.rb:1077](../../src/mir/lowering/variables.rb#L1077) target; observed MIR::Ident, MIR::IndexGet; no source callsite
  - [src/mir/lowering/variables.rb:1077](../../src/mir/lowering/variables.rb#L1077) target_node; observed AST::GetIndex, AST::Identifier; no source callsite
- [src/mir/mir_lowering.rb:3374](../../src/mir/mir_lowering.rb#L3374): affects 3 of 419 union candidates; source calls 0
  - [src/mir/mir_lowering.rb:3374](../../src/mir/mir_lowering.rb#L3374) catch_body; observed MIR::BlockExpr, MIR::BreakExpr, MIR::DefaultValue, MIR::Ident, MIR::Lit, MIR::ScopeBlock, MIR::UnaryOp; no source callsite
  - [src/mir/mir_lowering.rb:3374](../../src/mir/mir_lowering.rb#L3374) fallback; observed AST::Literal, MIR::BlockExpr, MIR::Lit, MIR::UnaryOp; no source callsite
  - [src/mir/mir_lowering.rb:3374](../../src/mir/mir_lowering.rb#L3374) left; observed MIR::Call, MIR::Ident, MIR::RegistryCall; no source callsite
- [src/tools/lint_fix_rewriter.rb:68](../../src/tools/lint_fix_rewriter.rb#L68): affects 2 of 419 union candidates; source calls 690244
  - [src/tools/lint_fix_rewriter.rb:68](../../src/tools/lint_fix_rewriter.rb#L68) in_bg; observed FalseClass, TrueClass; [src/tools/lint_fix_rewriter.rb:68](../../src/tools/lint_fix_rewriter.rb#L68); source calls 532420
  - [src/tools/lint_fix_rewriter.rb:68](../../src/tools/lint_fix_rewriter.rb#L68) node; observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BatchWindowOp, AST::BenchmarkStmt, AST::BgBlock, ...; [src/tools/lint_fix_rewriter.rb:68](../../src/tools/lint_fix_rewriter.rb#L68); source calls 157824
- [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226): affects 2 of 419 union candidates; source calls 31421
  - [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) name; observed String, Symbol; [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226); source calls 20072
  - [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) x; observed FunctionSignature, Hash; [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226); source calls 11349
- [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89): affects 2 of 419 union candidates; source calls 19172
  - [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) body; observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89); source calls 9586
  - [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) declared_return; observed Symbol, Type; [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89); source calls 9586
- [src/ast/type.rb:3549](../../src/ast/type.rb#L3549): affects 2 of 419 union candidates; source calls 17922
  - [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) source_type; observed Symbol, Type; [src/ast/type.rb:3549](../../src/ast/type.rb#L3549); source calls 9523
  - [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) target_type; observed Symbol, Type; [src/ast/type.rb:3549](../../src/ast/type.rb#L3549); source calls 8399
- [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209): affects 2 of 419 union candidates; source calls 1624
  - [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) tight; observed FalseClass, TrueClass; [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209); source calls 860
  - [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) mark_per_iter; observed FalseClass, TrueClass; [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209); source calls 764
- [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31): affects 2 of 419 union candidates; source calls 1098
  - [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) code_or_message; observed String, Symbol; [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31); source calls 1096
  - [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) node_or_token; observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, ...; [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31); source calls 2
- ... and 11 more (run with `--full` to see all)

### Missing Sigs Needing Manual Review (91)
- [src/ast/ast.rb:1655](../../src/ast/ast.rb#L1655) add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- [src/ast/ast.rb:1816](../../src/ast/ast.rb#L1816) add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- [src/ast/ast.rb:1831](../../src/ast/ast.rb#L1831) add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- [src/mir/lowering/functions.rb:451](../../src/mir/lowering/functions.rb#L451) add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- [src/mir/lowering/functions.rb:614](../../src/mir/lowering/functions.rb#L614) add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) add_sig: add missing sig
- [src/tools/atomic_escape_suggester.rb:25](../../src/tools/atomic_escape_suggester.rb#L25) add_sig: add missing sig
- [src/tools/atomic_escape_suggester.rb:53](../../src/tools/atomic_escape_suggester.rb#L53) add_sig: add missing sig
- [src/tools/atomic_migration_suggester.rb:57](../../src/tools/atomic_migration_suggester.rb#L57) add_sig: add missing sig
- [src/tools/atomic_migration_suggester.rb:64](../../src/tools/atomic_migration_suggester.rb#L64) add_sig: add missing sig
- ... and 11 more (run with `--full` to see all)

### Other Review Actions (975)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `AST::Param#name` as String (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `AST::Param#takes` as T.any(FalseClass, Lexer::Token, TrueClass) (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `BinaryOpResult#type` as Type (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `AST::MethodCall#name` as String (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `MIR::Call#callee` as String (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `MIR::Call#owned_return` as T.any(FalseClass, T::Boolean, TrueClass) (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `AST::StructLit#fields` as T.any(Array, Hash, T::Hash[`T.untyped`, `T.untyped`]) (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `AST::StructField#borrowed` as T::Boolean (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `MIR::MethodCall#args` as T.any(Array, T::Array[MIR::Node], T::Array[`T.untyped`]) (struct field RBI)
- [sorbet/rbi/ast-struct-fields.rb](../../sorbet/rbi/ast-struct-fields.rb)i:1 add_struct_field_sig: type `AST::Capability#capability` as Symbol (struct field RBI)
- ... and 11 more (run with `--full` to see all)

## High-Confidence Actions (0)
- none

## Gap Actions (0)
- none

## Untyped Slots
- bucket: runtime-observation state for the current `T.untyped` slot, such as unobserved, nil-only, single-type, or runtime union
- source category: static origin category explaining where the untyped value appears to come from
- unknown expression cause: parser/indexer reason the report could not classify the expression more precisely

### Param `T.untyped` Buckets
- runtime union; kept `T.untyped` by policy: 388
  - 3 slots: [src/mir/hoist.rb:1033](../../src/mir/hoist.rb#L1033) `MIRHoistLowering#replace_mir_expr_child!` parent; 163100 call(s); observed MIR::AddressOf, MIR::ArrayInit, MIR::AssertStmt, MIR::BgBlock, MIR::BinOp, MIR::Call, MIR::CapWrap, MIR::CapabilityLockAddress, ...; me ...
  - 3 slots: [src/mir/lowering/variables.rb:1016](../../src/mir/lowering/variables.rb#L1016) `MIRLoweringVariables#lower_map_indexed_assignment` target_node; 677 call(s); observed AST::GetField, AST::Identifier; direct protocol: none observed; analysis gaps: forwarded to extract_root_var_na ...
  - 3 slots: [src/mir/lowering/variables.rb:1077](../../src/mir/lowering/variables.rb#L1077) `MIRLoweringVariables#lower_template_indexed_assignment` target_node; 161 call(s); observed AST::GetIndex, AST::Identifier; direct protocol: none observed; analysis gaps: forwarded to extract_root_v ...
  - 3 slots: [src/mir/mir_lowering.rb:3374](../../src/mir/mir_lowering.rb#L3374) `MIRLowering#try_catch_with_provenance` left; 296 call(s); observed MIR::Call, MIR::Ident, MIR::RegistryCall; direct protocol: none observed; analysis gaps: forwarded to strip_try slot 0 at src/mir/mir_lo ...
  - 2 slots: [src/annotator/helpers/fixable_helpers.rb:1123](../../src/annotator/helpers/fixable_helpers.rb#L1123) `FixableHelper#emit_type_mismatch_assign_error!` node; 10 call(s); observed AST::Assignment, AST::BindExpr; medium direct protocol #value; other potential options, not exhaustive: AST, AS ...
  - 2 slots: [src/annotator/helpers/fixable_helpers.rb:1176](../../src/annotator/helpers/fixable_helpers.rb#L1176) `FixableHelper#build_cast_wrap_fix` value; 13 call(s); observed AST::FuncCall, AST::Identifier, AST::Literal, AST::PassStmt, AST::StructLit, NilClass; strong direct protocol #name, #token ...
  - 2 slots: [src/annotator/helpers/fixable_helpers.rb:66](../../src/annotator/helpers/fixable_helpers.rb#L66) `FixableHelper#closest_name` input; 122 call(s); observed String, Symbol; weak direct protocol #to_s
  - 2 slots: [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) `FunctionAnalysis#analyze_routine` body; 9651 call(s); observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; medium direct protocol #resolved_type; other potential options, not ex ...
- single observed type; narrow candidate: 184
  - 4 slots: [src/lsp/code_actions.rb:60](../../src/lsp/code_actions.rb#L60) `LSP::CodeActions#build_action` fix; 11 call(s); observed Fix
  - 3 slots: [src/ast/diagnostic_examples.rb:141](../../src/ast/diagnostic_examples.rb#L141) `DiagnosticExamples#find_block_end` lines; 7872 call(s); observed Array
  - 3 slots: [src/lsp/hover.rb:63](../../src/lsp/hover.rb#L63) `LSP::Hover#find_overlapping` result; 16 call(s); observed LSP::Analyzer::Result
  - 3 slots: [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91) `LSP::Hover#build_markdown` diag; 13 call(s); observed Hash
  - 2 slots: [src/annotator/helpers/fixable_helpers.rb:540](../../src/annotator/helpers/fixable_helpers.rb#L540) `FixableHelper#emit_overflow_suffix_fix!` node; 3 call(s); observed AST::Literal
  - 2 slots: [src/annotator/helpers/fixable_helpers.rb:947](../../src/annotator/helpers/fixable_helpers.rb#L947) `FixableHelper#emit_with_read_needs_write_lock!` name; 2 call(s); observed String
  - 2 slots: [src/annotator/helpers/generic_analysis.rb:434](../../src/annotator/helpers/generic_analysis.rb#L434) `GenericAnalysis#same_generic_binding?` left; 21 call(s); observed Type
  - 2 slots: [src/annotator/helpers/intrinsic_registry.rb:127](../../src/annotator/helpers/intrinsic_registry.rb#L127) `IntrinsicRegistry#convert_entry` h; 71109 call(s); observed Hash
- slot not observed: method was not hit: 29
  - 1 slot: [src/annotator/helpers/capabilities.rb:1076](../../src/annotator/helpers/capabilities.rb#L1076) `CapabilityHelper#with_fiber_capture_analysis` blk; 0 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/pipe_analysis.rb:144](../../src/annotator/helpers/pipe_analysis.rb#L144) `PipeAnalysis#lift_to_observable_if_terminal!` type_kwargs; 0 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/pipe_analysis.rb:163](../../src/annotator/helpers/pipe_analysis.rb#L163) `PipeAnalysis#mark_observable_terminal!` type_kwargs; 0 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:1068](../../src/ast/ast.rb#L1068) `AST::Locatable#finalize_storage!` schema_lookup; 0 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:117](../../src/ast/ast.rb#L117) `AST#initialize` kw; 0 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:1340](../../src/ast/ast.rb#L1340) `AST#initialize` args; 0 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:144](../../src/ast/ast.rb#L144) `AST#initialize` kw; 0 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:1502](../../src/ast/ast.rb#L1502) `AST#initialize` kw; 0 call(s); observed no observed runtime type
- slot not observed: source index did not model this param shape: 22
  - 1 slot: [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls` block; 1629 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls` block; 1468 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves` blk; 1061 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/capabilities.rb:41](../../src/annotator/helpers/capabilities.rb#L41) `Capabilities#validate!` error_handler; 19076 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:752](../../src/annotator/helpers/fixable_helpers.rb#L752) `FixableHelper#emit_match_partial_fix!` kwargs; 14 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/pipe_analysis.rb:1828](../../src/annotator/helpers/pipe_analysis.rb#L1828) `PipeAnalysis#with_soa_tracking` blk; 1396 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:719](../../src/ast/ast.rb#L719) `AST#each_bg_block` block; 38202 call(s); observed no observed runtime type
  - 1 slot: [src/ast/ast.rb:726](../../src/ast/ast.rb#L726) `AST#_bg_visit_recursive` block; 104451 call(s); observed no observed runtime type
- nil only observed: 6
  - 1 slot: [src/ast/ast.rb:1727](../../src/ast/ast.rb#L1727) `AST#params=` val; 1 call(s); observed NilClass
  - 1 slot: [src/ast/ast.rb:2274](../../src/ast/ast.rb#L2274) `AST#params=` val; 1 call(s); observed NilClass
  - 1 slot: [src/backends/transpiler.rb:153](../../src/backends/transpiler.rb#L153) `ZigTranspiler#main_stack_variant` override; 931 call(s); observed NilClass
  - 1 slot: [src/mir/control_flow.rb:1308](../../src/mir/control_flow.rb#L1308) `UseAfterMoveChecker#check` can_fail_fns; 12 call(s); observed NilClass
  - 1 slot: [src/mir/fsm_transform/segments.rb:171](../../src/mir/fsm_transform/segments.rb#L171) `FsmTransform::Segments#split` lowering; 3 call(s); observed NilClass
  - 1 slot: [src/mir/mir_checker.rb:347](../../src/mir/mir_checker.rb#L347) `MIRChecker#initialize` fn_name; 1909 call(s); observed NilClass
- boolean pair; T::Boolean candidate: 5
  - 2 slots: [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) `MIRLoweringControlFlow#prepend_loop_mark` mark_per_iter; 1997 call(s); observed FalseClass, NilClass, TrueClass
  - 1 slot: [src/ast/diagnostic_examples.rb:165](../../src/ast/diagnostic_examples.rb#L165) `DiagnosticExamples#extract_first_heredoc_in_it` expecting_raise; 3936 call(s); observed FalseClass, TrueClass
  - 1 slot: [src/ast/source_error.rb:122](../../src/ast/source_error.rb#L122) `ErrorHelper#fixable!` raise_in_collector; 1207 call(s); observed FalseClass, TrueClass
  - 1 slot: [src/mir/lowering/control_flow.rb:247](../../src/mir/lowering/control_flow.rb#L247) `MIRLoweringControlFlow#finalize_loop_frame_alloc_scopes!` mark_per_iter; 1997 call(s); observed FalseClass, NilClass, TrueClass

### Return `T.untyped` Buckets
- runtime union; kept `T.untyped` by policy: 115
  - 1 slot: [src/annotator/annotator.rb:673](../../src/annotator/annotator.rb#L673) `SemanticAnnotator#visit` return; 228694 call(s); observed Array, FunctionSignature, Hash, Integer, NilClass, Symbol, SymbolEntry, TrueClass, ...
  - 1 slot: [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls` return; 1629 call(s); observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST::Li ...
  - 1 slot: [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk` return; 817 call(s); observed AST::BindExpr, AST::HashLit, AST::Identifier, AST::ListLit, AST::Literal, AST::ReturnNode, AST::VarDecl, Array, ...
  - 1 slot: [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls` return; 1468 call(s); observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST: ...
  - 1 slot: [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops` return; 1359 call(s); observed AST::Assert, AST::Assignment, AST::BindExpr, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST::ListLit, ...
  - 1 slot: [src/annotator/helpers/generic_analysis.rb:338](../../src/annotator/helpers/generic_analysis.rb#L338) `GenericAnalysis#extract_type_bindings!` return; 104 call(s); observed Array, NilClass, Type
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:271](../../src/annotator/helpers/intrinsic_registry.rb#L271) `IntrinsicRegistry#sig` return; 22763 call(s); observed Array, FunctionSignature, NilClass
  - 1 slot: [src/ast/ast.rb:1021](../../src/ast/ast.rb#L1021) `AST::Locatable#coerced_type` return; 171885 call(s); observed FunctionSignature, NilClass, Symbol
- single observed type; narrow candidate: 32
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:947](../../src/annotator/helpers/fixable_helpers.rb#L947) `FixableHelper#emit_with_read_needs_write_lock!` return; 2 call(s); observed NilClass, Symbol
  - 1 slot: [src/annotator/helpers/function_analysis.rb:1299](../../src/annotator/helpers/function_analysis.rb#L1299) `FunctionAnalysis#find_matching_intrinsic` return; 8717 call(s); observed FunctionSignature, NilClass
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) `IntrinsicRegistry#to_return_def` return; 74071 call(s); observed FunctionReturn
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) `IntrinsicRegistry#normalize_lifetime` return; 72116 call(s); observed Array
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:156](../../src/annotator/helpers/intrinsic_registry.rb#L156) `IntrinsicRegistry#params_from_arg_spec` return; 71109 call(s); observed Array
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:197](../../src/annotator/helpers/intrinsic_registry.rb#L197) `IntrinsicRegistry#sigs` return; 22896 call(s); observed Hash
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:213](../../src/annotator/helpers/intrinsic_registry.rb#L213) `IntrinsicRegistry#registries` return; 70847 call(s); observed Hash
  - 1 slot: [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) `IntrinsicRegistry#fs` return; 21278 call(s); observed FunctionSignature, NilClass
- nil only observed: 14
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:1048](../../src/annotator/helpers/fixable_helpers.rb#L1048) `FixableHelper#emit_with_restrict_immutable_error!` return; 10 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:1473](../../src/annotator/helpers/fixable_helpers.rb#L1473) `FixableHelper#emit_auto_resolved_finding!` return; 22 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:1497](../../src/annotator/helpers/fixable_helpers.rb#L1497) `FixableHelper#emit_auto_shape_resolved_finding!` return; 9 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:1539](../../src/annotator/helpers/fixable_helpers.rb#L1539) `FixableHelper#emit_auto_ambiguity_finding!` return; 4 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:1571](../../src/annotator/helpers/fixable_helpers.rb#L1571) `FixableHelper#emit_auto_unresolved_finding!` return; 9 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:540](../../src/annotator/helpers/fixable_helpers.rb#L540) `FixableHelper#emit_overflow_suffix_fix!` return; 3 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:752](../../src/annotator/helpers/fixable_helpers.rb#L752) `FixableHelper#emit_match_partial_fix!` return; 14 call(s); observed NilClass
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:779](../../src/annotator/helpers/fixable_helpers.rb#L779) `FixableHelper#emit_return_borrowed_no_copy_error!` return; 8 call(s); observed NilClass
- void candidate; return value appears unused: 6
  - 1 slot: [src/annotator/annotator.rb:698](../../src/annotator/annotator.rb#L698) `SemanticAnnotator#visit_Program` return; 6355 call(s); observed Symbol, Type
  - 1 slot: [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves` return; 1061 call(s); observed NilClass, SymbolEntry, Type, TypePlacement
  - 1 slot: [src/ast/ast.rb:776](../../src/ast/ast.rb#L776) `AST#each_bg_block_in_stmt` return; 23538 call(s); observed Array, NilClass, Set, TrueClass
  - 1 slot: [src/ast/scope.rb:375](../../src/ast/scope.rb#L375) `Scope#mark_read` return; 45013 call(s); observed NilClass, TrueClass
  - 1 slot: [src/mir/cleanup_classifier.rb:724](../../src/mir/cleanup_classifier.rb#L724) `CleanupClassifier#each_capture_binding` return; 4857 call(s); observed Array
  - 1 slot: [src/mir/control_flow.rb:1319](../../src/mir/control_flow.rb#L1319) `UseAfterMoveChecker#check_stmt_reads` return; 20138 call(s); observed Array, Hash, NilClass
- slot not observed: method hit but return was not captured: 6
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:1005](../../src/annotator/helpers/fixable_helpers.rb#L1005) `FixableHelper#emit_with_materialized_needs_tense!` return; 3 call(s); observed no observed runtime type
  - 1 slot: [src/annotator/helpers/fixable_helpers.rb:860](../../src/annotator/helpers/fixable_helpers.rb#L860) `FixableHelper#emit_with_guard_all_bindings_need_as!` return; 2 call(s); observed no observed runtime type
  - 1 slot: [src/ast/parser.rb:614](../../src/ast/parser.rb#L614) `Parser#emit_consume_error_with_fix` return; 97 call(s); observed no observed runtime type
  - 1 slot: [src/ast/parser.rb:633](../../src/ast/parser.rb#L633) `Parser#emit_syntax_insert_end_of_line!` return; 8 call(s); observed no observed runtime type
  - 1 slot: [src/ast/parser.rb:656](../../src/ast/parser.rb#L656) `Parser#emit_syntax_insert_before_token!` return; 2 call(s); observed no observed runtime type
  - 1 slot: [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) `ErrorHelper#error!` return; 1098 call(s); observed no observed runtime type

### Param `T.untyped` Source Categories
- untyped unknown expression: 408
  - [src/annotator/helpers/auto_inference.rb:68](../../src/annotator/helpers/auto_inference.rb#L68) `AutoSlotId#eql?` other; no static callsite origin
  - [src/annotator/helpers/auto_inference.rb:242](../../src/annotator/helpers/auto_inference.rb#L242) `AutoConstraintCollector#record_constraint` node; [src/annotator/helpers/auto_inference.rb:225](../../src/annotator/helpers/auto_inference.rb#L225) node
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls` block; no static callsite origin
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls` block; no static callsite origin
  - [src/annotator/helpers/capabilities.rb:41](../../src/annotator/helpers/capabilities.rb#L41) `Capabilities#validate!` node; [src/annotator/domains/variables.rb:179](../../src/annotator/domains/variables.rb#L179) node
  - [src/annotator/helpers/capabilities.rb:41](../../src/annotator/helpers/capabilities.rb#L41) `Capabilities#validate!` error_handler; no static callsite origin
  - [src/annotator/helpers/capabilities.rb:1076](../../src/annotator/helpers/capabilities.rb#L1076) `CapabilityHelper#with_fiber_capture_analysis` blk; no static callsite origin
  - [src/annotator/helpers/capabilities.rb:1107](../../src/annotator/helpers/capabilities.rb#L1107) `CapabilityHelper#record_capture_site!` node; [src/annotator/domains/lifetimes.rb:14](../../src/annotator/domains/lifetimes.rb#L14) node; [src/annotator/domains/lifetimes.rb:117](../../src/annotator/domains/lifetimes.rb#L117) node; [src/annotator/domains/lifetimes.rb:164](../../src/annotator/domains/lifetimes.rb#L164) node
- untyped forwarded return: 189
  - [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) `AutoConstraintCollector#walk` node; [src/annotator/helpers/auto_inference.rb:173](../../src/annotator/helpers/auto_inference.rb#L173) program_node; [src/annotator/helpers/auto_inference.rb:221](../../src/annotator/helpers/auto_inference.rb#L221) c; [src/annotator/helpers/auto_inference.rb:223](../../src/annotator/helpers/auto_inference.rb#L223) v
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls` node; [src/annotator/helpers/auto_inference.rb:730](../../src/annotator/helpers/auto_inference.rb#L730) fn.body; [src/annotator/helpers/auto_inference.rb:746](../../src/annotator/helpers/auto_inference.rb#L746) node.value; src/annotator/helpers/auto_inference. ...
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk` node; [src/annotator/helpers/auto_inference.rb:173](../../src/annotator/helpers/auto_inference.rb#L173) program_node; [src/annotator/helpers/auto_inference.rb:221](../../src/annotator/helpers/auto_inference.rb#L221) c; [src/annotator/helpers/auto_inference.rb:223](../../src/annotator/helpers/auto_inference.rb#L223) v
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls` node; [src/annotator/helpers/auto_inference.rb:887](../../src/annotator/helpers/auto_inference.rb#L887) fn.body; [src/annotator/helpers/auto_inference.rb:901](../../src/annotator/helpers/auto_inference.rb#L901) node.value; src/annotator/helpers/auto_inferen ...
  - [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops` node; [src/annotator/helpers/auto_inference.rb:874](../../src/annotator/helpers/auto_inference.rb#L874) fn.body; [src/annotator/helpers/auto_inference.rb:924](../../src/annotator/helpers/auto_inference.rb#L924) node.left; [src/annotator/helpers/auto_inference.rb:925](../../src/annotator/helpers/auto_inference.rb#L925)  ...
  - [src/annotator/helpers/capabilities.rb:1011](../../src/annotator/helpers/capabilities.rb#L1011) `CapabilityHelper#capability_alias_type` type; [src/annotator/helpers/capabilities.rb:919](../../src/annotator/helpers/capabilities.rb#L919) source_type; [src/annotator/helpers/capabilities.rb:934](../../src/annotator/helpers/capabilities.rb#L934) capability_source_type(fact); src/annotator/helpers/cap ...
  - [src/annotator/helpers/fixable_helpers.rb:108](../../src/annotator/helpers/fixable_helpers.rb#L108) `FixableHelper#emit_registry_mismatch!` name; [src/annotator/domains/errors.rb:223](../../src/annotator/domains/errors.rb#L223) item.name; [src/annotator/domains/errors.rb:233](../../src/annotator/domains/errors.rb#L233) item.name; [src/annotator/domains/execution_boundaries.rb:578](../../src/annotator/domains/execution_boundaries.rb#L578) name
  - [src/annotator/helpers/fixable_helpers.rb:146](../../src/annotator/helpers/fixable_helpers.rb#L146) `FixableHelper#emit_typo_suggestion!` token; [src/annotator/domains/control_flow.rb:215](../../src/annotator/domains/control_flow.rb#L215) name_tok; [src/annotator/domains/control_flow.rb:602](../../src/annotator/domains/control_flow.rb#L602) name_tok; [src/annotator/domains/member_access.rb:140](../../src/annotator/domains/member_access.rb#L140) node. ...
- untyped struct/array/collection value: 17
  - [src/annotator/helpers/fixable_helpers.rb:66](../../src/annotator/helpers/fixable_helpers.rb#L66) `FixableHelper#closest_name` candidates; [src/annotator/helpers/fixable_helpers.rb:110](../../src/annotator/helpers/fixable_helpers.rb#L110) candidates; [src/annotator/helpers/fixable_helpers.rb:149](../../src/annotator/helpers/fixable_helpers.rb#L149) candidates; [src/annotator/helpers/fixable_helpers.rb:21](../../src/annotator/helpers/fixable_helpers.rb#L21) ...
  - [src/annotator/helpers/intrinsic_registry.rb:271](../../src/annotator/helpers/intrinsic_registry.rb#L271) `IntrinsicRegistry#sig` reg; [src/annotator/helpers/intrinsic_registry.rb:239](../../src/annotator/helpers/intrinsic_registry.rb#L239) registry; [src/annotator/helpers/intrinsic_registry.rb:249](../../src/annotator/helpers/intrinsic_registry.rb#L249) MAP_METHODS; [src/annotator/helpers/intrinsic_registry.rb:25](../../src/annotator/helpers/intrinsic_registry.rb#L25) ...
  - [src/annotator/helpers/pipe_analysis.rb:1299](../../src/annotator/helpers/pipe_analysis.rb#L1299) `PipeAnalysis#each_shard_scan_node` node; [src/annotator/helpers/pipe_analysis.rb:1174](../../src/annotator/helpers/pipe_analysis.rb#L1174) node; [src/annotator/helpers/pipe_analysis.rb:1184](../../src/annotator/helpers/pipe_analysis.rb#L1184) node; [src/annotator/helpers/pipe_analysis.rb:1282](../../src/annotator/helpers/pipe_analysis.rb#L1282) nodes
  - [src/annotator/helpers/pipe_analysis.rb:1806](../../src/annotator/helpers/pipe_analysis.rb#L1806) `PipeAnalysis#check_soa_opportunity!` item_type; [src/annotator/helpers/pipe_analysis.rb:1833](../../src/annotator/helpers/pipe_analysis.rb#L1833) item_type
  - [src/annotator/helpers/pipe_analysis.rb:1828](../../src/annotator/helpers/pipe_analysis.rb#L1828) `PipeAnalysis#with_soa_tracking` item_type; [src/annotator/helpers/pipe_analysis.rb:323](../../src/annotator/helpers/pipe_analysis.rb#L323) item_type; [src/annotator/helpers/pipe_analysis.rb:854](../../src/annotator/helpers/pipe_analysis.rb#L854) item_type; [src/annotator/helpers/pipe_analysis.rb:1028](../../src/annotator/helpers/pipe_analysis.rb#L1028) it ...
  - [src/ast/diagnostic_examples.rb:86](../../src/ast/diagnostic_examples.rb#L86) `DiagnosticExamples#scan_file` out; [src/ast/diagnostic_examples.rb:78](../../src/ast/diagnostic_examples.rb#L78) out
  - [src/ast/diagnostic_examples.rb:141](../../src/ast/diagnostic_examples.rb#L141) `DiagnosticExamples#find_block_end` lines; [src/ast/diagnostic_examples.rb:101](../../src/ast/diagnostic_examples.rb#L101) lines; [src/ast/diagnostic_examples.rb:169](../../src/ast/diagnostic_examples.rb#L169) block_lines
  - [src/ast/diagnostic_examples.rb:165](../../src/ast/diagnostic_examples.rb#L165) `DiagnosticExamples#extract_first_heredoc_in_it` block_lines; [src/ast/diagnostic_examples.rb:105](../../src/ast/diagnostic_examples.rb#L105) block; [src/ast/diagnostic_examples.rb:107](../../src/ast/diagnostic_examples.rb#L107) block
- untyped literal/static expression: 16
  - [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) `FunctionAnalysis#analyze_routine` declared_return; [src/annotator/helpers/function_analysis.rb:168](../../src/annotator/helpers/function_analysis.rb#L168) :Any; [src/annotator/helpers/function_analysis.rb:221](../../src/annotator/helpers/function_analysis.rb#L221) declared_return
  - [src/ast/diagnostic_examples.rb:165](../../src/ast/diagnostic_examples.rb#L165) `DiagnosticExamples#extract_first_heredoc_in_it` expecting_raise; [src/ast/diagnostic_examples.rb:105](../../src/ast/diagnostic_examples.rb#L105) true; [src/ast/diagnostic_examples.rb:107](../../src/ast/diagnostic_examples.rb#L107) false
  - [src/ast/source_error.rb:31](../../src/ast/source_error.rb#L31) `ErrorHelper#error!` code_or_message; [src/annotator/annotator.rb:507](../../src/annotator/annotator.rb#L507) :WITH_SNAPSHOT_BODY_NOT_PURE; [src/annotator/domains/control_flow.rb:144](../../src/annotator/domains/control_flow.rb#L144) :IF_AS_NEEDS_OPTIONAL; [src/annotator/domains/control_flow.rb:202](../../src/annotator/domains/control_flow.rb#L202) :MATCH_NE ...
  - [src/ast/source_error.rb:122](../../src/ast/source_error.rb#L122) `ErrorHelper#fixable!` raise_in_collector; [src/annotator/domains/lifetimes.rb:691](../../src/annotator/domains/lifetimes.rb#L691) true; [src/annotator/domains/lifetimes.rb:759](../../src/annotator/domains/lifetimes.rb#L759) true; [src/annotator/domains/variables.rb:146](../../src/annotator/domains/variables.rb#L146) false
  - [src/backends/pipeline_rewriter.rb:294](../../src/backends/pipeline_rewriter.rb#L294) `PipelineRewriter#fuse_pipeline` terminal; [src/backends/pipeline_rewriter.rb:173](../../src/backends/pipeline_rewriter.rb#L173) terminal; [src/backends/pipeline_rewriter.rb:183](../../src/backends/pipeline_rewriter.rb#L183) nil
  - [src/lsp/code_actions.rb:105](../../src/lsp/code_actions.rb#L105) `LSP::CodeActions#range_position` side; [src/lsp/code_actions.rb:97](../../src/lsp/code_actions.rb#L97) :end; [src/lsp/code_actions.rb:97](../../src/lsp/code_actions.rb#L97) :start; [src/lsp/code_actions.rb:98](../../src/lsp/code_actions.rb#L98) :end
  - [src/lsp/document_store.rb:29](../../src/lsp/document_store.rb#L29) `LSP::DocumentStore#cached_findings=` value; [src/lsp/document_store.rb:55](../../src/lsp/document_store.rb#L55) nil; [src/lsp/server.rb:271](../../src/lsp/server.rb#L271) result
  - [src/lsp/hover.rb:31](../../src/lsp/hover.rb#L31) `LSP::Hover#render` document; [src/lsp/server.rb:258](../../src/lsp/server.rb#L258) doc; [src/mir/fsm_ops.rb:424](../../src/mir/fsm_ops.rb#L424) "__ctx_#{@ctx_id}"; [src/mir/mir_emitter.rb:285](../../src/mir/mir_emitter.rb#L285) plan
- untyped instance variable: 4
  - [src/ast/schemas.rb:233](../../src/ast/schemas.rb#L233) Schemas::InlineStructVariant#== other; [src/annotator/domains/control_flow.rb:78](../../src/annotator/domains/control_flow.rb#L78) :moved; [src/annotator/domains/control_flow.rb:243](../../src/annotator/domains/control_flow.rb#L243) :Int64; [src/annotator/domains/control_flow.rb:243](../../src/annotator/domains/control_flow.rb#L243) :Float64
  - [src/ast/type.rb:1369](../../src/ast/type.rb#L1369) Type#== other; [src/annotator/domains/control_flow.rb:78](../../src/annotator/domains/control_flow.rb#L78) :moved; [src/annotator/domains/control_flow.rb:243](../../src/annotator/domains/control_flow.rb#L243) :Int64; [src/annotator/domains/control_flow.rb:243](../../src/annotator/domains/control_flow.rb#L243) :Float64
  - [src/lsp/rpc.rb:32](../../src/lsp/rpc.rb#L32) `LSP::RPC#read_message` io; [src/lsp/server.rb:54](../../src/lsp/server.rb#L54) @stdin
  - [src/lsp/rpc.rb:53](../../src/lsp/rpc.rb#L53) `LSP::RPC#write_message` io; [src/lsp/server.rb:129](../../src/lsp/server.rb#L129) @stdout

### Return `T.untyped` Source Categories
- untyped forwarded return: 86
  - [src/annotator/annotator.rb:673](../../src/annotator/annotator.rb#L673) `SemanticAnnotator#visit`
  - [src/annotator/annotator.rb:698](../../src/annotator/annotator.rb#L698) `SemanticAnnotator#visit_Program`
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
  - [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`
  - [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves`
  - [src/annotator/helpers/fixable_helpers.rb:540](../../src/annotator/helpers/fixable_helpers.rb#L540) `FixableHelper#emit_overflow_suffix_fix!`
- untyped literal/static expression: 63
  - [src/annotator/helpers/intrinsic_registry.rb:61](../../src/annotator/helpers/intrinsic_registry.rb#L61) `IntrinsicRegistry#nested_emit`
  - [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) `IntrinsicRegistry#to_return_def`
  - [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) `IntrinsicRegistry#fs`
  - [src/ast/ast.rb:791](../../src/ast/ast.rb#L791) `AST#_expr_each_bg_block_shallow`
  - [src/ast/ast.rb:1021](../../src/ast/ast.rb#L1021) `AST::Locatable#coerced_type`
  - [src/ast/diagnostic_examples.rb:141](../../src/ast/diagnostic_examples.rb#L141) `DiagnosticExamples#find_block_end`
  - [src/ast/fixable_error.rb:140](../../src/ast/fixable_error.rb#L140) `FixCollector#disable!`
  - [src/ast/parser.rb:702](../../src/ast/parser.rb#L702) `Parser#match!`
- untyped unknown expression: 12
  - [src/annotator/helpers/function_analysis.rb:1299](../../src/annotator/helpers/function_analysis.rb#L1299) `FunctionAnalysis#find_matching_intrinsic`
  - [src/annotator/helpers/intrinsic_registry.rb:197](../../src/annotator/helpers/intrinsic_registry.rb#L197) `IntrinsicRegistry#sigs`
  - [src/annotator/helpers/intrinsic_registry.rb:213](../../src/annotator/helpers/intrinsic_registry.rb#L213) `IntrinsicRegistry#registries`
  - [src/ast/diagnostic_examples.rb:63](../../src/ast/diagnostic_examples.rb#L63) `DiagnosticExamples#all`
  - [src/ast/parser.rb:1759](../../src/ast/parser.rb#L1759) `Parser#parse_expression`
  - [src/ast/parser.rb:1947](../../src/ast/parser.rb#L1947) `Parser#parse_suffixes`
  - [src/backends/pipeline_rewriter.rb:759](../../src/backends/pipeline_rewriter.rb#L759) `PipelineRewriter#patch_chain_source!`
  - [src/lsp/diagnostics.rb:58](../../src/lsp/diagnostics.rb#L58) `LSP::Diagnostics#from_result`
- untyped struct/array/collection value: 12
  - [src/annotator/helpers/generic_analysis.rb:338](../../src/annotator/helpers/generic_analysis.rb#L338) `GenericAnalysis#extract_type_bindings!`
  - [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) `IntrinsicRegistry#normalize_lifetime`
  - [src/ast/ast.rb:1727](../../src/ast/ast.rb#L1727) `AST#params=`
  - [src/ast/ast.rb:2274](../../src/ast/ast.rb#L2274) `AST#params=`
  - [src/ast/parser.rb:3937](../../src/ast/parser.rb#L3937) `Parser#parse_comma_seq`
  - [src/lsp/code_actions.rb:105](../../src/lsp/code_actions.rb#L105) `LSP::CodeActions#range_position`
  - [src/mir/control_flow.rb:952](../../src/mir/control_flow.rb#L952) `OwnershipDataflow#transfer_stmt`
  - [src/mir/hoist.rb:469](../../src/mir/hoist.rb#L469) `MIRHoistLowering#lower_head`

### Param Unknown Expression Causes
- unknown operation unresolved constant Compiler::Entrypoint::NAME: 12
  - [src/annotator/domains/errors.rb:89](../../src/annotator/domains/errors.rb#L89) ==(0) Compiler::Entrypoint::NAME
  - [src/annotator/helpers/effects.rb:427](../../src/annotator/helpers/effects.rb#L427) ==(0) Compiler::Entrypoint::NAME
  - [src/annotator/helpers/effects.rb:491](../../src/annotator/helpers/effects.rb#L491) ==(0) Compiler::Entrypoint::NAME
  - [src/annotator/helpers/effects.rb:649](../../src/annotator/helpers/effects.rb#L649) ==(0) Compiler::Entrypoint::NAME
  - [src/annotator/phases/import_resolution.rb:36](../../src/annotator/phases/import_resolution.rb#L36) ==(0) Compiler::Entrypoint::NAME
  - [src/backends/transpiler.rb:209](../../src/backends/transpiler.rb#L209) ==(0) Compiler::Entrypoint::NAME
  - [src/mir/lowering/capabilities.rb:295](../../src/mir/lowering/capabilities.rb#L295) ==(0) Compiler::Entrypoint::NAME
  - [src/mir/mir_lowering.rb:2534](../../src/mir/mir_lowering.rb#L2534) ==(0) Compiler::Entrypoint::NAME
- unknown operation SelfNode: 5
  - [src/annotator/domains/member_access.rb:23](../../src/annotator/domains/member_access.rb#L23) resolve(2) self
  - [src/annotator/helpers/method_analysis.rb:90](../../src/annotator/helpers/method_analysis.rb#L90) resolve(2) self
  - [src/annotator/phases/expression_domains.rb:116](../../src/annotator/phases/expression_domains.rb#L116) resolve(2) self
  - [src/annotator/phases/expression_domains.rb:160](../../src/annotator/phases/expression_domains.rb#L160) resolve(2) self
  - [src/mir/lowering/concurrency.rb:532](../../src/mir/lowering/concurrency.rb#L532) transform(2) self
- unknown expression with multiple unknown types: 4
  - [src/annotator/helpers/lock_helper.rb:465](../../src/annotator/helpers/lock_helper.rb#L465) error!(0) anchor || semantic_program
  - [src/annotator/helpers/pipe_analysis.rb:1329](../../src/annotator/helpers/pipe_analysis.rb#L1329) sharded_unsynced_entry?(0) node.symbol || lookup_scope_for(node.name)&.resolve_entry(node.name)
  - [src/mir/lowering/variables.rb:1229](../../src/mir/lowering/variables.rb#L1229) placement_for_node(0) root_receiver_node(node.name) || node.name
  - [src/mir/lowering/variables.rb:1324](../../src/mir/lowering/variables.rb#L1324) placement_for_node(0) root_receiver_node(node.name) || node.name
- unknown operation unresolved constant STD_LIB: 3
  - [src/backends/pipeline_rewriter.rb:226](../../src/backends/pipeline_rewriter.rb#L226) sig(0) STD_LIB
  - [src/backends/pipeline_rewriter.rb:705](../../src/backends/pipeline_rewriter.rb#L705) sig(0) STD_LIB
  - [src/mir/lowering/functions.rb:1183](../../src/mir/lowering/functions.rb#L1183) sig(0) STD_LIB
- unknown operation unresolved constant HEAP_STRING_TYPE: 2
  - [src/ast/type.rb:703](../../src/ast/type.rb#L703) ==(0) HEAP_STRING_TYPE
  - [src/ast/type.rb:703](../../src/ast/type.rb#L703) ==(0) HEAP_STRING_TYPE
- unknown operation RegularExpressionNode: 2
  - [src/lsp/diagnostics.rb:161](../../src/lsp/diagnostics.rb#L161) split(0) /(%\{[^}]+\})/
  - [src/tools/doctor.rb:453](../../src/tools/doctor.rb#L453) split(0) /\t/
- unknown operation unresolved constant UNINIT: 2
  - [src/mir/control_flow.rb:890](../../src/mir/control_flow.rb#L890) ==(0) UNINIT
  - [src/mir/control_flow.rb:891](../../src/mir/control_flow.rb#L891) ==(0) UNINIT
- unknown operation unresolved constant Arc: 2
  - [src/mir/fiber_ctx_builder.rb:84](../../src/mir/fiber_ctx_builder.rb#L84) ==(0) Arc
  - [src/mir/fiber_ctx_builder.rb:89](../../src/mir/fiber_ctx_builder.rb#L89) ==(0) Arc
- unknown operation unresolved constant CaptureCleanupKind::CapturedValue: 2
  - [src/mir/fiber_ctx_builder.rb:118](../../src/mir/fiber_ctx_builder.rb#L118) ==(0) CaptureCleanupKind::CapturedValue
  - [src/mir/fiber_ctx_builder.rb:153](../../src/mir/fiber_ctx_builder.rb#L153) ==(0) CaptureCleanupKind::CapturedValue
- unknown operation unresolved constant CaptureCleanupKind::UniformValue: 2
  - [src/mir/fiber_ctx_builder.rb:123](../../src/mir/fiber_ctx_builder.rb#L123) ==(0) CaptureCleanupKind::UniformValue
  - [src/mir/fiber_ctx_builder.rb:154](../../src/mir/fiber_ctx_builder.rb#L154) ==(0) CaptureCleanupKind::UniformValue
- ... and 30 more (run with `--full` to see all)

### Return Unknown Expression Causes
- unknown local variable value: 20
  - [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) `IntrinsicRegistry#normalize_lifetime` value
  - [src/mir/fsm_lowering.rb:183](../../src/mir/fsm_lowering.rb#L183) `FsmLowering#coerce_fsm_result_value` value
  - [src/mir/fsm_lowering.rb:183](../../src/mir/fsm_lowering.rb#L183) `FsmLowering#coerce_fsm_result_value` value
  - [src/mir/lowering/control_flow.rb:921](../../src/mir/lowering/control_flow.rb#L921) `MIRLoweringControlFlow#return_payload_pointer_value` value
  - [src/mir/lowering/control_flow.rb:921](../../src/mir/lowering/control_flow.rb#L921) `MIRLoweringControlFlow#return_payload_pointer_value` value
  - [src/mir/lowering/control_flow.rb:921](../../src/mir/lowering/control_flow.rb#L921) `MIRLoweringControlFlow#return_payload_pointer_value` value
  - [src/mir/lowering/control_flow.rb:921](../../src/mir/lowering/control_flow.rb#L921) `MIRLoweringControlFlow#return_payload_pointer_value` value
  - [src/mir/lowering/control_flow.rb:939](../../src/mir/lowering/control_flow.rb#L939) `MIRLoweringControlFlow#heap_carry_return_value` value
- unknown local variable result: 8
  - [src/annotator/annotator.rb:673](../../src/annotator/annotator.rb#L673) `SemanticAnnotator#visit` result
  - [src/annotator/helpers/intrinsic_registry.rb:271](../../src/annotator/helpers/intrinsic_registry.rb#L271) `IntrinsicRegistry#sig` result
  - [src/ast/parser.rb:711](../../src/ast/parser.rb#L711) `Parser#parse_statement` result
  - [src/ast/parser.rb:3870](../../src/ast/parser.rb#L3870) `Parser#parse_bg_body_stmt` result
  - [src/mir/hoist.rb:433](../../src/mir/hoist.rb#L433) `MIRHoistLowering#lower_scoped` result
  - [src/mir/lowering/control_flow.rb:548](../../src/mir/lowering/control_flow.rb#L548) `MIRLoweringControlFlow#lower_match` result
  - [src/mir/lowering/variables.rb:708](../../src/mir/lowering/variables.rb#L708) `MIRLoweringVariables#lower_bind_expr` result
  - [src/mir/lowering/variables.rb:708](../../src/mir/lowering/variables.rb#L708) `MIRLoweringVariables#lower_bind_expr` result
- unknown local variable expr: 6
  - [src/ast/parser.rb:711](../../src/ast/parser.rb#L711) `Parser#parse_statement` expr
  - [src/ast/parser.rb:3870](../../src/ast/parser.rb#L3870) `Parser#parse_bg_body_stmt` expr
  - [src/mir/hoist.rb:602](../../src/mir/hoist.rb#L602) `MIRHoistLowering#hoist_alloc` expr
  - [src/mir/hoist.rb:602](../../src/mir/hoist.rb#L602) `MIRHoistLowering#hoist_alloc` expr
  - [src/mir/mir_pass.rb:378](../../src/mir/mir_pass.rb#L378) `MIRPass#unwrap_return_expr` expr
  - [src/mir/mir_pass.rb:378](../../src/mir/mir_pass.rb#L378) `MIRPass#unwrap_return_expr` expr
- unknown local variable left: 6
  - [src/mir/lowering/expressions.rb:865](../../src/mir/lowering/expressions.rb#L865) `MIRLoweringExpressions#lower_or_rescue` left
  - [src/mir/lowering/expressions.rb:865](../../src/mir/lowering/expressions.rb#L865) `MIRLoweringExpressions#lower_or_rescue` left
  - [src/mir/lowering/expressions.rb:865](../../src/mir/lowering/expressions.rb#L865) `MIRLoweringExpressions#lower_or_rescue` left
  - [src/mir/lowering/expressions.rb:865](../../src/mir/lowering/expressions.rb#L865) `MIRLoweringExpressions#lower_or_rescue` left
  - [src/mir/lowering/expressions.rb:865](../../src/mir/lowering/expressions.rb#L865) `MIRLoweringExpressions#lower_or_rescue` left
  - [src/mir/lowering/expressions.rb:865](../../src/mir/lowering/expressions.rb#L865) `MIRLoweringExpressions#lower_or_rescue` left
- unknown local variable mir: 6
  - [src/mir/lowering/functions.rb:1876](../../src/mir/lowering/functions.rb#L1876) `MIRLoweringFunctions#lower_extern_arg` mir
  - [src/mir/mir_lowering.rb:764](../../src/mir/mir_lowering.rb#L764) `MIRLowering#place_owned_branch_value_for_destination` mir
  - [src/mir/mir_lowering.rb:877](../../src/mir/mir_lowering.rb#L877) `MIRLowering#lower` mir
  - [src/mir/mir_lowering.rb:1319](../../src/mir/mir_lowering.rb#L1319) `MIRLowering#place_discarded_owned_branch_value` mir
  - [src/mir/mir_lowering.rb:1319](../../src/mir/mir_lowering.rb#L1319) `MIRLowering#place_discarded_owned_branch_value` mir
  - [src/mir/mir_lowering.rb:1319](../../src/mir/mir_lowering.rb#L1319) `MIRLowering#place_discarded_owned_branch_value` mir
- unknown local variable node: 4
  - [src/ast/parser.rb:2522](../../src/ast/parser.rb#L2522) `Parser#parse_lit` node
  - [src/backends/pipeline_rewriter.rb:768](../../src/backends/pipeline_rewriter.rb#L768) `PipelineRewriter#replace_named_placeholder` node
  - [src/backends/pipeline_rewriter.rb:786](../../src/backends/pipeline_rewriter.rb#L786) `PipelineRewriter#replace_placeholder` node
  - [src/mir/hoist.rb:480](../../src/mir/hoist.rb#L480) `MIRHoistLowering#with_pending` node
- unknown local variable init: 4
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
  - [src/mir/lowering/variables.rb:198](../../src/mir/lowering/variables.rb#L198) `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
- unknown local variable inner: 4
  - [src/mir/lowering/variables.rb:557](../../src/mir/lowering/variables.rb#L557) `MIRLoweringVariables#lower_var_decl_init` inner
  - [src/mir/lowering/variables.rb:557](../../src/mir/lowering/variables.rb#L557) `MIRLoweringVariables#lower_var_decl_init` inner
  - [src/mir/lowering/variables.rb:557](../../src/mir/lowering/variables.rb#L557) `MIRLoweringVariables#lower_var_decl_init` inner
  - [src/mir/lowering/variables.rb:557](../../src/mir/lowering/variables.rb#L557) `MIRLoweringVariables#lower_var_decl_init` inner
- unknown expression with multiple unknown types: 3
  - [src/annotator/helpers/function_analysis.rb:1299](../../src/annotator/helpers/function_analysis.rb#L1299) `FunctionAnalysis#find_matching_intrinsic` matched && IntrinsicRegistry.fs(matched)
  - [src/ast/ast.rb:838](../../src/ast/ast.rb#L838) `AST#_expr_each_concurrent_capture` yield node.capture_analysis
  - [src/mir/lowering/expressions.rb:954](../../src/mir/lowering/expressions.rb#L954) `MIRLoweringExpressions#or_fallback_expected_type` function_state.current_expected_type || node.full_type!(context: "OR fallback expected type")
- unknown local variable call: 3
  - [src/backends/pipeline_rewriter.rb:97](../../src/backends/pipeline_rewriter.rb#L97) `PipelineRewriter#rewrite_pipeline` call
  - [src/mir/lowering/concurrency.rb:1222](../../src/mir/lowering/concurrency.rb#L1222) `MIRLoweringConcurrency#lower_next_expr` call
  - [src/mir/lowering/concurrency.rb:1222](../../src/mir/lowering/concurrency.rb#L1222) `MIRLoweringConcurrency#lower_next_expr` call
- ... and 34 more (run with `--full` to see all)

## Nil origins
- [src/mir/lowering/expressions.rb:428](../../src/mir/lowering/expressions.rb#L428): 1

## Nilability Pressure By Root Callsite
- pressure: how many review actions are attributed to the same source location
- root callsite: the caller/source location where nil entered one or more typed slots
- [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462) priority 7.01; affects `T.nilable` in 1 signature slot(s), 1025642 observed call(s)
  - [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462) reg
- [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) priority 6.02; affects `T.nilable` in 2 signature slot(s), 1815 observed call(s)
  - [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) mark_per_iter (candidate T::Boolean)
  - [src/mir/lowering/control_flow.rb:209](../../src/mir/lowering/control_flow.rb#L209) tight (candidate T::Boolean)
- [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) priority 5.90; affects `T.nilable` in 1 signature slot(s), 80341 observed call(s)
  - [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) node
- [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) priority 5.85; affects `T.nilable` in 1 signature slot(s), 70102 observed call(s)
  - [src/annotator/helpers/intrinsic_registry.rb:148](../../src/annotator/helpers/intrinsic_registry.rb#L148) value (candidate String; default "")
- [src/tools/lint_fix_rewriter.rb:213](../../src/tools/lint_fix_rewriter.rb#L213) priority 5.63; affects `T.nilable` in 1 signature slot(s), 42944 observed call(s)
  - [src/tools/lint_fix_rewriter.rb:213](../../src/tools/lint_fix_rewriter.rb#L213) n
- [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) priority 5.58; affects `T.nilable` in 1 signature slot(s), 37940 observed call(s)
  - [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) value
- [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) priority 5.58; affects `T.nilable` in 1 signature slot(s), 37940 observed call(s)
  - [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) value
- [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) priority 5.56; affects `T.nilable` in 1 signature slot(s), 36065 observed call(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) node
- ... and 42 more (run with `--full` to see all)

## Union Pressure Downgraded To `T.untyped`
- downgrade: a slot observed with multiple runtime types was kept as `T.untyped` instead of emitted as `T.any(...)`
- why it happens: `T.any(...)` is risky when the runtime sample may not include every type that can reach the slot
Changing these to T.any(...) can be dangerous unless you are certain the runtime sample includes every type that can reach the slot. Static analysis can separately look for other types that could be passed without breaking the function.
- [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) priority 7.96; affects `T.any` in 2 signature slot(s), 42554 observed call(s)
  - [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) x (observed FunctionSignature, Hash)
  - [src/annotator/helpers/intrinsic_registry.rb:226](../../src/annotator/helpers/intrinsic_registry.rb#L226) name (observed String, Symbol)
- [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) priority 7.73; affects `T.any` in 2 signature slot(s), 29470 observed call(s)
  - [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) source_type (observed Symbol, Type)
  - [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) target_type (observed Symbol, Type)
- [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) priority 7.47; affects `T.any` in 2 signature slot(s), 19237 observed call(s)
  - [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) body (observed AST::BinaryOp, AST::Identifier, AST::Literal, Array)
  - [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) declared_return (observed Symbol, Type)
- [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) priority 7.15; affects `T.any` in 1 signature slot(s), 1413494 observed call(s)
  - [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- [src/ast/lexer.rb:294](../../src/ast/lexer.rb#L294) priority 7.06; affects `T.any` in 1 signature slot(s), 1145975 observed call(s)
  - [src/ast/lexer.rb:294](../../src/ast/lexer.rb#L294) val (observed Float, Integer, String)
- [src/mir/hoist.rb:246](../../src/mir/hoist.rb#L246) priority 6.98; affects `T.any` in 1 signature slot(s), 963074 observed call(s)
  - [src/mir/hoist.rb:246](../../src/mir/hoist.rb#L246) child (observed AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, ...)
- [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231) priority 6.97; affects `T.any` in 1 signature slot(s), 938439 observed call(s)
  - [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231) node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) priority 6.72; affects `T.any` in 1 signature slot(s), 529783 observed call(s)
  - [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) value (observed AST::BinaryOp, Array, FalseClass, FunctionSignature, Hash, ...)
- [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) priority 6.72; affects `T.any` in 1 signature slot(s), 529783 observed call(s)
  - [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) value (observed AST::BinaryOp, Array, FalseClass, FunctionSignature, Hash, ...)
- [src/annotator/helpers/function_signature.rb:144](../../src/annotator/helpers/function_signature.rb#L144) priority 6.22; affects `T.any` in 1 signature slot(s), 167578 observed call(s)
  - [src/annotator/helpers/function_signature.rb:144](../../src/annotator/helpers/function_signature.rb#L144) x (observed Array, FunctionSignature, Symbol, Type)
- ... and 40 more (run with `--full` to see all)

## `T.any` Downgrades By Signature
- signature downgrade: an individual param or return slot where union evidence exists but the report kept the current `T.untyped` signature
- [src/ast/lexer.rb:294](../../src/ast/lexer.rb#L294) val: observed Float, Integer, String; kept as `T.untyped`
- [src/ast/parser.rb:1947](../../src/ast/parser.rb#L1947) lhs: observed AST::BinaryOp, AST::CapabilityWrap, AST::CloneNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::ListLit, AST::Literal, AST::MethodCall, AST::NextExpr, AST::RangeLit, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- [src/ast/symbol_entry.rb:462](../../src/ast/symbol_entry.rb#L462) reg: observed AST::BindExpr, AST::Identifier, AST::LetBinding, AST::StubDecl, AST::VarDecl, OpenStruct, String, Symbol; kept as `T.untyped`
- [src/ast/ast.rb:396](../../src/ast/ast.rb#L396) root: observed AST::BgBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::Cast, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::Program, AST::ResolveNode, AST::ShareNode, AST::StringConcat, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, Array; kept as `T.untyped`
- [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) body: observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; kept as `T.untyped`
- [src/annotator/helpers/function_analysis.rb:89](../../src/annotator/helpers/function_analysis.rb#L89) declared_return: observed Symbol, Type; kept as `T.untyped`
- [src/annotator/helpers/generic_analysis.rb:507](../../src/annotator/helpers/generic_analysis.rb#L507) node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- [src/ast/type.rb:3557](../../src/ast/type.rb#L3557) node: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- [src/ast/type.rb:3557](../../src/ast/type.rb#L3557) effective_type: observed FunctionSignature, Symbol, Type; kept as `T.untyped`
- ... and 41 more (run with `--full` to see all)

## Return Origin Pressure
- origin: the expression or forwarded callee that currently determines a method's return type
- pressure: how many untyped returns could be improved by fixing the same origin
- cascading return fix: a return annotation that can unlock other forwarded-return annotations after it becomes typed
- blocked: 113
- weak: 45
- strong: 15

Top root return blockers:
- untyped callee fixable!; affects 15 return(s); 15 source occurrence(s)
  - [src/annotator/helpers/fixable_helpers.rb:540](../../src/annotator/helpers/fixable_helpers.rb#L540) `FixableHelper#emit_overflow_suffix_fix!`
  - [src/annotator/helpers/fixable_helpers.rb:752](../../src/annotator/helpers/fixable_helpers.rb#L752) `FixableHelper#emit_match_partial_fix!`
  - [src/annotator/helpers/fixable_helpers.rb:779](../../src/annotator/helpers/fixable_helpers.rb#L779) `FixableHelper#emit_return_borrowed_no_copy_error!`
  - [src/annotator/helpers/fixable_helpers.rb:860](../../src/annotator/helpers/fixable_helpers.rb#L860) `FixableHelper#emit_with_guard_all_bindings_need_as!`
- untyped callee each_pair; affects 7 return(s); 7 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
  - [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`
- untyped callee each; affects 6 return(s); 9 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
- untyped callee call; affects 5 return(s); 5 source occurrence(s)
  - [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves`
  - [src/ast/scope.rb:492](../../src/ast/scope.rb#L492) `ScopeHelper#with_new_scope`
  - [src/mir/mir_lowering.rb:2545](../../src/mir/mir_lowering.rb#L2545) `MIRLowering#with_decl_alloc`
  - [src/mir/mir_lowering.rb:2567](../../src/mir/mir_lowering.rb#L2567) `MIRLowering#with_sink_type`
- untyped callee parse_suffixes; affects 5 return(s); 5 source occurrence(s)
  - [src/ast/parser.rb:488](../../src/ast/parser.rb#L488) `Parser#parse_literal`
  - [src/ast/parser.rb:1962](../../src/ast/parser.rb#L1962) `Parser#parse_var_id`
  - [src/ast/parser.rb:2477](../../src/ast/parser.rb#L2477) `Parser#parse_primary`
  - [src/ast/parser.rb:2522](../../src/ast/parser.rb#L2522) `Parser#parse_lit`
- untyped callee hoist_alloc; affects 4 return(s); 5 source occurrence(s)
  - [src/mir/lowering/control_flow.rb:114](../../src/mir/lowering/control_flow.rb#L114) `MIRLoweringControlFlow#lower_control_condition`
  - [src/mir/lowering/expressions.rb:972](../../src/mir/lowering/expressions.rb#L972) `MIRLoweringExpressions#materialize_or_fallback_value`
  - [src/mir/lowering/expressions.rb:972](../../src/mir/lowering/expressions.rb#L972) `MIRLoweringExpressions#materialize_or_fallback_value`
  - [src/mir/lowering/functions.rb:1227](../../src/mir/lowering/functions.rb#L1227) `MIRLoweringFunctions#lower_call_arg_from_facts`
- untyped callee each_value; affects 4 return(s); 4 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
  - [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`
- untyped callee cast; affects 3 return(s); 4 source occurrence(s)
  - [src/mir/lowering/expressions.rb:2098](../../src/mir/lowering/expressions.rb#L2098) `MIRLoweringExpressions#lower_share`
  - [src/mir/lowering/expressions.rb:2098](../../src/mir/lowering/expressions.rb#L2098) `MIRLoweringExpressions#lower_share`
  - [src/mir/lowering/functions.rb:990](../../src/mir/lowering/functions.rb#L990) `MIRLoweringFunctions#cross_boundary_arg`
  - [src/mir/lowering/literals.rb:81](../../src/mir/lowering/literals.rb#L81) `MIRLoweringLiterals#lower_list_lit`
- untyped callee []; affects 3 return(s); 3 source occurrence(s); suggestion review as nilable lookup or replace with fetch/typed accessor
  - [src/annotator/helpers/intrinsic_registry.rb:271](../../src/annotator/helpers/intrinsic_registry.rb#L271) `IntrinsicRegistry#sig`
  - [src/ast/parser.rb:141](../../src/ast/parser.rb#L141) `Parser#peek_at`
  - [src/mir/fsm_ops.rb:346](../../src/mir/fsm_ops.rb#L346) `FsmOps::Lowerer#lower_expr`
- untyped callee instance_exec; affects 3 return(s); 3 source occurrence(s)
  - [src/ast/parser.rb:711](../../src/ast/parser.rb#L711) `Parser#parse_statement`
  - [src/ast/parser.rb:2477](../../src/ast/parser.rb#L2477) `Parser#parse_primary`
  - [src/ast/parser.rb:3870](../../src/ast/parser.rb#L3870) `Parser#parse_bg_body_stmt`
- ... and 20 more (run with `--full` to see all)

Top cascading return fixes:
- nil return at [src/annotator/helpers/intrinsic_registry.rb:62](../../src/annotator/helpers/intrinsic_registry.rb#L62); may unlock 1 return(s) (1 direct, 0 cascading), 1 possible param flow(s)
  - [src/annotator/helpers/intrinsic_registry.rb:61](../../src/annotator/helpers/intrinsic_registry.rb#L61) `IntrinsicRegistry#nested_emit`
- nil return at [src/ast/fixable_error.rb:141](../../src/ast/fixable_error.rb#L141); may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - [src/ast/fixable_error.rb:140](../../src/ast/fixable_error.rb#L140) `FixCollector#disable!`
- nil return at [src/ast/scope.rb:375](../../src/ast/scope.rb#L375); may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - [src/ast/scope.rb:375](../../src/ast/scope.rb#L375) `Scope#mark_read`
- nil return at [src/ast/type.rb:2593](../../src/ast/type.rb#L2593); may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - [src/ast/type.rb:2592](../../src/ast/type.rb#L2592) `Type#stream_capacity`
- unknown expression at [src/backends/pipeline_rewriter.rb:764](../../src/backends/pipeline_rewriter.rb#L764); may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - [src/backends/pipeline_rewriter.rb:759](../../src/backends/pipeline_rewriter.rb#L759) `PipelineRewriter#patch_chain_source!`
- nil return at [src/mir/fsm_transform/segments.rb:361](../../src/mir/fsm_transform/segments.rb#L361); may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - [src/mir/fsm_transform/segments.rb:357](../../src/mir/fsm_transform/segments.rb#L357) `FsmTransform::Segments#suspend_for`
- nil return at [src/mir/test_lowering.rb:328](../../src/mir/test_lowering.rb#L328); may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - [src/mir/test_lowering.rb:325](../../src/mir/test_lowering.rb#L325) `TestLowering#stub_intercept_for`

Forwarded return blocker pressure:
- fixable!: callee return still untyped; affects 15 return(s), 0 possible param flow(s)
  - [src/annotator/helpers/fixable_helpers.rb:540](../../src/annotator/helpers/fixable_helpers.rb#L540) `FixableHelper#emit_overflow_suffix_fix!`
  - [src/annotator/helpers/fixable_helpers.rb:752](../../src/annotator/helpers/fixable_helpers.rb#L752) `FixableHelper#emit_match_partial_fix!`
  - [src/annotator/helpers/fixable_helpers.rb:779](../../src/annotator/helpers/fixable_helpers.rb#L779) `FixableHelper#emit_return_borrowed_no_copy_error!`
  - [src/annotator/helpers/fixable_helpers.rb:860](../../src/annotator/helpers/fixable_helpers.rb#L860) `FixableHelper#emit_with_guard_all_bindings_need_as!`
- each_pair: unresolved forwarded callee; affects 7 return(s), 0 possible param flow(s)
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
  - [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`
- each: ambiguous method name; affects 6 return(s), 0 possible param flow(s)
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
- call: ambiguous method name; affects 5 return(s), 47 possible param flow(s)
  - [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves`
  - [src/ast/scope.rb:492](../../src/ast/scope.rb#L492) `ScopeHelper#with_new_scope`
  - [src/mir/mir_lowering.rb:2545](../../src/mir/mir_lowering.rb#L2545) `MIRLowering#with_decl_alloc`
  - [src/mir/mir_lowering.rb:2567](../../src/mir/mir_lowering.rb#L2567) `MIRLowering#with_sink_type`
- parse_suffixes: callee return still untyped; affects 5 return(s), 0 possible param flow(s)
  - [src/ast/parser.rb:488](../../src/ast/parser.rb#L488) `Parser#parse_literal`
  - [src/ast/parser.rb:1962](../../src/ast/parser.rb#L1962) `Parser#parse_var_id`
  - [src/ast/parser.rb:2477](../../src/ast/parser.rb#L2477) `Parser#parse_primary`
  - [src/ast/parser.rb:2522](../../src/ast/parser.rb#L2522) `Parser#parse_lit`
- hoist_alloc: static candidate MIR::Ident; affects 4 return(s), 6 possible param flow(s)
  - [src/mir/lowering/control_flow.rb:114](../../src/mir/lowering/control_flow.rb#L114) `MIRLoweringControlFlow#lower_control_condition`
  - [src/mir/lowering/expressions.rb:972](../../src/mir/lowering/expressions.rb#L972) `MIRLoweringExpressions#materialize_or_fallback_value`
  - [src/mir/lowering/expressions.rb:972](../../src/mir/lowering/expressions.rb#L972) `MIRLoweringExpressions#materialize_or_fallback_value`
  - [src/mir/lowering/functions.rb:1227](../../src/mir/lowering/functions.rb#L1227) `MIRLoweringFunctions#lower_call_arg_from_facts`
- each_value: unresolved forwarded callee; affects 4 return(s), 0 possible param flow(s)
  - [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`
  - [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`
  - [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`
  - [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`
- []: ambiguous method name; affects 3 return(s), 3097 possible param flow(s)
  - [src/annotator/helpers/intrinsic_registry.rb:271](../../src/annotator/helpers/intrinsic_registry.rb#L271) `IntrinsicRegistry#sig`
  - [src/ast/parser.rb:141](../../src/ast/parser.rb#L141) `Parser#peek_at`
  - [src/mir/fsm_ops.rb:346](../../src/mir/fsm_ops.rb#L346) `FsmOps::Lowerer#lower_expr`
- cast: unresolved forwarded callee; affects 3 return(s), 182 possible param flow(s)
  - [src/mir/lowering/expressions.rb:2098](../../src/mir/lowering/expressions.rb#L2098) `MIRLoweringExpressions#lower_share`
  - [src/mir/lowering/expressions.rb:2098](../../src/mir/lowering/expressions.rb#L2098) `MIRLoweringExpressions#lower_share`
  - [src/mir/lowering/functions.rb:990](../../src/mir/lowering/functions.rb#L990) `MIRLoweringFunctions#cross_boundary_arg`
  - [src/mir/lowering/literals.rb:81](../../src/mir/lowering/literals.rb#L81) `MIRLoweringLiterals#lower_list_lit`
- instance_exec: unresolved forwarded callee; affects 3 return(s), 0 possible param flow(s)
  - [src/ast/parser.rb:711](../../src/ast/parser.rb#L711) `Parser#parse_statement`
  - [src/ast/parser.rb:2477](../../src/ast/parser.rb#L2477) `Parser#parse_primary`
  - [src/ast/parser.rb:3870](../../src/ast/parser.rb#L3870) `Parser#parse_bg_body_stmt`
- ... and 10 more (run with `--full` to see all)

High-impact root return actions:
- untyped callee each_pair: review as receiver-returning iterator; callers probably want explicit return value; may unblock 7 return(s)
- untyped callee each: review as receiver-returning iterator; callers probably want explicit return value; may unblock 6 return(s)
- untyped callee each_value: review as receiver-returning iterator; callers probably want explicit return value; may unblock 4 return(s)
- untyped callee []: review as nilable lookup or replace with fetch/typed accessor; may unblock 3 return(s)
- untyped callee finalize_call_result: void candidate: return is only forwarded into other returns, never used as a value; may unblock 2 return(s)
- untyped callee try_catch_with_provenance: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee return_with_transfer_marks: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee with_pending: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee finalize_program_semantics!: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee finalize_program_semantics! at [src/annotator/annotator.rb:725](../../src/annotator/annotator.rb#L725): void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- ... and 10 more (run with `--full` to see all)

Blocked return examples:
- [src/annotator/annotator.rb:673](../../src/annotator/annotator.rb#L673) `SemanticAnnotator#visit`: untyped callee register_type_declaration at [src/annotator/annotator.rb:678](../../src/annotator/annotator.rb#L678)
- [src/annotator/annotator.rb:698](../../src/annotator/annotator.rb#L698) `SemanticAnnotator#visit_Program`: untyped callee finalize_program_semantics! at [src/annotator/annotator.rb:725](../../src/annotator/annotator.rb#L725)
- [src/annotator/helpers/auto_inference.rb:741](../../src/annotator/helpers/auto_inference.rb#L741) `ShapeEvidenceCollector#walk_for_shape_decls`: untyped callee walk_for_shape_decls at [src/annotator/helpers/auto_inference.rb:746](../../src/annotator/helpers/auto_inference.rb#L746)
- [src/annotator/helpers/auto_inference.rb:762](../../src/annotator/helpers/auto_inference.rb#L762) `ShapeEvidenceCollector#walk`: untyped callee each at [src/annotator/helpers/auto_inference.rb:768](../../src/annotator/helpers/auto_inference.rb#L768)
- [src/annotator/helpers/auto_inference.rb:896](../../src/annotator/helpers/auto_inference.rb#L896) `OperatorEvidenceCollector#walk_for_local_decls`: untyped callee walk_for_local_decls at [src/annotator/helpers/auto_inference.rb:901](../../src/annotator/helpers/auto_inference.rb#L901)
- [src/annotator/helpers/auto_inference.rb:919](../../src/annotator/helpers/auto_inference.rb#L919) `OperatorEvidenceCollector#walk_binops`: untyped callee walk_binops at [src/annotator/helpers/auto_inference.rb:925](../../src/annotator/helpers/auto_inference.rb#L925)
- [src/annotator/helpers/capabilities.rb:1208](../../src/annotator/helpers/capabilities.rb#L1208) `CapabilityHelper#without_capture_moves`: untyped callee call at [src/annotator/helpers/capabilities.rb:1211](../../src/annotator/helpers/capabilities.rb#L1211)
- [src/annotator/helpers/fixable_helpers.rb:540](../../src/annotator/helpers/fixable_helpers.rb#L540) `FixableHelper#emit_overflow_suffix_fix!`: untyped callee fixable! at [src/annotator/helpers/fixable_helpers.rb:550](../../src/annotator/helpers/fixable_helpers.rb#L550)
- [src/annotator/helpers/fixable_helpers.rb:1473](../../src/annotator/helpers/fixable_helpers.rb#L1473) `FixableHelper#emit_auto_resolved_finding!`: untyped callee fixable! at [src/annotator/helpers/fixable_helpers.rb:1481](../../src/annotator/helpers/fixable_helpers.rb#L1481)
- [src/annotator/helpers/fixable_helpers.rb:1497](../../src/annotator/helpers/fixable_helpers.rb#L1497) `FixableHelper#emit_auto_shape_resolved_finding!`: untyped callee fixable! at [src/annotator/helpers/fixable_helpers.rb:1504](../../src/annotator/helpers/fixable_helpers.rb#L1504)
- ... and 2 more (run with `--full` to see all)

## Input Param Origin Backflow
- origin: the caller-side expression passed into a parameter slot
- backflow: tracing weak or untyped parameter pressure backward from the callee slot to the caller expression that supplied it
- return-to-param flow: a method return value that is later passed into another method's parameter
- Origins indexed: 79661
- static: 29908
- local: 18016
- unknown: 13183
- untyped_return: 10752
- typed_return: 7802

Return-to-param flows:
- []: 3129 flow(s); [src/annotator/annotator.rb:114](../../src/annotator/annotator.rb#L114) -> const(1); [src/annotator/annotator.rb:118](../../src/annotator/annotator.rb#L118) -> const(1); [src/annotator/annotator.rb:124](../../src/annotator/annotator.rb#L124) -> prop(1); [src/annotator/annotator.rb:125](../../src/annotator/annotator.rb#L125) -> prop(1)
- nilable: 2278 flow(s); [src/annotator/annotator.rb:102](../../src/annotator/annotator.rb#L102) -> const(1); [src/annotator/annotator.rb:131](../../src/annotator/annotator.rb#L131) -> prop(1); [src/annotator/annotator.rb:146](../../src/annotator/annotator.rb#L146) -> prop(1); [src/annotator/annotator.rb:147](../../src/annotator/annotator.rb#L147) -> prop(1)
- new: 1940 flow(s); [src/annotator/annotator.rb:272](../../src/annotator/annotator.rb#L272) -> <<(0); [src/annotator/annotator.rb:486](../../src/annotator/annotator.rb#L486) -> <<(0); [src/annotator/annotator.rb:528](../../src/annotator/annotator.rb#L528) -> let(0); [src/annotator/annotator.rb:529](../../src/annotator/annotator.rb#L529) -> let(0)
- untyped: 1354 flow(s); [src/annotator/annotator.rb:672](../../src/annotator/annotator.rb#L672) -> returns(0); [src/annotator/annotator.rb:697](../../src/annotator/annotator.rb#L697) -> returns(0); [src/annotator/annotator.rb:777](../../src/annotator/annotator.rb#L777) -> let(1); [src/annotator/annotator.rb:791](../../src/annotator/annotator.rb#L791) -> let(1)
- name: 494 flow(s); [src/annotator/domains/control_flow.rb:163](../../src/annotator/domains/control_flow.rb#L163) -> declare(0); [src/annotator/domains/control_flow.rb:164](../../src/annotator/domains/control_flow.rb#L164) -> local_entry!(0); [src/annotator/domains/control_flow.rb:211](../../src/annotator/domains/control_flow.rb#L211) -> key?(0); [src/annotator/domains/control_flow.rb:215](../../src/annotator/domains/control_flow.rb#L215) -> emit_typo_suggestion!(1)
- to_s: 394 flow(s); [src/annotator/domains/control_flow.rb:176](../../src/annotator/domains/control_flow.rb#L176) -> og_declare(0); [src/annotator/domains/control_flow.rb:704](../../src/annotator/domains/control_flow.rb#L704) -> record_capture_local!(0); [src/annotator/domains/control_flow.rb:750](../../src/annotator/domains/control_flow.rb#L750) -> record_capture_local!(0); [src/annotator/domains/control_flow.rb:849](../../src/annotator/domains/control_flow.rb#L849) -> record_capture_local!(0)
- value: 357 flow(s); [src/annotator/domains/control_flow.rb:436](../../src/annotator/domains/control_flow.rb#L436) -> visit(0); [src/annotator/domains/control_flow.rb:456](../../src/annotator/domains/control_flow.rb#L456) -> visit(0); [src/annotator/domains/control_flow.rb:501](../../src/annotator/domains/control_flow.rb#L501) -> match_variant_name(0); [src/annotator/domains/control_flow.rb:553](../../src/annotator/domains/control_flow.rb#L553) -> match_variant_name(0)
- any: 275 flow(s); [src/annotator/annotator.rb:121](../../src/annotator/annotator.rb#L121) -> [](1); [src/annotator/domains/control_flow.rb:310](../../src/annotator/domains/control_flow.rb#L310) -> params(schema); [src/annotator/domains/control_flow.rb:873](../../src/annotator/domains/control_flow.rb#L873) -> params(node); [src/annotator/domains/control_flow.rb:873](../../src/annotator/domains/control_flow.rb#L873) -> params(body)
- must: 260 flow(s); [src/annotator/annotator.rb:491](../../src/annotator/annotator.rb#L491) -> held_locks=(0); [src/annotator/annotator.rb:492](../../src/annotator/annotator.rb#L492) -> held_lock_types=(0); [src/annotator/domains/control_flow.rb:559](../../src/annotator/domains/control_flow.rb#L559) -> declare_match_destructure_fields!(2); [src/annotator/domains/control_flow.rb:706](../../src/annotator/domains/control_flow.rb#L706) -> classify_ownership!(0)
- body: 214 flow(s); [src/annotator/domains/control_flow.rb:406](../../src/annotator/domains/control_flow.rb#L406) -> visit_stmts(0); [src/annotator/domains/control_flow.rb:682](../../src/annotator/domains/control_flow.rb#L682) -> expr_result_type(0); [src/annotator/domains/control_flow.rb:707](../../src/annotator/domains/control_flow.rb#L707) -> visit_stmts(0); [src/annotator/domains/control_flow.rb:715](../../src/annotator/domains/control_flow.rb#L715) -> validate_tight_body!(0)
- ... and 10 more (run with `--full` to see all)

## Foreign Scalar Inputs Into Object-Typed Params
This ranks caller origins where `String`/`Symbol` values flow into params that also receive object instances. It skips `src/tools` origins unless `NIL_KILL_FOREIGN_INCLUDE_TOOLS=1`.
- [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) `def walk(node, current_fn:)`; 696549 foreign scalar call(s), affects 1 slot(s)
  - [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215) `AutoConstraintCollector#walk` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (696549); trace [src/annotator/helpers/auto_inference.rb:215](../../src/annotator/helpers/auto_inference.rb#L215)
- [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231) `def each_call_like(node, matches, &blk)`; 518931 foreign scalar call(s), affects 1 slot(s)
  - [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231) `Hoist#each_call_like` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (518931); trace [src/mir/hoist.rb:231](../../src/mir/hoist.rb#L231)
- [src/mir/hoist.rb:246](../../src/mir/hoist.rb#L246) `def each_call_like_child(child, matches, &blk)`; 518863 foreign scalar call(s), affects 1 slot(s)
  - [src/mir/hoist.rb:246](../../src/mir/hoist.rb#L246) `Hoist#each_call_like_child` child: String, Symbol into AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock (518863); trace [src/mir/hoist.rb:246](../../src/mir/hoist.rb#L246)
- [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) `def each_mir_expr_in_value(value, &blk)`; 383437 foreign scalar call(s), affects 1 slot(s)
  - [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577) `MIRHoistLowering#each_mir_expr_in_value` value: String, Symbol into AST::BinaryOp, Array, FunctionSignature, Hash, MIR::AddressOf (383437); trace [src/mir/hoist.rb:577](../../src/mir/hoist.rb#L577)
- [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) `def mir_expr_child?(value)`; 383437 foreign scalar call(s), affects 1 slot(s)
  - [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589) `MIRHoistLowering#mir_expr_child?` value: String, Symbol into AST::BinaryOp, Array, FunctionSignature, Hash, MIR::AddressOf (383437); trace [src/mir/hoist.rb:589](../../src/mir/hoist.rb#L589)
- [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) `def walk(node, violations, seen)`; 345294 foreign scalar call(s), affects 1 slot(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) `PreMirTypeCheck#walk` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (345294); trace [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71)
- [src/ast/type.rb:1369](../../src/ast/type.rb#L1369) `def ==(other)`; 85866 foreign scalar call(s), affects 1 slot(s)
  - [src/ast/type.rb:1369](../../src/ast/type.rb#L1369) Type#== other: Symbol into Type (85866); trace [src/ast/type.rb:1369](../../src/ast/type.rb#L1369)
- [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) `def to_return_def(v)`; 47629 foreign scalar call(s), affects 1 slot(s)
  - [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) `IntrinsicRegistry#to_return_def` v: Symbol into Hash, Proc, Type (47629); trace [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103)
- [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) `def is_safe_autocast?(source_type, target_type)`; 15859 foreign scalar call(s), affects 2 slot(s)
  - [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) `TypeHelper#is_safe_autocast?` source_type: Symbol into Type (9523); trace [src/ast/type.rb:3549](../../src/ast/type.rb#L3549)
  - [src/ast/type.rb:3549](../../src/ast/type.rb#L3549) `TypeHelper#is_safe_autocast?` target_type: Symbol into Type (6336); trace [src/ast/type.rb:3549](../../src/ast/type.rb#L3549)
- [src/ast/type.rb:3544](../../src/ast/type.rb#L3544) `def to_type(input)`; 15859 foreign scalar call(s), affects 1 slot(s)
  - [src/ast/type.rb:3544](../../src/ast/type.rb#L3544) `TypeHelper#to_type` input: Symbol into Type (15859); trace [src/ast/type.rb:3544](../../src/ast/type.rb#L3544)
- ... and 28 more (run with `--full` to see all)

## Type Normalizer Sites
- Sites matching `is_a?(Type)` plus `Type.new(...)`: 128
- [src/ast/type.rb](../../src/ast/type.rb): 12
  - line 314 `TypeShape#resolved`: item.is_a?(Type)
  - line 423 `Type#indirect_type?`: value.is_a?(Type)
  - line 430 `Type#surface_name`: type.is_a?(Type)
  - line 549 `Type#coerce_error`: target_type.is_a?(Type)
  - line 753 `Type#initialize`: raw_input.is_a?(Type)
  - ... 7 more
- [src/annotator/domains/lifetimes.rb](../../src/annotator/domains/lifetimes.rb): 10
  - line 69 `Annotator::Domains::Lifetimes#ensure_owned_value!`: vti.is_a?(Type)
  - line 76 `Annotator::Domains::Lifetimes#ensure_owned_value!`: expected_type.is_a?(Type)
  - line 80 `Annotator::Domains::Lifetimes#ensure_owned_value!`: expected_type.is_a?(Type)
  - line 122 `Annotator::Domains::Lifetimes#visit_CopyNode`: inner_type.is_a?(Type)
  - line 129 `Annotator::Domains::Lifetimes#visit_CopyNode`: ti.is_a?(Type)
  - ... 5 more
- [src/annotator/helpers/auto_inference.rb](../../src/annotator/helpers/auto_inference.rb): 9
  - line 580 `AutoUnifier#collect_observed_types`: t.is_a?(Type)
  - line 590 `AutoUnifier#widen_byte_array_to_string`: t.is_a?(Type)
  - line 601 `AutoUnifier#types_equal?`: a.is_a?(Type)
  - line 601 `AutoUnifier#types_equal?`: b.is_a?(Type)
  - line 602 `AutoUnifier#types_equal?`: a.is_a?(Type)
  - ... 4 more
- [src/mir/lowering/functions.rb](../../src/mir/lowering/functions.rb): 8
  - line 290 `MIRLoweringFunctions#lower_function_def`: ret_type.is_a?(Type)
  - line 1231 `MIRLoweringFunctions#lower_call_arg_from_facts`: facts.callee_param_type.is_a?(Type)
  - line 1314 `MIRLoweringFunctions#wants_ptr?`: ti.is_a?(Type)
  - line 1458 `MIRLoweringFunctions#call_owned_return?`: raw_ti.is_a?(Type)
  - line 1912 `MIRLoweringFunctions#build_extern_trampoline_call`: pt.is_a?(Type)
  - ... 3 more
- [src/annotator/domains/control_flow.rb](../../src/annotator/domains/control_flow.rb): 7
  - line 241 `Annotator::Domains::ControlFlow#annotate_struct_pattern!`: ft.is_a?(Type)
  - line 278 `Annotator::Domains::ControlFlow#normalized_match_payload`: payload.is_a?(Type)
  - line 530 `Annotator::Domains::ControlFlow#match_payload_binding_type`: raw_payload.is_a?(Type)
  - line 573 `Annotator::Domains::ControlFlow#match_payload_struct_schema`: raw_payload.is_a?(Type)
  - line 732 `Annotator::Domains::ControlFlow#visit_ForEach`: coll_type.is_a?(Type)
  - ... 2 more
- [src/annotator/helpers/pipe_analysis.rb](../../src/annotator/helpers/pipe_analysis.rb): 6
  - line 771 `PipeAnalysis#analyze_pipe_to_identifier`: sig.is_a?(Type)
  - line 817 `PipeAnalysis#analyze_pipe_to_named_function`: result_type.is_a?(Type)
  - line 1157 `PipeAnalysis#emit_multi_map_warning`: sc.is_a?(Type)
  - line 1246 `PipeAnalysis#auto_detect_sharded_access`: map_type.is_a?(Type)
  - line 1322 `PipeAnalysis#sharded_unsynced_entry?`: type.is_a?(Type)
  - ... 1 more
- [src/mir/lowering/expressions.rb](../../src/mir/lowering/expressions.rb): 6
  - line 1502 `MIRLoweringExpressions#lower_struct_lit`: field_type_input.is_a?(Type)
  - line 1591 `MIRLoweringExpressions#lower_union_variant_lit`: ft.is_a?(Type)
  - line 1987 `MIRLoweringExpressions#lower_copy`: sink_type.is_a?(Type)
  - line 2032 `MIRLoweringExpressions#copy_source_type_info`: sym_type.is_a?(Type)
  - line 2101 `MIRLoweringExpressions#lower_share`: source_ti.is_a?(Type)
  - ... 1 more
- [src/semantic/escape_analysis.rb](../../src/semantic/escape_analysis.rb): 6
  - line 311 `EscapeAnalysis#propagate_caller_sync!`: t.is_a?(Type)
  - line 329 `EscapeAnalysis#propagate_caller_sync!`: t.is_a?(Type)
  - line 367 `EscapeAnalysis#param_sync_was_declared?`: t.is_a?(Type)
  - line 373 `EscapeAnalysis#param_accepts_caller_sync?`: t.is_a?(Type)
  - line 458 `EscapeAnalysis#mark_param_receiver_allocations_heap!`: ti.is_a?(Type)
  - ... 1 more
- [src/annotator/helpers/capabilities.rb](../../src/annotator/helpers/capabilities.rb): 4
  - line 206 `CapabilityHelper#validate_capability_transition!`: var_type.is_a?(Type)
  - line 219 `CapabilityHelper#validate_capability_transition!`: var_type.is_a?(Type)
  - line 813 `CapabilityHelper#acquire_capability!`: base_t.is_a?(Type)
  - line 1303 `CapabilityAudit#record_capability_binding`: final_type.is_a?(Type)
- ... and 11 more (run with `--full` to see all)

## Struct Shape Report
- Struct declarations: 335
- Runtime-observed struct field slots: 662
- Static constructor field observations: 7120

### Struct Field Slot Breakdown
- missing field type with candidate: 119
  - `AST::Param.name` -> String (runtime 90046)
  - `AST::Param.takes` -> T.any(FalseClass, Lexer::Token, TrueClass) (runtime 77450)
  - `AST::Capture.name` -> String (runtime 32)
  - `AST::Capture.mutable` -> T.any(FalseClass, Lexer::Token) (runtime 31)
  - `AST::Capture.takes` -> T::Boolean (runtime 31)
  - `AST::Capture.comptime` -> T::Boolean (runtime 31)
  - `AST::Capture.name_token` -> Lexer::Token (runtime 31)
  - `AST::MatchCase.kind` -> Symbol (runtime 2873)
  - ... 111 more
- missing field type with no candidate: 77
  - `AST::Param.type`
  - `AST::Param.default`
  - `AST::Param.mutable`
  - `AST::Param.comptime`
  - `AST::Param.name_token`
  - `AST::Param.required`
  - `AST::Param.sync`
  - `AST::Param.symbol`
  - ... 69 more
- untyped with runtime candidate: 214
  - `AST::UnaryOp.op` current `T.untyped` -> T.any(String, Symbol) (runtime 1724)
  - `AST::CallSiteOverride.inner` current `T.untyped` -> AST::FuncCall (runtime 5)
  - `AST::StructLit.fields` current `T.untyped` -> T.any(Array, Hash, T::Hash[`T.untyped`, `T.untyped`]) (runtime 9810)
  - `AST::IfStatement.then_branch` current `T.untyped` -> T.any(Array, T::Array[Object], T::Array[`T.untyped`]) (runtime 3109)
  - `AST::MethodCall.name` current `T.untyped` -> String (runtime 18567)
  - `AST::DieNode.status` current `T.untyped` -> T.any(AST::Literal, Integer) (runtime 5)
  - `AST::Slice.target` current `T.untyped` -> T.any(AST::GetIndex, AST::Identifier) (runtime 67)
  - `AST::ReduceOp.initial_value` current `T.untyped` -> T.any(AST::Identifier, AST::Literal) (runtime 278)
  - ... 206 more
- untyped with static candidate: 45
  - `AST::FunctionDef.return_type` current `T.untyped` -> T.any(Symbol, Type) (static)
  - `AST::BinaryOp.op` current `T.untyped` -> T.any(String, Symbol) (static)
  - `AST::StructLit.type_args` current `T.untyped` -> T::Array[String] (static)
  - `AST::IfBind.bindings` current `T.untyped` -> T::Array[AST::Binding] (static)
  - `AST::IfBind.then_branch` current `T.untyped` -> T::Array[Object] (static)
  - `AST::IfBind.else_branch` current `T.untyped` -> T::Array[Object] (static)
  - `AST::WhileLoop.do_branch` current `T.untyped` -> T.any(T::Array[Object], T::Array[`T.untyped`]) (static)
  - `AST::WhileBindLoop.do_branch` current `T.untyped` -> T.any(T::Array[Object], T::Array[`T.untyped`]) (static)
  - ... 37 more
- untyped with no candidate: 267
  - `AST::RequireNode.path` current `T.untyped`
  - `AST::RequireNode.namespace` current `T.untyped`
  - `AST::FunctionDef.name` current `T.untyped`
  - `AST::FunctionDef.return_lifetime` current `T.untyped`
  - `AST::FunctionDef.catch_clauses` current `T.untyped`
  - `AST::FunctionDef.default_catch` current `T.untyped`
  - `AST::FunctionDef.deferred_drops` current `T.untyped`
  - `AST::FunctionDef.uses_frame` current `T.untyped`
  - ... 259 more
- weak collection or union type: 46
  - `Capabilities::Conflict.set_a` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 1204)
  - `Capabilities::Conflict.set_b` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 1204)
  - `AST::Program.statements` current T::Array[`T.untyped`]
  - `AST::FunctionDef.params` current T::Array[`T.untyped`]
  - `AST::FunctionDef.captures` current T.nilable(T::Array[`T.untyped`])
  - `AST::FunctionDef.body` current T::Array[`T.untyped`] -> T.any(Array, T::Array[Object], T::Array[`T.untyped`]) (runtime 17087)
  - `AST::StructDef.type_params` current T::Array[`T.untyped`] -> T::Array[String] (static)
  - `AST::ListLit.items` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 4613)
  - ... 38 more
- typed but nilable: 26
  - `AST::Cast.token` current T.nilable(Token)
  - `AST::Require.token` current T.nilable(Token)
  - `AST::IndexOp.token` current T.nilable(Token) -> Lexer::Token (runtime 63)
  - `AST::OrderByOp.token` current T.nilable(Token) -> Lexer::Token (runtime 32)
  - `AST::LimitOp.token` current T.nilable(Token) -> Lexer::Token (runtime 247)
  - `AST::UnnestOp.token` current T.nilable(Token) -> Lexer::Token (runtime 152)
  - `AST::DistinctOp.token` current T.nilable(Token) -> Lexer::Token (runtime 200)
  - `AST::SkipOp.token` current T.nilable(Token) -> Lexer::Token (runtime 97)
  - ... 18 more
- strongly typed: 292
  - `Capabilities::Conflict.message` current String -> String (static)
  - `FixableHelper::AnchorToken.line` current Integer -> Integer (static)
  - `FixableHelper::AnchorToken.column` current Integer -> Integer (static)
  - `AST::Program.token` current Lexer::Token -> T.any(Lexer::Token, T::Array[`T.untyped`]) (runtime 10185)
  - `AST::RequireNode.token` current Token
  - `AST::RequireNode.kind` current Symbol -> Symbol (static)
  - `AST::FunctionDef.token` current Token
  - `AST::FunctionDef.visibility` current Symbol
  - ... 284 more

### Struct Field Type Candidates
- `AST::Param.name`; String; runtime; 90046 call(s)
- `AST::Param.takes`; T.any(FalseClass, Lexer::Token, TrueClass); runtime; 77450 call(s)
- `AST::FuncCall.args`; T.any(Array, T::Array[AST::Node], T::Array[`T.untyped`]); runtime; 24566 call(s)
- `BinaryOpResult.type`; Type; runtime; 21001 call(s)
- `AST::MethodCall.name`; String; runtime; 18567 call(s)
- `AST::FunctionDef.body`; T.any(Array, T::Array[Object], T::Array[`T.untyped`]); runtime; 17087 call(s)
- `MIR::Call.callee`; String; runtime; 10445 call(s)
- `MIR::Call.owned_return`; T.any(FalseClass, T::Boolean, TrueClass); runtime; 10254 call(s)
- `AST::Program.token`; T.any(Lexer::Token, T::Array[`T.untyped`]); runtime; 10185 call(s)
- `AST::StructLit.fields`; T.any(Array, Hash, T::Hash[`T.untyped`, `T.untyped`]); runtime; 9810 call(s)
- ... and 40 more (run with `--full` to see all)

## Collection Type Report
- Array signature slots: 1238 total, 906 strong, 332 weak, 124 nilable
- Hash signature slots: 272 total, 177 strong, 95 weak, 46 nilable

### Hash Record Struct Candidates (Shapes + Pressure)
- literal shape: a statically observed hash literal instantiation site in this candidate cluster
- similar keyset: a distinct hash key set grouped into the same likely record, e.g. `{name, id}` with `{name, id, type}`
- AddrsRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 18
  - common keys: addrs, allocs, bytes, free_bytes, frees, live
  - read keys: addrs(2), allocs(2), bytes(2), free_bytes(1), frees(1)
  - accounts for: return 0, param 10, ivar 0, collection 8
  - related pressure records: local hash record s at [src/tools/doctor.rb](../../src/tools/doctor.rb) (61); local hash record v at [src/tools/doctor.rb](../../src/tools/doctor.rb) (8); local hash record vals at [src/tools/doctor.rb](../../src/tools/doctor.rb) (4); local hash record s at [src/tools/pprof_converter.rb](../../src/tools/pprof_converter.rb) (3)
  - [src/tools/pprof_converter.rb:145](../../src/tools/pprof_converter.rb#L145) s[:addrs]; receiver s
  - [src/tools/pprof_converter.rb:149](../../src/tools/pprof_converter.rb#L149) s[:allocs]; receiver s
  - [src/tools/pprof_converter.rb:150](../../src/tools/pprof_converter.rb#L150) s[:bytes]; receiver s
  - [src/tools/pprof_converter.rb:151](../../src/tools/pprof_converter.rb#L151) s[:allocs]; receiver s
  - suggested struct:
    class AddrsRecord < T::Struct
      const :addrs, `T.untyped`
      const :allocs, Integer
      const :bytes, Integer
      const :free_bytes, Integer
      const :frees, Integer
      const :live, Integer
    end
- AllocsRecord: 8 literal shape(s), 3 similar keyset(s), total pressure 14
  - common keys: allocs, bytes
  - optional keys: addr, free_bytes, frees, inuse_allocs, inuse_bytes, live, trace
  - read keys: bytes(6), allocs(5)
  - accounts for: return 0, param 3, ivar 0, collection 11
  - related pressure records: local hash record s at [src/tools/doctor.rb](../../src/tools/doctor.rb) (61); local hash record v at [src/tools/doctor.rb](../../src/tools/doctor.rb) (8); local hash record vals at [src/tools/doctor.rb](../../src/tools/doctor.rb) (4)
  - [src/tools/doctor.rb:1339](../../src/tools/doctor.rb#L1339) self_total[:bytes]; receiver self_total
  - [src/tools/doctor.rb:1347](../../src/tools/doctor.rb#L1347) self_total[:bytes]; receiver self_total
  - [src/tools/doctor.rb:1347](../../src/tools/doctor.rb#L1347) self_total[:allocs]; receiver self_total
  - [src/tools/doctor.rb:1473](../../src/tools/doctor.rb#L1473) b[:bytes]; receiver b
  - suggested struct:
    class AllocsRecord < T::Struct
      prop :addr, `T.untyped`
      const :allocs, Integer
      const :bytes, Integer
      prop :free_bytes, T.nilable(Integer)
      prop :frees, T.nilable(Integer)
      prop :inuse_allocs, `T.untyped`
      prop :inuse_bytes, `T.untyped`
      prop :live, T.nilable(Integer)
      prop :trace, `T.untyped`
    end
- ContendedRecord: 6 literal shape(s), 5 similar keyset(s), total pressure 12
  - common keys: contended, read_contended, read_total_wait_ns, total_wait_ns
  - optional keys: acquires, addr, caller_trace, max_hold_ns, max_wait_ns, read_acquires, read_max_wait_ns, total_hold_ns, trace, traces
  - read keys: contended(2), read_contended(2), read_total_wait_ns(2), total_wait_ns(2)
  - accounts for: return 0, param 4, ivar 0, collection 8
  - related pressure records: local hash record l at [src/tools/pprof_converter.rb](../../src/tools/pprof_converter.rb) (26); local hash record l at [src/tools/doctor.rb](../../src/tools/doctor.rb) (20); local hash record r at [src/tools/doctor.rb](../../src/tools/doctor.rb) (20)
  - [src/tools/doctor.rb:1545](../../src/tools/doctor.rb#L1545) b[:contended]; receiver b
  - [src/tools/doctor.rb:1545](../../src/tools/doctor.rb#L1545) b[:read_contended]; receiver b
  - [src/tools/doctor.rb:1546](../../src/tools/doctor.rb#L1546) a[:contended]; receiver a
  - [src/tools/doctor.rb:1546](../../src/tools/doctor.rb#L1546) a[:read_contended]; receiver a
  - suggested struct:
    class ContendedRecord < T::Struct
      prop :acquires, T.nilable(Integer)
      prop :addr, T.nilable(String)
      prop :caller_trace, T.nilable(T::Array[`T.untyped`])
      const :contended, Integer
      prop :max_hold_ns, T.nilable(Integer)
      prop :max_wait_ns, T.nilable(Integer)
      prop :read_acquires, T.nilable(Integer)
      const :read_contended, Integer
      prop :read_max_wait_ns, T.nilable(Integer)
      const :read_total_wait_ns, Integer
      prop :total_hold_ns, T.nilable(Integer)
      const :total_wait_ns, Integer
      prop :trace, T.nilable(T::Array[`T.untyped`])
      prop :traces, `T.untyped`
    end
- CommitsRecord: 6 literal shape(s), 4 similar keyset(s), total pressure 8
  - common keys: commits, reads, retries
  - optional keys: addr, caller_trace, multi_commits, struct_size, trace, traces, update_failures
  - read keys: retries(4), commits(2)
  - accounts for: return 0, param 2, ivar 0, collection 6
  - related pressure records: local hash record c at [src/tools/pprof_converter.rb](../../src/tools/pprof_converter.rb) (34); hash record return first at [src/tools/doctor.rb:935](../../src/tools/doctor.rb#L935) (1)
  - [src/tools/doctor.rb:1614](../../src/tools/doctor.rb#L1614) a[:commits]; receiver a
  - [src/tools/doctor.rb:1614](../../src/tools/doctor.rb#L1614) b[:commits]; receiver b
  - [src/tools/doctor.rb:1615](../../src/tools/doctor.rb#L1615) a[:retries]; receiver a
  - [src/tools/doctor.rb:1615](../../src/tools/doctor.rb#L1615) b[:retries]; receiver b
  - suggested struct:
    class CommitsRecord < T::Struct
      prop :addr, T.nilable(String)
      prop :caller_trace, T.nilable(T::Array[`T.untyped`])
      const :commits, Integer
      prop :multi_commits, T.nilable(Integer)
      const :reads, Integer
      const :retries, Integer
      prop :struct_size, T.nilable(Integer)
      prop :trace, T.nilable(T::Array[`T.untyped`])
      prop :traces, `T.untyped`
      prop :update_failures, T.nilable(Integer)
    end
- NameRecord: 3 literal shape(s), 2 similar keyset(s), total pressure 7
  - common keys: name, stack_bytes
  - optional keys: zig_name
  - read keys: line(3), usage_pct(1)
  - accounts for: return 0, param 3, ivar 0, collection 4
  - related pressure records: hash record param field at [src/mir/mir.rb:662](../../src/mir/mir.rb#L662) (2); hash record return candidate_decl_info at [src/tools/migration_suggester_helpers.rb:64](../../src/tools/migration_suggester_helpers.rb#L64) (2); hash record return [] at [src/annotator/helpers/fixable_helpers.rb:1704](../../src/annotator/helpers/fixable_helpers.rb#L1704) (1); hash record return first at [src/mir/lowering/variables.rb:98](../../src/mir/lowering/variables.rb#L98) (1); local hash record a at [src/annotator/domains/lifetimes.rb](../../src/annotator/domains/lifetimes.rb) (1)
  - [src/tools/stack_verifier.rb:124](../../src/tools/stack_verifier.rb#L124) entry[:line]; receiver entry
  - [src/tools/stack_verifier.rb:132](../../src/tools/stack_verifier.rb#L132) entry[:line]; receiver entry
  - [src/tools/stack_verifier.rb:140](../../src/tools/stack_verifier.rb#L140) entry[:line]; receiver entry
  - [src/tools/stack_verifier.rb:143](../../src/tools/stack_verifier.rb#L143) entry[:usage_pct]; receiver entry
  - suggested struct:
    class NameRecord < T::Struct
      const :name, String
      const :stack_bytes, T.nilable(Integer)
      prop :zig_name, NilClass
    end
- BytesRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 7
  - common keys: bytes, reg
  - read keys: bytes(2), reg(2)
  - accounts for: return 0, param 3, ivar 0, collection 4
  - related pressure records: hash record hash literal at [src/tools/stack_verifier.rb:289](../../src/tools/stack_verifier.rb#L289) (3); hash record hash literal at [src/tools/stack_verifier.rb:84](../../src/tools/stack_verifier.rb#L84) (3)
  - [src/tools/stack_verifier.rb:85](../../src/tools/stack_verifier.rb#L85) pending_mov[:reg]; receiver pending_mov
  - [src/tools/stack_verifier.rb:87](../../src/tools/stack_verifier.rb#L87) pending_mov[:bytes]; receiver pending_mov
  - [src/tools/stack_verifier.rb:290](../../src/tools/stack_verifier.rb#L290) pending_mov[:reg]; receiver pending_mov
  - [src/tools/stack_verifier.rb:291](../../src/tools/stack_verifier.rb#L291) pending_mov[:bytes]; receiver pending_mov
  - suggested struct:
    class BytesRecord < T::Struct
      const :bytes, Integer
      const :reg, `T.untyped`
    end
- OwnershipRecord: 2 literal shape(s), 2 similar keyset(s), total pressure 7
  - common keys: ownership, sync
  - optional keys: layout, lock_rank
  - read keys: lock_rank(3), layout(1), ownership(1), sync(1)
  - accounts for: return 0, param 1, ivar 0, collection 6
  - related pressure records: hash record return [] at [src/annotator/helpers/function_analysis.rb:1312](../../src/annotator/helpers/function_analysis.rb#L1312) (7); hash record param v at [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) (6)
  - [src/ast/parser.rb:3631](../../src/ast/parser.rb#L3631) dims[:ownership]; receiver dims
  - [src/ast/parser.rb:3631](../../src/ast/parser.rb#L3631) dims[:sync]; receiver dims
  - [src/ast/parser.rb:3631](../../src/ast/parser.rb#L3631) dims[:layout]; receiver dims
  - [src/ast/parser.rb:3631](../../src/ast/parser.rb#L3631) dims[:lock_rank]; receiver dims
  - suggested struct:
    class OwnershipRecord < T::Struct
      prop :layout, NilClass
      prop :lock_rank, NilClass
      const :ownership, NilClass
      const :sync, NilClass
    end
- CaptureRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 6
  - common keys: capture, expr
  - read keys: expr(4), capture(2)
  - accounts for: return 0, param 0, ivar 0, collection 6
  - related pressure records: hash record return [] at [src/mir/mir_emitter.rb:1497](../../src/mir/mir_emitter.rb#L1497) (7); local hash record binding at [src/mir/mir_checker.rb](../../src/mir/mir_checker.rb) (3); local hash record binding at [src/mir/hoist.rb](../../src/mir/hoist.rb) (2); local hash record binding at [src/mir/mir_lowering.rb](../../src/mir/mir_lowering.rb) (2); local hash record entry at [src/annotator/helpers/capabilities.rb](../../src/annotator/helpers/capabilities.rb) (2)
  - [src/mir/hoist.rb:824](../../src/mir/hoist.rb#L824) binding[:expr]; receiver binding
  - [src/mir/hoist.rb:825](../../src/mir/hoist.rb#L825) binding[:capture]; receiver binding
  - [src/mir/mir.rb:1121](../../src/mir/mir.rb#L1121) binding[:expr]; receiver binding
  - [src/mir/mir_checker.rb:648](../../src/mir/mir_checker.rb#L648) binding[:expr]; receiver binding
  - suggested struct:
    class CaptureRecord < T::Struct
      const :capture, `T.untyped`
      const :expr, `T.untyped`
    end
- DispatchRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 5
  - common keys: dispatch, exits, form, id, max_lifetime_ns, runs, scheds, spawns, total_lifetime_ns
  - read keys: runs(3), dispatch(1), scheds(1)
  - accounts for: return 0, param 1, ivar 0, collection 4
  - related pressure records: local hash record site at [src/tools/doctor.rb](../../src/tools/doctor.rb) (10); hash record hash literal at [src/tools/pprof.rb:145](../../src/tools/pprof.rb#L145) (4); hash record return [] at [src/tools/pprof.rb:143](../../src/tools/pprof.rb#L143) (4); hash record hash literal at [src/tools/pprof.rb:120](../../src/tools/pprof.rb#L120) (3)
  - [src/tools/doctor.rb:529](../../src/tools/doctor.rb#L529) site[:runs]; receiver site
  - [src/tools/doctor.rb:529](../../src/tools/doctor.rb#L529) site[:runs]; receiver site
  - [src/tools/doctor.rb:532](../../src/tools/doctor.rb#L532) site[:dispatch]; receiver site
  - [src/tools/doctor.rb:583](../../src/tools/doctor.rb#L583) site[:scheds]; receiver site
  - suggested struct:
    class DispatchRecord < T::Struct
      const :dispatch, T.nilable(String)
      const :exits, Integer
      const :form, T.nilable(String)
      const :id, Integer
      const :max_lifetime_ns, Integer
      const :runs, Integer
      const :scheds, Object
      const :spawns, Integer
      const :total_lifetime_ns, Integer
    end
- FunctionsRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 5
  - common keys: functions, source_file, warnings
  - read keys: warnings(3), functions(2)
  - accounts for: return 0, param 0, ivar 0, collection 5
  - related pressure records: hash record hash literal at [src/tools/stack_verifier.rb:100](../../src/tools/stack_verifier.rb#L100) (5)
  - [src/tools/stack_verifier.rb:125](../../src/tools/stack_verifier.rb#L125) report[:warnings]; receiver report
  - [src/tools/stack_verifier.rb:133](../../src/tools/stack_verifier.rb#L133) report[:warnings]; receiver report
  - [src/tools/stack_verifier.rb:141](../../src/tools/stack_verifier.rb#L141) report[:warnings]; receiver report
  - [src/tools/stack_verifier.rb:151](../../src/tools/stack_verifier.rb#L151) report[:functions]; receiver report
  - suggested struct:
    class FunctionsRecord < T::Struct
      const :functions, T::Array[`T.untyped`]
      const :source_file, T.nilable(String)
      const :warnings, T::Array[`T.untyped`]
    end
- DescriptionRecord: 4 literal shape(s), 1 similar keyset(s), total pressure 4
  - common keys: description, sigil
  - read keys: description(1), sigil(1)
  - accounts for: return 0, param 2, ivar 0, collection 2
  - [src/annotator/helpers/fixable_helpers.rb:988](../../src/annotator/helpers/fixable_helpers.rb#L988) c[:sigil]; receiver c
  - [src/annotator/helpers/fixable_helpers.rb:988](../../src/annotator/helpers/fixable_helpers.rb#L988) c[:description]; receiver c
  - suggested struct:
    class DescriptionRecord < T::Struct
      const :description, String
      const :sigil, String
    end
- NameRecord: 3 literal shape(s), 2 similar keyset(s), total pressure 4
  - common keys: name, value
  - optional keys: alloc
  - read keys: value(1)
  - accounts for: return 0, param 3, ivar 0, collection 1
  - related pressure records: local hash record field at [src/mir/lowering/expressions.rb](../../src/mir/lowering/expressions.rb) (8); hash record param field at [src/mir/mir.rb:670](../../src/mir/mir.rb#L670) (4); hash record param field at [src/mir/mir.rb:662](../../src/mir/mir.rb#L662) (2); hash record param field at [src/mir/mir.rb:678](../../src/mir/mir.rb#L678) (2); hash record return candidate_decl_info at [src/tools/migration_suggester_helpers.rb:64](../../src/tools/migration_suggester_helpers.rb#L64) (2)
  - [src/mir/mir.rb:672](../../src/mir/mir.rb#L672) field[:value]; receiver field
  - suggested struct:
    class NameRecord < T::Struct
      prop :alloc, T.nilable(Symbol)
      const :name, String
      const :value, MIR::Ident
    end
- FilenameIdxRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 4
  - common keys: filename_idx, id, name_idx, start_line, system_name_idx
  - read keys: id(1)
  - accounts for: return 2, param 1, ivar 0, collection 1
  - related pressure records: hash record hash literal at [src/tools/pprof.rb:145](../../src/tools/pprof.rb#L145) (4); hash record return [] at [src/tools/pprof.rb:143](../../src/tools/pprof.rb#L143) (4); hash record hash literal at [src/tools/pprof.rb:120](../../src/tools/pprof.rb#L120) (3)
  - [src/tools/pprof.rb:154](../../src/tools/pprof.rb#L154) f[:id]; receiver f
  - suggested struct:
    class FilenameIdxRecord < T::Struct
      const :filename_idx, Integer
      const :id, Integer
      const :name_idx, Integer
      const :start_line, Integer
      const :system_name_idx, Integer
    end
- IdxRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 4
  - common keys: idx, runs
  - read keys: runs(3), idx(1)
  - accounts for: return 0, param 0, ivar 0, collection 4
  - related pressure records: hash record return must at [src/mir/lowering/variables.rb:1046](../../src/mir/lowering/variables.rb#L1046) (2)
  - [src/tools/doctor.rb:508](../../src/tools/doctor.rb#L508) r[:runs]; receiver r
  - [src/tools/doctor.rb:510](../../src/tools/doctor.rb#L510) r[:runs]; receiver r
  - [src/tools/doctor.rb:512](../../src/tools/doctor.rb#L512) r[:idx]; receiver r
  - [src/tools/doctor.rb:512](../../src/tools/doctor.rb#L512) r[:runs]; receiver r
  - suggested struct:
    class IdxRecord < T::Struct
      const :idx, Integer
      const :runs, Integer
    end
- BgEntriesRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 3
  - common keys: bg_entries, call_graph, fn_addrs, fn_names, frame_sizes
  - read keys: call_graph(1), fn_names(1), frame_sizes(1)
  - accounts for: return 0, param 0, ivar 0, collection 3
  - related pressure records: hash record param graph_data at [src/tools/stack_verifier.rb:338](../../src/tools/stack_verifier.rb#L338) (3); hash record return extract_full_call_graph at [src/tools/stack_verifier.rb:403](../../src/tools/stack_verifier.rb#L403) (2); hash record return extract_full_call_graph at [src/tools/stack_verifier.rb:389](../../src/tools/stack_verifier.rb#L389) (1)
  - [src/tools/stack_verifier.rb:339](../../src/tools/stack_verifier.rb#L339) graph_data[:frame_sizes]; receiver graph_data
  - [src/tools/stack_verifier.rb:340](../../src/tools/stack_verifier.rb#L340) graph_data[:call_graph]; receiver graph_data
  - [src/tools/stack_verifier.rb:341](../../src/tools/stack_verifier.rb#L341) graph_data[:fn_names]; receiver graph_data
  - suggested struct:
    class BgEntriesRecord < T::Struct
      const :bg_entries, `T.untyped`
      const :call_graph, Object
      const :fn_addrs, Object
      const :fn_names, Object
      const :frame_sizes, Object
    end
- BuildIdIdxRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 3
  - common keys: build_id_idx, file_offset, filename_idx, has_filenames, has_functions, has_line_numbers, id, memory_limit, memory_start
  - read keys: id(2)
  - accounts for: return 1, param 0, ivar 0, collection 2
  - related pressure records: hash record param m at [src/tools/pprof.rb:275](../../src/tools/pprof.rb#L275) (16); hash record hash literal at [src/tools/pprof.rb:145](../../src/tools/pprof.rb#L145) (4); hash record return [] at [src/tools/pprof.rb:143](../../src/tools/pprof.rb#L143) (4); hash record hash literal at [src/tools/pprof.rb:120](../../src/tools/pprof.rb#L120) (3)
  - [src/tools/pprof.rb:133](../../src/tools/pprof.rb#L133) mapping[:id]; receiver mapping
  - [src/tools/pprof.rb:134](../../src/tools/pprof.rb#L134) mapping[:id]; receiver mapping
  - suggested struct:
    class BuildIdIdxRecord < T::Struct
      const :build_id_idx, Integer
      const :file_offset, Integer
      const :filename_idx, Integer
      const :has_filenames, T::Boolean
      const :has_functions, T::Boolean
      const :has_line_numbers, T::Boolean
      const :id, Integer
      const :memory_limit, Integer
      const :memory_start, Integer
    end
- ExprRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 1
  - common keys: expr, source
  - read keys: expr(1)
  - accounts for: return 0, param 0, ivar 0, collection 1
  - related pressure records: local hash record entry at [src/annotator/helpers/capabilities.rb](../../src/annotator/helpers/capabilities.rb) (2); local hash record entry at [src/mir/lowering/capabilities.rb](../../src/mir/lowering/capabilities.rb) (2); local hash record entry at [src/mir/lowering/functions.rb](../../src/mir/lowering/functions.rb) (2); hash record return collect_chain at [src/backends/pipeline_rewriter.rb:258](../../src/backends/pipeline_rewriter.rb#L258) (1); local hash record binding at [src/mir/mir.rb](../../src/mir/mir.rb) (1)
  - [src/annotator/helpers/capabilities.rb:574](../../src/annotator/helpers/capabilities.rb#L574) entry[:expr]; receiver entry
  - suggested struct:
    class ExprRecord < T::Struct
      const :expr, `T.untyped`
      const :source, String
    end
- EndRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 1
  - common keys: end, start
  - read keys: end(1)
  - accounts for: return 0, param 0, ivar 0, collection 1
  - related pressure records: local hash record seg at [src/tools/formatter.rb](../../src/tools/formatter.rb) (4); hash record param range at [src/lsp/position.rb:71](../../src/lsp/position.rb#L71) (2)
  - [src/tools/formatter.rb:1820](../../src/tools/formatter.rb#L1820) segments.last[:end]; receiver segments.last
  - suggested struct:
    class EndRecord < T::Struct
      const :end, AST::StructField
      const :start, AST::StructField
    end
- CategoryRecord: 441 literal shape(s), 4 similar keyset(s), total pressure 0
  - common keys: category, severity, summary, template
  - optional keys: cause, fix_hint, pending
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: local hash record entry at [src/ast/diagnostic_registry.rb](../../src/ast/diagnostic_registry.rb) (6); hash record param entry at [src/lsp/hover.rb:91](../../src/lsp/hover.rb#L91) (5); hash record param entry at [src/lsp/hover.rb:132](../../src/lsp/hover.rb#L132) (2); hash record return [] at [src/ast/diagnostic_registry.rb:2803](../../src/ast/diagnostic_registry.rb#L2803) (1); hash record return [] at [src/ast/diagnostic_registry.rb:2812](../../src/ast/diagnostic_registry.rb#L2812) (1)
  - suggested struct:
    class CategoryRecord < T::Struct
      const :category, Symbol
      prop :cause, T.nilable(String)
      prop :fix_hint, T.nilable(String)
      prop :pending, T.nilable(T::Boolean)
      const :severity, Symbol
      const :summary, String
      const :template, String
    end
- ZigRecord: 95 literal shape(s), 12 similar keyset(s), total pressure 0
  - common keys: zig
  - optional keys: args, bc, borrows, can_fail, is_method, lifetime, mutates_receiver, return, return_alloc
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record param h at [src/annotator/helpers/intrinsic_registry.rb:156](../../src/annotator/helpers/intrinsic_registry.rb#L156) (4); local hash record config at [src/annotator/helpers/function_analysis.rb](../../src/annotator/helpers/function_analysis.rb) (3); local hash record definition at [src/annotator/phases/expression_domains.rb](../../src/annotator/phases/expression_domains.rb) (3)
  - suggested struct:
    class ZigRecord < T::Struct
      prop :args, T.nilable(T::Array[`T.untyped`])
      prop :bc, T.nilable(T::Boolean)
      prop :borrows, T.nilable(Symbol)
      prop :can_fail, T.nilable(T::Boolean)
      prop :is_method, T.nilable(T::Boolean)
      prop :lifetime, T.nilable(String)
      prop :mutates_receiver, T.nilable(T::Boolean)
      prop :return, T.nilable(Symbol)
      prop :return_alloc, T.nilable(Symbol)
      const :zig, String
    end
- AlienFactorRecord: 30 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: alien_factor, category, codes, frequency, id, summary, title
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record hash literal at [src/tools/pprof.rb:145](../../src/tools/pprof.rb#L145) (4); hash record return [] at [src/tools/pprof.rb:143](../../src/tools/pprof.rb#L143) (4); hash record hash literal at [src/tools/pprof.rb:120](../../src/tools/pprof.rb#L120) (3); hash record param entry at [src/lsp/hover.rb:132](../../src/lsp/hover.rb#L132) (2); local hash record b at [src/ast/diagnostic_buckets.rb](../../src/ast/diagnostic_buckets.rb) (2)
  - suggested struct:
    class AlienFactorRecord < T::Struct
      const :alien_factor, Symbol
      const :category, Symbol
      const :codes, T::Array[`T.untyped`]
      const :frequency, Integer
      const :id, Symbol
      const :summary, String
      const :title, String
    end
- ZigRecord: 27 literal shape(s), 12 similar keyset(s), total pressure 0
  - common keys: zig
  - optional keys: alloc, allocates, args, bc, bc_op, borrows, can_fail, is_method, return, return_alloc, suspends
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: local hash record config at [src/annotator/helpers/function_analysis.rb](../../src/annotator/helpers/function_analysis.rb) (3); local hash record definition at [src/annotator/phases/expression_domains.rb](../../src/annotator/phases/expression_domains.rb) (3); hash record param field at [src/mir/mir.rb:678](../../src/mir/mir.rb#L678) (2)
  - suggested struct:
    class ZigRecord < T::Struct
      prop :alloc, T.nilable(Symbol)
      prop :allocates, T.nilable(T::Boolean)
      prop :args, T.nilable(T::Array[`T.untyped`])
      prop :bc, T.nilable(T::Boolean)
      prop :bc_op, T.nilable(Symbol)
      prop :borrows, T.nilable(Symbol)
      prop :can_fail, T.nilable(T::Boolean)
      prop :is_method, T.nilable(T::Boolean)
      prop :return, T.nilable(Symbol)
      prop :return_alloc, T.nilable(Symbol)
      prop :suspends, T.nilable(T::Boolean)
      const :zig, String
    end
- BcRecord: 20 literal shape(s), 8 similar keyset(s), total pressure 0
  - common keys: bc, borrows, zig
  - optional keys: alloc, allocates, arity, is_method, mutates_receiver, numeric_zig, return_type, sharded_alloc, sharded_zig, tag, validate
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record param h at [src/annotator/helpers/intrinsic_registry.rb:156](../../src/annotator/helpers/intrinsic_registry.rb#L156) (4); hash record param field at [src/mir/mir.rb:678](../../src/mir/mir.rb#L678) (2)
  - suggested struct:
    class BcRecord < T::Struct
      prop :alloc, T.nilable(Symbol)
      prop :allocates, T.nilable(T::Boolean)
      prop :arity, T.nilable(Integer)
      const :bc, T::Boolean
      const :borrows, Symbol
      prop :is_method, T.nilable(T::Boolean)
      prop :mutates_receiver, T.nilable(T::Boolean)
      prop :numeric_zig, T.nilable(String)
      prop :return_type, T.nilable(Symbol)
      prop :sharded_alloc, T.nilable(Symbol)
      prop :sharded_zig, T.nilable(String)
      prop :tag, T.nilable(Symbol)
      prop :validate, `T.untyped`
      const :zig, String
    end
- AltsRecord: 13 literal shape(s), 2 similar keyset(s), total pressure 0
  - common keys: alts, default
  - optional keys: notes
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record return [] at [src/annotator/helpers/fixable_helpers.rb:1393](../../src/annotator/helpers/fixable_helpers.rb#L1393) (5); hash record return [] at [src/annotator/helpers/fixable_helpers.rb:1401](../../src/annotator/helpers/fixable_helpers.rb#L1401) (1)
  - suggested struct:
    class AltsRecord < T::Struct
      const :alts, T::Array[`T.untyped`]
      const :default, Symbol
      prop :notes, T.nilable(Object)
    end
- FirstSiteRecord: 11 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: first_site, id, kind, zig_name
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record hash literal at [src/tools/pprof.rb:145](../../src/tools/pprof.rb#L145) (4); hash record return [] at [src/tools/pprof.rb:143](../../src/tools/pprof.rb#L143) (4); hash record hash literal at [src/tools/pprof.rb:120](../../src/tools/pprof.rb#L120) (3); hash record return [] at [src/ast/error_registry.rb:127](../../src/ast/error_registry.rb#L127) (3); local hash record meta at [src/ast/error_registry.rb](../../src/ast/error_registry.rb) (2)
  - suggested struct:
    class FirstSiteRecord < T::Struct
      const :first_site, NilClass
      const :id, Integer
      const :kind, Symbol
      const :zig_name, String
    end
- DimRecord: 9 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: dim, val
  - accounts for: return 0, param 0, ivar 0, collection 0
  - suggested struct:
    class DimRecord < T::Struct
      const :dim, Symbol
      const :val, Symbol
    end
- AssocRecord: 7 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: assoc, ops
  - accounts for: return 0, param 0, ivar 0, collection 0
  - suggested struct:
    class AssocRecord < T::Struct
      const :assoc, Symbol
      const :ops, T::Array[`T.untyped`]
    end
- CharacterRecord: 6 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: character, line
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record param position at [src/lsp/hover.rb:63](../../src/lsp/hover.rb#L63) (4); hash record param position at [src/lsp/position.rb:71](../../src/lsp/position.rb#L71) (4); hash record return [] at [src/lsp/code_actions.rb:106](../../src/lsp/code_actions.rb#L106) (4); hash record return [] at [src/lsp/position.rb:73](../../src/lsp/position.rb#L73) (2); hash record return [] at [src/lsp/position.rb:74](../../src/lsp/position.rb#L74) (2)
  - suggested struct:
    class CharacterRecord < T::Struct
      const :character, Integer
      const :line, Integer
    end
- GetRecord: 6 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: get, set
  - accounts for: return 0, param 0, ivar 0, collection 0
  - suggested struct:
    class GetRecord < T::Struct
      const :bc, T::Boolean
      const :bc_op, Symbol
      const :container_borrow, T::Boolean
      const :return_type, Symbol
      const :shard_direct_zig, String
      const :sharded_zig, String
      const :zig, String
    end

    class SetRecord < T::Struct
      const :alloc, Symbol
      const :allocates, T::Boolean
      const :bc, T::Boolean
      const :bc_op, Symbol
      const :key_alloc, Symbol
      const :shard_alloc, Symbol
      const :shard_direct_zig, String
      const :sharded_zig, String
      const :takes_value, T::Boolean
      const :val_alloc, Symbol
      const :zig, String
    end

    class GetRecord < T::Struct
      const :get, GetRecord
      const :set, SetRecord
    end
- SyncRecord: 6 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: sync, type
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record return [] at [src/annotator/helpers/function_analysis.rb:1312](../../src/annotator/helpers/function_analysis.rb#L1312) (7); hash record param v at [src/annotator/helpers/intrinsic_registry.rb:103](../../src/annotator/helpers/intrinsic_registry.rb#L103) (6); hash record return [] at [src/annotator/helpers/generic_analysis.rb:311](../../src/annotator/helpers/generic_analysis.rb#L311) (2); hash record return [] at [src/annotator/helpers/union.rb:75](../../src/annotator/helpers/union.rb#L75) (2); local hash record a at [src/annotator/helpers/function_analysis.rb](../../src/annotator/helpers/function_analysis.rb) (1)
  - suggested struct:
    class SyncRecord < T::Struct
      const :sync, Symbol
      const :type, Symbol
    end

### Weak Collection Slots With Runtime Candidates
- [src/annotator/helpers/fixable_helpers.rb:108](../../src/annotator/helpers/fixable_helpers.rb#L108) `FixableHelper#emit_registry_mismatch!` param candidates: T::Array[`T.untyped`] -> T::Array[Symbol] (12 call(s))
- [src/annotator/helpers/fixable_helpers.rb:381](../../src/annotator/helpers/fixable_helpers.rb#L381) `FixableHelper#emit_use_of_moved_path_error!` param path: T::Array[`T.untyped`] -> T::Array[Symbol] (4 call(s))
- [src/annotator/helpers/fixable_helpers.rb:1386](../../src/annotator/helpers/fixable_helpers.rb#L1386) `FixableHelper#auto_rank_candidates` return return: T::Array[T::Array[`T.untyped`]] -> T::Array[T::Array[T.nilable(T.any(String, Symbol))]] (22 call(s))
- [src/annotator/helpers/fixable_helpers.rb:1442](../../src/annotator/helpers/fixable_helpers.rb#L1442) `FixableHelper#build_auto_op_evidence_block` param candidates: T::Array[`T.untyped`] -> T::Array[T::Array[T.nilable(T.any(String, Symbol))]] (4 call(s))
- [src/annotator/helpers/fixable_helpers.rb:1517](../../src/annotator/helpers/fixable_helpers.rb#L1517) `FixableHelper#build_auto_replace_fixes` return return: T::Array[`T.untyped`] -> T::Array[Fix] (20 call(s))
- [src/annotator/helpers/fixable_helpers.rb:1682](../../src/annotator/helpers/fixable_helpers.rb#L1682) `FixableHelper#build_auto_ambiguity_message` param observed_strs: T::Array[`T.untyped`] -> T::Array[String] (5 call(s))
- [src/annotator/helpers/function_analysis.rb:1299](../../src/annotator/helpers/function_analysis.rb#L1299) `FunctionAnalysis#find_matching_intrinsic` param definitions: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (8717 call(s))
- [src/annotator/helpers/function_analysis.rb:1349](../../src/annotator/helpers/function_analysis.rb#L1349) `FunctionAnalysis#format_intrinsic_args` param args: T::Array[`T.untyped`] -> T::Array[Symbol] (12 call(s))
- [src/annotator/helpers/generic_analysis.rb:287](../../src/annotator/helpers/generic_analysis.rb#L287) `GenericAnalysis#infer_generic_type_args!` return return: T.nilable(T::Hash[Symbol, `T.untyped`]) -> T::Hash[Symbol, Type] (65 call(s))
- [src/annotator/helpers/generic_analysis.rb:338](../../src/annotator/helpers/generic_analysis.rb#L338) `GenericAnalysis#extract_type_bindings!` param subst: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, Type] (104 call(s))
- ... and 40 more (run with `--full` to see all)

### Weak Collection Slots Without Candidate
- [src/annotator/domains/errors.rb:350](../../src/annotator/domains/errors.rb#L350) `Annotator::Domains::Errors#emit_error_type_conflict!` param conflict: T::Hash[Symbol, `T.untyped`]; key observations Symbol; value observations FalseClass, Lexer::Token, NilClass, Symbol
- [src/annotator/helpers/auto_inference.rb:720](../../src/annotator/helpers/auto_inference.rb#L720) `ShapeEvidenceCollector#collect_in_function` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Assignment, AST::BindExpr, AST::MethodCall, AST::ReturnNode, AST::VarDecl
- [src/annotator/helpers/auto_inference.rb:790](../../src/annotator/helpers/auto_inference.rb#L790) `ShapeEvidenceCollector#record_method_call` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- [src/annotator/helpers/auto_inference.rb:808](../../src/annotator/helpers/auto_inference.rb#L808) `ShapeEvidenceCollector#record_map_pair_evidence` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Literal
- [src/annotator/helpers/auto_inference.rb:808](../../src/annotator/helpers/auto_inference.rb#L808) `ShapeEvidenceCollector#record_map_pair_evidence` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- [src/annotator/helpers/auto_inference.rb:817](../../src/annotator/helpers/auto_inference.rb#L817) `ShapeEvidenceCollector#record_index_assign` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- [src/annotator/helpers/auto_inference.rb:872](../../src/annotator/helpers/auto_inference.rb#L872) `OperatorEvidenceCollector#collect_in_function` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BindExpr, AST::MethodCall, AST::ReturnNode, AST::VarDecl
- [src/annotator/helpers/auto_inference.rb:946](../../src/annotator/helpers/auto_inference.rb#L946) `OperatorEvidenceCollector#record_binop` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::Identifier, AST::Literal
- [src/annotator/helpers/effects.rb:250](../../src/annotator/helpers/effects.rb#L250) `EffectTracker#compute_effects!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- [src/annotator/helpers/effects.rb:466](../../src/annotator/helpers/effects.rb#L466) `EffectTracker#compute_can_fail!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- ... and 21 more (run with `--full` to see all)

### Collection Blocker Pressure
- method_return expression_children array at [src/ast/ast.rb:679](../../src/ast/ast.rb#L679); element observations are heterogeneous or AST/MIR-specific: AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, AST::BgStreamBlock: 1 slot(s), 374039 observation(s)
  - [src/ast/ast.rb:679](../../src/ast/ast.rb#L679) `AST#expression_children` return return: T::Array[`T.untyped`]
- method_return normalize_allocating_mir_stmt! array at [src/mir/hoist.rb:800](../../src/mir/hoist.rb#L800); element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::Cleanup, MIR::ErrCleanup, MIR::Let: 1 slot(s), 287452 observation(s)
  - [src/mir/hoist.rb:800](../../src/mir/hoist.rb#L800) `MIRHoistLowering#normalize_allocating_mir_stmt!` return return: T::Array[`T.untyped`]
- method_return normalize_stmt_child_exprs! array at [src/mir/hoist.rb:869](../../src/mir/hoist.rb#L869); no element observations: 1 slot(s), 201827 observation(s)
  - [src/mir/hoist.rb:869](../../src/mir/hoist.rb#L869) `MIRHoistLowering#normalize_stmt_child_exprs!` return return: T::Array[`T.untyped`]
- [src/ast/ast.rb:744](../../src/ast/ast.rb#L744) `AST#_expr_each_bg_block_recursive` return return; no element observations: 1 slot(s), 155350 observation(s)
  - [src/ast/ast.rb:744](../../src/ast/ast.rb#L744) `AST#_expr_each_bg_block_recursive` return return: T.nilable(T::Array[`T.untyped`])
- [src/mir/mir_checker.rb:2738](../../src/mir/mir_checker.rb#L2738) `MIRChecker#check_stmt_for_unhoisted` return return; no element observations: 1 slot(s), 122106 observation(s)
  - [src/mir/mir_checker.rb:2738](../../src/mir/mir_checker.rb#L2738) `MIRChecker#check_stmt_for_unhoisted` return return: T.nilable(T::Array[`T.untyped`])
- [src/mir/mir_checker.rb:2806](../../src/mir/mir_checker.rb#L2806) `MIRChecker#check_expr_sources_for_unhoisted` return return; no element observations: 1 slot(s), 97892 observation(s)
  - [src/mir/mir_checker.rb:2806](../../src/mir/mir_checker.rb#L2806) `MIRChecker#check_expr_sources_for_unhoisted` return return: T.nilable(T::Array[`T.untyped`])
- method_return normalize_allocating_result_expr! array at [src/mir/hoist.rb:908](../../src/mir/hoist.rb#L908); element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::Cleanup, MIR::ErrCleanup, MIR::Let: 1 slot(s), 94369 observation(s)
  - [src/mir/hoist.rb:908](../../src/mir/hoist.rb#L908) `MIRHoistLowering#normalize_allocating_result_expr!` return return: T::Array[`T.untyped`]
- method_param body array at [src/mir/hoist.rb:789](../../src/mir/hoist.rb#L789); element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush, MIR::BinOp, MIR::BlockExpr: 1 slot(s), 52841 observation(s)
  - [src/mir/hoist.rb:789](../../src/mir/hoist.rb#L789) `MIRHoistLowering#normalize_allocating_mir_body` param body: T::Array[`T.untyped`]
- method_return normalize_allocating_mir_body array at [src/mir/hoist.rb:789](../../src/mir/hoist.rb#L789); element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush, MIR::BinOp, MIR::BlockExpr: 1 slot(s), 52841 observation(s)
  - [src/mir/hoist.rb:789](../../src/mir/hoist.rb#L789) `MIRHoistLowering#normalize_allocating_mir_body` return return: T::Array[`T.untyped`]
- method_return each_bg_block array at [src/ast/ast.rb:719](../../src/ast/ast.rb#L719); element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 38202 observation(s)
  - [src/ast/ast.rb:719](../../src/ast/ast.rb#L719) `AST#each_bg_block` return return: T.nilable(T::Array[`T.untyped`])
- ... and 20 more (run with `--full` to see all)

### Runtime Collection Mutation Observations
- ivar: 97748 slot(s)
- method_param: 76215 slot(s)
- method_return: 62439 slot(s)
- struct_field: 27818 slot(s)
  - [src/ast/lexer.rb:42](../../src/ast/lexer.rb#L42) ivar @tokens; array; T::Array[Lexer::Token]; 673666 observation(s)
  - [src/tools/lint_fix_rewriter.rb:68](../../src/tools/lint_fix_rewriter.rb#L68) method_param set; set; T::Set[String]; 574760 observation(s)
  - [src/tools/lint_fix_rewriter.rb:89](../../src/tools/lint_fix_rewriter.rb#L89) method_param set; set; T::Set[String]; 574497 observation(s)
  - [src/tools/lint_fix_rewriter.rb:199](../../src/tools/lint_fix_rewriter.rb#L199) method_param edits; array; T::Array[Hash]; 573862 observation(s)
  - [src/tools/predicate_rewriter.rb:116](../../src/tools/predicate_rewriter.rb#L116) method_param edits; array; T::Array[PredicateRewriter::Edit]; 573056 observation(s)
  - [src/tools/method_rewriter.rb:140](../../src/tools/method_rewriter.rb#L140) method_param edits; array; T::Array[Hash]; 572427 observation(s)
  - [src/tools/method_rewriter.rb:140](../../src/tools/method_rewriter.rb#L140) method_param methods; set; T::Set[String]; 572272 observation(s)
  - [src/tools/method_rewriter.rb:65](../../src/tools/method_rewriter.rb#L65) method_param fns; set; T::Set[String]; 527434 observation(s)
  - [src/tools/method_rewriter.rb:65](../../src/tools/method_rewriter.rb#L65) method_param methods; set; T::Set[`T.untyped`]; 525432 observation(s)
  - [src/tools/formatter.rb:155](../../src/tools/formatter.rb#L155) ivar @out; array; T::Array[Formatter::FormatLexer::Token]; 309169 observation(s)
  - [src/ast/scope.rb:28](../../src/ast/scope.rb#L28) method_return initialize; hash; T::Hash[String, SymbolEntry]; 181435 observation(s)
  - [src/ast/scope.rb:35](../../src/ast/scope.rb#L35) ivar @entries; hash; T::Hash[String, SymbolEntry]; 181435 observation(s)
  - [src/ast/scope.rb:144](../../src/ast/scope.rb#L144) ivar @owned_names; set; T::Set[String]; 174888 observation(s)
  - [src/ast/symbol_entry.rb:579](../../src/ast/symbol_entry.rb#L579) ivar @capabilities; set; T::Set[`T.untyped`]; 170597 observation(s)
  - [src/ast/symbol_entry.rb:580](../../src/ast/symbol_entry.rb#L580) ivar @lifetime; array; T::Array[`T.untyped`]; 170597 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param seen; hash; T::Hash[Integer, TrueClass]; 90127 observation(s)
  - [src/ast/lexer.rb:42](../../src/ast/lexer.rb#L42) ivar @tokens; array; T::Array[Lexer::Token]; 84913 observation(s)
  - [src/ast/scope.rb:28](../../src/ast/scope.rb#L28) method_return initialize; hash; T::Hash[String, SymbolEntry]; 77427 observation(s)
  - [src/ast/scope.rb:35](../../src/ast/scope.rb#L35) ivar @entries; hash; T::Hash[String, SymbolEntry]; 77427 observation(s)
  - [src/ast/scope.rb:144](../../src/ast/scope.rb#L144) ivar @owned_names; set; T::Set[String]; 74790 observation(s)
  - [src/tools/lint_fix_rewriter.rb:213](../../src/tools/lint_fix_rewriter.rb#L213) method_param n; array; T::Array[`T.untyped`]; 73248 observation(s)
  - [src/ast/symbol_entry.rb:579](../../src/ast/symbol_entry.rb#L579) ivar @capabilities; set; T::Set[`T.untyped`]; 73238 observation(s)
  - [src/ast/symbol_entry.rb:580](../../src/ast/symbol_entry.rb#L580) ivar @lifetime; array; T::Array[`T.untyped`]; 73238 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param violations; array; T::Array[`T.untyped`]; 69823 observation(s)
  - [src/ast/scope.rb:28](../../src/ast/scope.rb#L28) method_return initialize; hash; T::Hash[String, SymbolEntry]; 53016 observation(s)
  - [src/ast/scope.rb:35](../../src/ast/scope.rb#L35) ivar @entries; hash; T::Hash[String, SymbolEntry]; 53016 observation(s)
  - [src/ast/scope.rb:144](../../src/ast/scope.rb#L144) ivar @owned_names; set; T::Set[String]; 52891 observation(s)
  - [src/tools/formatter.rb:2632](../../src/tools/formatter.rb#L2632) ivar @generic_bracket_indices; set; T::Set[Integer]; 52610 observation(s)
  - [src/tools/formatter.rb:2633](../../src/tools/formatter.rb#L2633) ivar @struct_lit_brace_indices; set; T::Set[Integer]; 52610 observation(s)
  - [src/ast/symbol_entry.rb:579](../../src/ast/symbol_entry.rb#L579) ivar @capabilities; set; T::Set[`T.untyped`]; 51431 observation(s)
  - [src/ast/symbol_entry.rb:580](../../src/ast/symbol_entry.rb#L580) ivar @lifetime; array; T::Array[`T.untyped`]; 51431 observation(s)
  - [src/ast/parser.rb:3937](../../src/ast/parser.rb#L3937) method_return parse_comma_seq; array; T::Array[`T.untyped`]; 42604 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param seen; hash; T::Hash[Integer, TrueClass]; 37486 observation(s)
  - [src/ast/ast.rb:679](../../src/ast/ast.rb#L679) method_return expression_children; array; T::Array[`T.untyped`]; 35842 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param seen; hash; T::Hash[Integer, TrueClass]; 34890 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param seen; hash; T::Hash[Integer, TrueClass]; 32348 observation(s)
  - [src/ast/ast.rb:679](../../src/ast/ast.rb#L679) method_return expression_children; array; T::Array[`T.untyped`]; 30286 observation(s)
  - [src/ast/lexer.rb:42](../../src/ast/lexer.rb#L42) ivar @tokens; array; T::Array[Lexer::Token]; 29831 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param violations; array; T::Array[`T.untyped`]; 28548 observation(s)
  - [src/mir/pre_mir_type_check.rb:71](../../src/mir/pre_mir_type_check.rb#L71) method_param violations; array; T::Array[`T.untyped`]; 26572 observation(s)

### Collection Index Lookup Provenance
- provenance: the inferred origin of the collection receiver being indexed with `[]`, `fetch`, or similar lookup syntax
- receiver origin: the parameter, literal, forwarded return, instance variable, or local record that produced the indexed receiver
- weak index lookup: an index lookup where the receiver is unknown, `T.untyped`, or a weak collection type
- unknown receiver type: 1239
- weak collection receiver: 333
- typed collection receiver: 229
- typed lookup: 214
- non-collection or unresolved receiver: 196

### Unknown Or Weak Index Lookups By Receiver Origin
- local hash record self at [src/ast/ast.rb](../../src/ast/ast.rb): 86
  - [src/ast/ast.rb:119](../../src/ast/ast.rb#L119) self[:type]; receiver self; index :type; receiver type unknown
  - [src/ast/ast.rb:130](../../src/ast/ast.rb#L130) self[:type]; receiver self; index :type; receiver type unknown
  - [src/ast/ast.rb:148](../../src/ast/ast.rb#L148) self[:mutable]; receiver self; index :mutable; receiver type unknown
  - [src/ast/ast.rb:149](../../src/ast/ast.rb#L149) self[:takes]; receiver self; index :takes; receiver type unknown
  - [src/ast/ast.rb:150](../../src/ast/ast.rb#L150) self[:comptime]; receiver self; index :comptime; receiver type unknown
- local hash record c at [src/tools/doctor.rb](../../src/tools/doctor.rb): 74
  - [src/tools/doctor.rb:394](../../src/tools/doctor.rb#L394) c[:pushes]; receiver c; index :pushes; receiver type unknown
  - [src/tools/doctor.rb:394](../../src/tools/doctor.rb#L394) c[:pops]; receiver c; index :pops; receiver type unknown
  - [src/tools/doctor.rb:403](../../src/tools/doctor.rb#L403) c[:capacity]; receiver c; index :capacity; receiver type unknown
  - [src/tools/doctor.rb:404](../../src/tools/doctor.rb#L404) c[:max_depth]; receiver c; index :max_depth; receiver type unknown
  - [src/tools/doctor.rb:405](../../src/tools/doctor.rb#L405) c[:pushes]; receiver c; index :pushes; receiver type unknown
- local hash record s at [src/tools/doctor.rb](../../src/tools/doctor.rb): 57
  - [src/tools/doctor.rb:165](../../src/tools/doctor.rb#L165) s[:trace]; receiver s; index :trace; receiver type unknown
  - [src/tools/doctor.rb:210](../../src/tools/doctor.rb#L210) s[:trace]; receiver s; index :trace; receiver type unknown
  - [src/tools/doctor.rb:214](../../src/tools/doctor.rb#L214) s[:bytes]; receiver s; index :bytes; receiver type unknown
  - [src/tools/doctor.rb:215](../../src/tools/doctor.rb#L215) s[:allocs]; receiver s; index :allocs; receiver type unknown
  - [src/tools/doctor.rb:226](../../src/tools/doctor.rb#L226) s[:trace]; receiver s; index :trace; receiver type unknown
- local hash record d at [src/tools/doctor.rb](../../src/tools/doctor.rb): 44
  - [src/tools/doctor.rb:1478](../../src/tools/doctor.rb#L1478) d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - [src/tools/doctor.rb:1478](../../src/tools/doctor.rb#L1478) d[:delta_allocs]; receiver d; index :delta_allocs; receiver type unknown
  - [src/tools/doctor.rb:1479](../../src/tools/doctor.rb#L1479) d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - [src/tools/doctor.rb:1487](../../src/tools/doctor.rb#L1487) d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - [src/tools/doctor.rb:1489](../../src/tools/doctor.rb#L1489) d[:func]; receiver d; index :func; receiver type unknown
- local variable f: 26
  - [src/tools/pprof_converter.rb:115](../../src/tools/pprof_converter.rb#L115) f[0]; receiver f; index 0; receiver type unknown
  - [src/tools/pprof_converter.rb:118](../../src/tools/pprof_converter.rb#L118) f[1]; receiver f; index 1; receiver type unknown
  - [src/tools/pprof_converter.rb:119](../../src/tools/pprof_converter.rb#L119) f[2]; receiver f; index 2; receiver type unknown
  - [src/tools/pprof_converter.rb:120](../../src/tools/pprof_converter.rb#L120) f[3]; receiver f; index 3; receiver type unknown
  - [src/tools/pprof_converter.rb:121](../../src/tools/pprof_converter.rb#L121) f[4]; receiver f; index 4; receiver type unknown
- hash record return cast at [src/mir/fsm_transform.rb:136](../../src/mir/fsm_transform.rb#L136): 24
  - [src/mir/fsm_transform.rb:138](../../src/mir/fsm_transform.rb#L138) raw_ctx.fetch(:id); receiver raw_ctx; index :id; receiver type unknown
  - [src/mir/fsm_transform.rb:139](../../src/mir/fsm_transform.rb#L139) raw_ctx.fetch(:bg_rt); receiver raw_ctx; index :bg_rt; receiver type unknown
  - [src/mir/fsm_transform.rb:140](../../src/mir/fsm_transform.rb#L140) raw_ctx.fetch(:blk_label); receiver raw_ctx; index :blk_label; receiver type unknown
  - [src/mir/fsm_transform.rb:141](../../src/mir/fsm_transform.rb#L141) raw_ctx.fetch(:ctx_type); receiver raw_ctx; index :ctx_type; receiver type unknown
  - [src/mir/fsm_transform.rb:142](../../src/mir/fsm_transform.rb#L142) raw_ctx.fetch(:promise_zig); receiver raw_ctx; index :promise_zig; receiver type unknown
- local hash record r at [src/tools/doctor.rb](../../src/tools/doctor.rb): 24
  - [src/tools/doctor.rb:507](../../src/tools/doctor.rb#L507) r[:runs]; receiver r; index :runs; receiver type unknown
  - [src/tools/doctor.rb:508](../../src/tools/doctor.rb#L508) r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - [src/tools/doctor.rb:510](../../src/tools/doctor.rb#L510) r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - [src/tools/doctor.rb:512](../../src/tools/doctor.rb#L512) r[:idx]; receiver r; index :idx; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - [src/tools/doctor.rb:512](../../src/tools/doctor.rb#L512) r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record f at [src/tools/stack_verifier.rb](../../src/tools/stack_verifier.rb): 21
  - [src/tools/stack_verifier.rb:103](../../src/tools/stack_verifier.rb#L103) f[:name]; receiver f; index :name; receiver type unknown
  - [src/tools/stack_verifier.rb:103](../../src/tools/stack_verifier.rb#L103) f[:stack_bytes]; receiver f; index :stack_bytes; receiver type unknown
  - [src/tools/stack_verifier.rb:105](../../src/tools/stack_verifier.rb#L105) f[:name]; receiver f; index :name; receiver type unknown
  - [src/tools/stack_verifier.rb:121](../../src/tools/stack_verifier.rb#L121) f[:stack_bytes]; receiver f; index :stack_bytes; receiver type unknown
  - [src/tools/stack_verifier.rb:127](../../src/tools/stack_verifier.rb#L127) f[:name]; receiver f; index :name; receiver type unknown
- hash record return options at [src/annotator/helpers/pipe_analysis.rb:427](../../src/annotator/helpers/pipe_analysis.rb#L427): 16
  - [src/annotator/helpers/pipe_analysis.rb:440](../../src/annotator/helpers/pipe_analysis.rb#L440) opts["size"]; receiver opts; index "size"; receiver type unknown
  - [src/annotator/helpers/pipe_analysis.rb:441](../../src/annotator/helpers/pipe_analysis.rb#L441) opts["size"]; receiver opts; index "size"; receiver type unknown
  - [src/annotator/helpers/pipe_analysis.rb:442](../../src/annotator/helpers/pipe_analysis.rb#L442) opts["size"]; receiver opts; index "size"; receiver type unknown
  - [src/annotator/helpers/pipe_analysis.rb:444](../../src/annotator/helpers/pipe_analysis.rb#L444) opts["size"]; receiver opts; index "size"; receiver type unknown
  - [src/annotator/helpers/pipe_analysis.rb:446](../../src/annotator/helpers/pipe_analysis.rb#L446) opts["size"]; receiver opts; index "size"; receiver type unknown
- local hash record c at [src/tools/pprof_converter.rb](../../src/tools/pprof_converter.rb): 16
  - [src/tools/pprof_converter.rb:68](../../src/tools/pprof_converter.rb#L68) c[:pushes]; receiver c; index :pushes; receiver type unknown
  - [src/tools/pprof_converter.rb:68](../../src/tools/pprof_converter.rb#L68) c[:pops]; receiver c; index :pops; receiver type unknown
  - [src/tools/pprof_converter.rb:272](../../src/tools/pprof_converter.rb#L272) c[:reads]; receiver c; index :reads; receiver type unknown
  - [src/tools/pprof_converter.rb:272](../../src/tools/pprof_converter.rb#L272) c[:commits]; receiver c; index :commits; receiver type unknown
  - [src/tools/pprof_converter.rb:275](../../src/tools/pprof_converter.rb#L275) c[:addr]; receiver c; index :addr; receiver type unknown
- ... and 30 more (run with `--full` to see all)

## Tuple-Like Array Report
- tuple-like array: an array literal whose position-specific element types look meaningful enough to model as a tuple/record
- confidence: `high` means the static shape is regular enough for a likely-safe tuple type; `review` means the shape is useful but needs human inspection
- Tuple-like array literals: 274
- Runtime-observed tuple-like array slots: 327

### Runtime Tuple-Like Array Slots
- [src/ast/parser.rb:3937](../../src/ast/parser.rb#L3937) return parse_comma_seq; [Lexer::Token, Array]; 42604 call(s); complete, mixed, size 2
- [src/ast/parser.rb:496](../../src/ast/parser.rb#L496) param pattern; [String, Symbol, Hash, String]; 15944 call(s); complete, mixed, size 4
- [src/tools/lint_fix_rewriter.rb:199](../../src/tools/lint_fix_rewriter.rb#L199) param edits; [Hash, Hash]; 15094 call(s); complete, size 2
- [src/ast/parser.rb:496](../../src/ast/parser.rb#L496) return process_pattern; [AST::BinaryOp, String]; 13237 call(s); complete, mixed, size 2
- [src/tools/lint_fix_rewriter.rb:199](../../src/tools/lint_fix_rewriter.rb#L199) param edits; [Hash, Hash, Hash]; 10059 call(s); complete, size 3
- [src/ast/parser.rb:1652](../../src/ast/parser.rb#L1652) return parse_effects_decl; [NilClass, NilClass]; 7875 call(s); complete, size 2
- [src/tools/lint_fix_rewriter.rb:199](../../src/tools/lint_fix_rewriter.rb#L199) param edits; [Hash, Hash, Hash, Hash]; 6700 call(s); complete, size 4
- [src/mir/hoist.rb:976](../../src/mir/hoist.rb#L976) return normalize_allocating_used_expr; [Array, MIR::Lit]; 5838 call(s); complete, mixed, size 2
- [src/ast/parser.rb:3937](../../src/ast/parser.rb#L3937) return parse_comma_seq; [Lexer::Token, Array]; 5248 call(s); complete, mixed, size 2
- [src/mir/hoist.rb:976](../../src/mir/hoist.rb#L976) return normalize_allocating_used_expr; [Array, MIR::Ident]; 5075 call(s); complete, mixed, size 2
- ... and 70 more (run with `--full` to see all)

## Run Summary
- Target dirs: src
- Methods indexed: 5325
- Runtime-observed methods: 855
- Missing sigs: 91
- Existing sigs: 5234
- Existing/candidate `T.let` sites: 1158
- Sorbet errors captured: 1
