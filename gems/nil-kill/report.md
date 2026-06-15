# Nil Kill Report

- Target dirs: src
- Methods indexed: 5505
- Runtime-observed methods: 5245
- Missing sigs: 91
- Existing sigs: 5414
- Existing/candidate `T.let` sites: 1169
- Sorbet errors captured: 0

## Project Prioritization
- [Nil Source Fixes (161)](#nil-source-fixes-161): 158 action item(s), 161 `T.nilable` slot(s); top source affects 2 slot(s), 1326 source calls
- [Union / `T.any` Candidates (440)](#union-tany-candidates-440): 413 action item(s), 440 union slot(s); top source affects 3 slot(s), 0 source calls
- [Hash Record Struct Candidates (Shapes + Pressure)](#hash-record-struct-candidates-shapes-pressure): 157 struct candidate(s), 186 pressure record(s); top candidate AddrsRecord has pressure 18; 53 pressure record(s) without a literal shape cluster
- [Fallibility Pressure (422)](#fallibility-pressure-422): 422 material fallibility root(s), 425 total, 3 low-tail hidden; top root (top-level)# participates in 0 handler(s) and leaks to 0 caller(s)

## Hygiene Overview

### Type Soundness

| Slot category | Total | Strong | Weak | Untyped | Nilable |
|---|---|---|---|---|---|
| Param inputs | 6624 | 5801 (87.6%) | 168 (2.5%) | 655 (9.9%) | 770 (11.6%) |
| Returns | 3877 | 3673 (94.7%) | 35 (0.9%) | 169 (4.4%) | 765 (19.7%) |
| Struct/class fields & ivars | 1564 | 774 (49.5%) | 21 (1.3%) | 769 (49.2%) | 165 (10.5%) |
| Arrays/Sets/Hashmaps | 2173 | 1869 (86.0%) | 304 (14.0%) | 0 (0.0%) | 37 (1.7%) |

Total = Strong + Weak + Untyped. Nilable is a cross-cut sub-count (a `T.nilable(String)` slot is Strong and Nilable, not a fourth bucket). Collection-typed slots (`T::Array[...]` etc.) are counted only in the Arrays/Sets/Hashmaps row, so the four categories are mutually exclusive. The Param/Returns/Struct Untyped columns equal the per-row denominators in the Untyped Cause Breakdown below.

### Untyped Cause Breakdown

| Slot category | Refused/Pending | PropagationGap | WeakEvidence | Heterogeneous | NoEvidence |
|---|---|---|---|---|---|
| Param inputs (655 untyped) | 186 (28.4%) | 129 (19.7%) | 87 (13.3%) | 198 (30.2%) | 55 (8.4%) |
| Returns (169 untyped) | 49 (29.0%) | 9 (5.3%) | 48 (28.4%) | 58 (34.3%) | 5 (3.0%) |
| Struct/class fields & ivars (769 untyped) | 415 (54.0%) | 133 (17.3%) | 16 (2.1%) | 47 (6.1%) | 158 (20.5%) |
| Arrays/Sets/Hashmaps (261 untyped) | 51 (19.5%) | 16 (6.1%) | 29 (11.1%) | 100 (38.3%) | 65 (24.9%) |

- **Refused/Pending**: type IS determinable from local evidence (single observed runtime type, void/unused, boolean pair) -- untyped only because the fix is unapplied or conservatively refused
- **PropagationGap**: type is determinable elsewhere but needs cross-method/whole-program flow (forwarded return, ivar-from-param capture, callee untyped-but-resolvable, coherent collection needing the typed-collection rewrite)
- **WeakEvidence**: a type is known but only weakly (T::Array[`T.untyped`], a union wider than policy) -- the weak-collection / union-policy axis
- **Heterogeneous**: slot legitimately holds many unrelated types/shapes (AST/MIR node grab-bags, dynamic dispatch) -- `T.untyped` is the correct type
- **NoEvidence**: never observed at runtime AND no static expression/callsite to infer from -- needs a test or a hand-written sig

Actionable by more nil-kill work: PropagationGap (and the policy half of WeakEvidence). Inherent (correct `T.untyped` or needs human/tests): Heterogeneous + NoEvidence. Refused/Pending is resolvable today but unapplied or conservatively declined.

### Union Decomplexity
- Each entry is a canonical origin contract (an accessor like `.type_info`, a hash key like `[:type]`, an ivar, a call) and the TOTAL `is_a?(Type)` guards that collapse if that one contract is given a concrete type. Guards are aggregated across every method that reads the contract. Producer types come from runtime evidence for that contract; `unattributed` = no runtime trace yet for it.
- 20 guards collapse | `.type` (accessor) across 17 method(s) -> via @type assignments (runtime) {Symbol, Type, NilClass, T.nilable(Type)}: tighten that contract
  - methods: `MIRLoweringFunctions#lower_lambda`, `MethodAnalysis#narrow_collection_type!`, `Annotator::Domains::ControlFlow#annotate_struct_pattern!`, `Annotator::Domains::ControlFlow#loop_value_copyable?`, `AutoUnifier#stamp_map_pairs!`, `EscapeAnalysis#mark_param_receiver_allocations_heap!`, +11 more
  - guards at: src/mir/lowering/functions.rb:2001, src/mir/lowering/functions.rb:2002, src/annotator/helpers/method_analysis.rb:44, src/annotator/helpers/method_analysis.rb:45, src/annotator/domains/control_flow.rb:258
- 16 guards collapse | `full_type!()` (call) across 12 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `Annotator::Domains::Lifetimes#share_consumes_source?`, `Annotator::Domains::Lifetimes#visit_CopyNode`, `Annotator::Phases::ExpressionDomains#resolve_extern_method_call!`, `Annotator::Domains::ControlFlow#visit_ForEach`, `Annotator::Domains::Errors#visit_ReturnNode`, `Annotator::Domains::Expressions#visit_BinaryOp`, +6 more
  - guards at: src/annotator/domains/lifetimes.rb:1142, src/annotator/domains/lifetimes.rb:1143, src/annotator/domains/lifetimes.rb:129, src/annotator/domains/lifetimes.rb:140, src/annotator/phases/expression_domains.rb:231
- 7 guards collapse | `.return_type` (accessor) across 7 method(s) -> via @return_type assignments (runtime) {Type, Symbol, T.nilable(Type)}: tighten that contract
  - methods: `EffectTracker#assign_base_stack_tiers!`, `EffectTracker#compute_can_fail!`, `EffectTracker#function_needs_runtime_directly?`, `MIRLoweringFunctions#call_owned_return?`, `MIRLoweringVariables#tied_shared_family_return_param`, `PipeAnalysis#analyze_pipe_to_named_function`, +1 more
  - guards at: src/annotator/helpers/effects.rb:1043, src/annotator/helpers/effects.rb:520, src/annotator/helpers/effects.rb:434, src/mir/lowering/functions.rb:1461, src/mir/lowering/variables.rb:91
- 6 guards collapse | `` (hash-key) across 6 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `Annotator::Domains::ControlFlow#match_payload_struct_schema`, `Annotator::Domains::MemberAccess#visit_StructLit`, `MIRLoweringConcurrency#capture_ownership_mirror_nodes`, `MIRLoweringExpressions#lower_union_variant_lit`, `TypeShape#resolved`, `UnionAnalysis#validate_union_fields!`
  - guards at: src/annotator/domains/control_flow.rb:594, src/annotator/domains/member_access.rb:314, src/mir/lowering/concurrency.rb:207, src/mir/lowering/expressions.rb:1594, src/ast/type.rb:346
- 4 guards collapse | `.resolved_type` (accessor) across 2 method(s) -> via @resolved_type assignments (runtime) {Type, NilClass}: tighten that contract
  - methods: `CapabilityHelper#validate_capability_transition!`, `MIRLoweringControlFlow#match_lowering_facts`
  - guards at: src/annotator/helpers/capabilities.rb:207, src/annotator/helpers/capabilities.rb:219, src/mir/lowering/control_flow.rb:707, src/mir/lowering/control_flow.rb:710
- 4 guards collapse | `.full_type!` (accessor) across 4 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `FsmLowering#lower_step_stmts`, `MIRLoweringControlFlow#for_each_plan`, `MIRLoweringExpressions#lower_share`, `MIRLoweringFunctions#lower_lambda`
  - guards at: src/mir/fsm_lowering.rb:107, src/mir/lowering/control_flow.rb:321, src/mir/lowering/expressions.rb:2108, src/mir/lowering/functions.rb:1995
- 2 guards collapse | `param `b` (AutoUnifier#types_equal?)` (param) across 1 method(s) -> always `AutoConstraintCollector::ObservedType`: collapse, all 2 die
  - methods: `AutoUnifier#types_equal?`
  - guards at: src/annotator/helpers/auto_inference.rb:601, src/annotator/helpers/auto_inference.rb:603
- 2 guards collapse | `param `expected_type` (Annotator::Domains::Lifetimes#ensure_owned_value!)` (param) across 1 method(s) -> 50.0% `Type` + 2 outlier producer(s)
  - methods: `Annotator::Domains::Lifetimes#ensure_owned_value!`
  - guards at: src/annotator/domains/lifetimes.rb:76, src/annotator/domains/lifetimes.rb:80
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/annotator/helpers/function_analysis.rb:641 `facts.param.type`
  - outlier producer `T.nilable(Type)` at src/annotator/helpers/union.rb:202 `expected_fields[fname]`
- 2 guards collapse | `param `a` (AutoUnifier#types_equal?)` (param) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `AutoUnifier#types_equal?`
  - guards at: src/annotator/helpers/auto_inference.rb:601, src/annotator/helpers/auto_inference.rb:602
- 2 guards collapse | `local `_type_obj` (FiberCtxBuilder#build)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `FiberCtxBuilder#build`
  - guards at: src/mir/fiber_ctx_builder.rb:323, src/mir/fiber_ctx_builder.rb:352
- 2 guards collapse | `send()` (call) across 2 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `FunctionAnalysis#any_array_intrinsic_arg?`, `FunctionReturn#resolve`
  - guards at: src/annotator/helpers/function_analysis.rb:1342, src/annotator/helpers/function_return.rb:113
- 1 guards collapse | `param `input` (TypeHelper#to_type)` (param) across 1 method(s) -> always `Type`: collapse, all 1 die
  - methods: `TypeHelper#to_type`
  - guards at: src/ast/type.rb:3661
- 1 guards collapse | `param `type` (FixableHelper#auto_type_source_form)` (param) across 1 method(s) -> always `Symbol`: collapse, all 1 die
  - methods: `FixableHelper#auto_type_source_form`
  - guards at: src/annotator/helpers/fixable_helpers.rb:1729
- 1 guards collapse | `param `t` (AutoUnifier#widen_byte_array_to_string)` (param) across 1 method(s) -> always `AutoConstraintCollector::ObservedType`: collapse, all 1 die
  - methods: `AutoUnifier#widen_byte_array_to_string`
  - guards at: src/annotator/helpers/auto_inference.rb:590
- 1 guards collapse | `param `type` (ClearParser#synthesize_default_for_type)` (param) across 1 method(s) -> always `T.nilable(Type)`: collapse, all 1 die
  - methods: `ClearParser#synthesize_default_for_type`
  - guards at: src/ast/parser.rb:960
- 1 guards collapse | `param `type_obj` (FiberCtxBuilder#needs_move_capture_cleanup?)` (param) across 1 method(s) -> always `Type`: collapse, all 1 die
  - methods: `FiberCtxBuilder#needs_move_capture_cleanup?`
  - guards at: src/mir/fiber_ctx_builder.rb:418
- 1 guards collapse | `param `right` (GenericAnalysis#same_generic_binding?)` (param) across 1 method(s) -> always `Type`: collapse, all 1 die
  - methods: `GenericAnalysis#same_generic_binding?`
  - guards at: src/annotator/helpers/generic_analysis.rb:436
- 1 guards collapse | `param `to_type` (MIRLowering#mir_cast)` (param) across 1 method(s) -> always `Type`: collapse, all 1 die
  - methods: `MIRLowering#mir_cast`
  - guards at: src/mir/mir_lowering.rb:2731
- 1 guards collapse | `param `sink_type` (MIRLowering#owned_sink_plan)` (param) across 1 method(s) -> always `T.nilable(Type::TypeInput)`: collapse, all 1 die
  - methods: `MIRLowering#owned_sink_plan`
  - guards at: src/mir/mir_lowering.rb:3643
- 1 guards collapse | `param `t` (ModuleImporter#auto_type?)` (param) across 1 method(s) -> always `Type`: collapse, all 1 die
  - methods: `ModuleImporter#auto_type?`
  - guards at: src/compiler/module_importer.rb:165
- 1 guards collapse | `param `target_type` (Type#coerce_error)` (param) across 1 method(s) -> always `CoerceTypeInput`: collapse, all 1 die
  - methods: `Type#coerce_error`
  - guards at: src/ast/type.rb:585
- 1 guards collapse | `param `type_info` (Annotator::Domains::Lifetimes#og_declare)` (param) across 1 method(s) -> 83.3% `Type` + 1 outlier producer(s)
  - methods: `Annotator::Domains::Lifetimes#og_declare`
  - guards at: src/annotator/domains/lifetimes.rb:1130
  - outlier producer `Symbol` at src/annotator/helpers/test_annotation.rb:156 `:Int64`
- 1 guards collapse | `param `type` (ClearParser#type_annotation_source)` (param) across 1 method(s) -> 66.7% `Type` + 1 outlier producer(s)
  - methods: `ClearParser#type_annotation_source`
  - guards at: src/ast/parser.rb:2880
  - outlier producer `T.nilable(Type)` at src/ast/parser.rb:2544 `T.must(parse_type_annotation)`
- 1 guards collapse | `param `x` (FunctionSignature#unwrap)` (param) across 1 method(s) -> 60.0% `T::Hash[T.untyped, T.untyped]` + 6 outlier producer(s)
  - methods: `FunctionSignature#unwrap`
  - guards at: src/annotator/helpers/function_signature.rb:282
  - outlier producer `LookupResult` at src/annotator/helpers/intrinsic_registry.rb:234 `IntrinsicRegistry.lookup(registry, method_name)`
  - outlier producer `LookupResult` at src/annotator/helpers/intrinsic_registry.rb:245 `IntrinsicRegistry.lookup(MAP_METHODS, name.to_s)`
  - outlier producer `LookupResult` at src/annotator/helpers/intrinsic_registry.rb:255 `IntrinsicRegistry.lookup(registry, method_name)`
  - outlier producer `Type` at src/ast/scope.rb:474 `fn_scope.resolve_type(name)`
  - outlier producer `NilClass` at src/mir/lowering/functions.rb:1183 `matched`
  - outlier producer `FunctionSignature` at src/mir/mir.rb:4644 `stdlib_def`
- 1 guards collapse | `param `type_obj` (GenericAnalysis#apply_type_subst)` (param) across 1 method(s) -> 60.0% `MatchPayload` + 2 outlier producer(s)
  - methods: `GenericAnalysis#apply_type_subst`
  - guards at: src/annotator/helpers/generic_analysis.rb:371
  - outlier producer `T.nilable(T.any(Type, Symbol))` at src/annotator/domains/member_access.rb:387 `raw_expected`
  - outlier producer `Type` at src/annotator/helpers/generic_analysis.rb:494 `signature.return_type`
- 1 guards collapse | `param `other` (Type#==)` (param) across 1 method(s) -> 59.6% `Symbol` + 42 outlier producer(s)
  - methods: Type#==
  - guards at: src/ast/type.rb:1433
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/annotator/domains/control_flow.rb:261 `field_type`
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/annotator/helpers/function_analysis.rb:759 `facts.actual_type.resolved`
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/annotator/helpers/union.rb:78 `sig_t`
  - outlier producer `MatchPayload` at src/annotator/domains/control_flow.rb:320 `extra_payload`
  - outlier producer `T::Boolean` at src/annotator/domains/control_flow.rb:770 `true`
  - outlier producer `T::Boolean` at src/annotator/domains/control_flow.rb:796 `true`
- 1 guards collapse | `param `node` (PreMirTypeCheck#walk)` (param) across 1 method(s) -> 50.0% `AST::Program` + 2 outlier producer(s)
  - methods: `PreMirTypeCheck#walk`
  - guards at: src/mir/pre_mir_type_check.rb:72
  - outlier producer `T::Array[T.untyped]` at src/annotator/helpers/auto_inference.rb:723 `fn.body`
  - outlier producer `T::Array[T.any(Stmt, Expr)]` at src/mir/fsm_ops.rb:446 `ops_or_expr`
- 1 guards collapse | `param `val` (AST::Locatable#full_type=)` (param) across 1 method(s) -> 50.0% `SyntheticTypeInput` + 1 outlier producer(s)
  - methods: `AST::Locatable#full_type=`
  - guards at: src/ast/ast.rb:989
  - outlier producer `Type` at src/ast/ast.rb:1124 `t`
- 1 guards collapse | `param `type` (Type#surface_name)` (param) across 1 method(s) -> 44.4% `TypeInput` + 5 outlier producer(s)
  - methods: `Type#surface_name`
  - guards at: src/ast/type.rb:467
  - outlier producer `Type` at src/ast/type.rb:469 `t.tense_type`
  - outlier producer `Type` at src/mir/mir_lowering.rb:2775 `from_t`
  - outlier producer `T.nilable(Type)` at src/ast/type.rb:470 `T.must(t.payload_type)`
  - outlier producer `T.nilable(Type)` at src/ast/type.rb:471 `T.must(t.wrapped_type)`
  - outlier producer `T.nilable(Type)` at src/ast/type.rb:472 `T.must(t.element_type)`
- 1 guards collapse | `param `type` (ZigTypeMapper#transpile_type)` (param) across 1 method(s) -> 40.9% `String` + 9 outlier producer(s)
  - methods: `ZigTypeMapper#transpile_type`
  - guards at: src/backends/zig_type_mapper.rb:41
  - outlier producer `Type` at src/mir/lowering/expressions.rb:774 `ft`
  - outlier producer `Type` at src/mir/lowering/expressions.rb:824 `t`
  - outlier producer `Type` at src/mir/lowering/functions.rb:297 `ret_type`
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/mir/lowering/expressions.rb:2204 `ti.non_optional_type.resolved`
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/mir/lowering/functions.rb:541 `param.type`
  - outlier producer `T::Hash[T.untyped, T.untyped]` at src/mir/mir_lowering.rb:2733 `to`

### Deterministic Guard Collapse
- `static_proven` rows are predicates nil-kill can prove from source/type facts. `contract_proven` rows are guard clusters that collapse when the named origin is typed to its observed singleton producer. Runtime-only dominance is review material, not an autofix proof.
- Contract-proven collapses: 11
  - contract_proven: 2 guard(s) collapse | `param `b` (AutoUnifier#types_equal?)` (param) -> always `AutoConstraintCollector::ObservedType`
    - methods/sites: `AutoUnifier#types_equal?`; src/annotator/helpers/auto_inference.rb:601, src/annotator/helpers/auto_inference.rb:603
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `input` (TypeHelper#to_type)` (param) -> always `Type`
    - methods/sites: `TypeHelper#to_type`; src/ast/type.rb:3661
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `type` (FixableHelper#auto_type_source_form)` (param) -> always `Symbol`
    - methods/sites: `FixableHelper#auto_type_source_form`; src/annotator/helpers/fixable_helpers.rb:1729
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `t` (AutoUnifier#widen_byte_array_to_string)` (param) -> always `AutoConstraintCollector::ObservedType`
    - methods/sites: `AutoUnifier#widen_byte_array_to_string`; src/annotator/helpers/auto_inference.rb:590
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `type` (ClearParser#synthesize_default_for_type)` (param) -> always `T.nilable(Type)`
    - methods/sites: `ClearParser#synthesize_default_for_type`; src/ast/parser.rb:960
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `type_obj` (FiberCtxBuilder#needs_move_capture_cleanup?)` (param) -> always `Type`
    - methods/sites: `FiberCtxBuilder#needs_move_capture_cleanup?`; src/mir/fiber_ctx_builder.rb:418
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `right` (GenericAnalysis#same_generic_binding?)` (param) -> always `Type`
    - methods/sites: `GenericAnalysis#same_generic_binding?`; src/annotator/helpers/generic_analysis.rb:436
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `to_type` (MIRLowering#mir_cast)` (param) -> always `Type`
    - methods/sites: `MIRLowering#mir_cast`; src/mir/mir_lowering.rb:2731
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `sink_type` (MIRLowering#owned_sink_plan)` (param) -> always `T.nilable(Type::TypeInput)`
    - methods/sites: `MIRLowering#owned_sink_plan`; src/mir/mir_lowering.rb:3643
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `t` (ModuleImporter#auto_type?)` (param) -> always `Type`
    - methods/sites: `ModuleImporter#auto_type?`; src/compiler/module_importer.rb:165
    - producer evidence: param origins
  - contract_proven: 1 guard(s) collapse | `param `target_type` (Type#coerce_error)` (param) -> always `CoerceTypeInput`
    - methods/sites: `Type#coerce_error`; src/ast/type.rb:585
    - producer evidence: param origins
- Static-proven branch predicates: 27
  - static_proven: src/annotator/domains/control_flow.rb:448 `Annotator::Domains::ControlFlow#analyze_match_case!` `pattern.is_a?(AST::StructPattern)` -> always true (if takes body)
    - pattern has static type AST::StructPattern; is_a?(AST::StructPattern) is always true
  - static_proven: src/annotator/domains/errors.rb:376 `Annotator::Domains::Errors#visit_ReturnNode` `raw_value.nil?` -> always true (if takes body)
    - raw_value has static type NilClass; .nil? is always true
  - static_proven: src/annotator/helpers/function_signature.rb:290 `FunctionSignature#from_function_def` `raw_sig.is_a?(FunctionSignature)` -> always true (if takes body)
    - raw_sig has static type FunctionSignature; is_a?(FunctionSignature) is always true
  - static_proven: src/annotator/helpers/function_signature.rb:703 `FunctionSignature#normalize_lifetime` `val.nil?` -> always false (if takes else)
    - val has static type LifetimeInput; .nil? is always false
  - static_proven: src/annotator/helpers/pipe_analysis.rb:1217 `PipeAnalysis#auto_detect_sharded_access` `each_op.is_a?(AST::EachOp)` -> always true (unless takes else)
    - each_op has static type AST::EachOp; is_a?(AST::EachOp) is always true
  - static_proven: src/ast/parser.rb:2880 `ClearParser#type_annotation_source` `type.is_a?(Type)` -> always true (if takes body)
    - type has static type Type; is_a?(Type) is always true
  - static_proven: src/ast/symbol_entry.rb:476 `SymbolEntry#initialize` `type.nil?` -> always false (if takes else)
    - type has static type TypeInput; .nil? is always false
  - static_proven: src/ast/symbol_entry.rb:507 `SymbolEntry#type=` `val.nil?` -> always false (if takes else)
    - val has static type TypeInput; .nil? is always false
  - static_proven: src/ast/type.rb:2375 `Type#observable_array_future?` `tt.is_a?(Type)` -> always true (unless takes else)
    - tt has static type Type; is_a?(Type) is always true
  - static_proven: src/ast/type.rb:2769 `Type#copyable?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: src/ast/type.rb:2798 `Type#bg_capture_is_value_copy?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: src/ast/type.rb:2800 `Type#bg_capture_is_value_copy?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: src/ast/type.rb:2825 `Type#implicitly_copyable?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: src/ast/type.rb:2828 `Type#implicitly_copyable?` `resolver.is_a?(Proc)` -> always true (if takes body)
    - resolver has static type Proc; is_a?(Proc) is always true
  - static_proven: src/backends/mir_emitter.rb:333 `MIREmitter#emit_do_block` `plan.is_a?(MIR::DoBlockPlan)` -> always true (if takes body)
    - plan has static type MIR::DoBlockPlan; is_a?(MIR::DoBlockPlan) is always true
  - static_proven: src/mir/control_flow.rb:127 `FunctionCFG#build_body` `stmts.is_a?(Array)` -> always true (unless takes else)
    - stmts has static type T::Array[`T.untyped`]; is_a?(Array) is always true
  - static_proven: src/mir/fsm_transform/segments.rb:274 `FsmTransform::Segments#split_while_loop_next` `cond_node.nil?` -> always true (if takes body)
    - cond_node has static type NilClass; .nil? is always true
  - static_proven: src/mir/hoist.rb:96 `Hoist#hoist_body!` `body.is_a?(Array)` -> always true (unless takes else)
    - body has static type T::Array[AST::Node]; is_a?(Array) is always true
  - static_proven: src/mir/lowering/functions.rb:1214 `MIRLoweringFunctions#stdlib_coerce_type` `resolved.is_a?(Symbol)` -> always false (if takes else)
    - resolved has static type T::Hash[`T.untyped`, `T.untyped`]; is_a?(Symbol) is always false
  - static_proven: src/mir/lowering/functions.rb:1461 `MIRLoweringFunctions#call_owned_return?` `raw_ti.is_a?(Type)` -> always true (if takes body)
    - raw_ti has static type Type; is_a?(Type) is always true
  - static_proven: src/mir/mir_lowering.rb:1179 `MIRLowering#seed_cleanup_owner_index!` `nested_body.is_a?(Array)` -> always true (if takes body)
    - nested_body has static type T::Array[MIR::Emittable]; is_a?(Array) is always true
  - static_proven: src/mir/mir_lowering.rb:1204 `MIRLowering#append_lowered_statement_packet!` `packet_mir.is_a?(Array)` -> always true (if takes body)
    - packet_mir has static type T::Array[`T.untyped`]; is_a?(Array) is always true
  - static_proven: src/mir/mir_lowering.rb:2730 `MIRLowering#mir_cast` `from_type.is_a?(Type)` -> always true (if takes body)
    - from_type has static type Type; is_a?(Type) is always true
  - static_proven: src/mir/mir_pass.rb:449 `MIRPass#transform_body` `stmts.is_a?(Array)` -> always true (unless takes else)
    - stmts has static type T::Array[`T.untyped`]; is_a?(Array) is always true
  - static_proven: src/mir/thunk_transform/emit.rb:253 `ThunkTransform::Emit#return_type_info` `rt.nil?` -> always false (if takes else)
    - rt has static type Type; .nil? is always false
  - static_proven: src/mir/thunk_transform/emit.rb:254 `ThunkTransform::Emit#return_type_info` `rt.is_a?(Type)` -> always true (if takes body)
    - rt has static type Type; is_a?(Type) is always true
  - static_proven: src/semantic/local_binding_facts.rb:48 `MIR::LocalBindingAnalysis#each_direct_loop_node` `body.is_a?(Array)` -> always true (unless takes else)
    - body has static type T::Array[`T.untyped`]; is_a?(Array) is always true

### Node-Union Alias Candidates
- Heterogeneous param slots whose every observed class is in ONE namespace. Each namespace below collapses to a single `T.type_alias` (e.g. `AstNode = T.type_alias { T.any(AST::...) }`); applying it types every listed param at once. `classes` = distinct node types observed at that slot (small = a precise sub-union; large = the full node grab-bag).
- 135 of 196 Heterogeneous params (69%) collapse to 3 alias(es).
- `AstNode` (AST::*): 78 param slot(s)
  - src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture` param `node` (82 node types)
  - src/mir/control_flow.rb:276 `FunctionCFG#stmt_can_fail?` param `node` (65 node types)
  - src/semantic/escape_analysis.rb:130 `EscapeAnalysis::EscapeSink#matches?` param `node` (53 node types)
  - src/ast/ast.rb:727 `AST#_bg_visit_recursive` param `node` (33 node types)
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` param `ast_value` (31 node types)
  - src/mir/lowering/variables.rb:306 `MIRLoweringVariables#optional_nil_initializer?` param `value` (31 node types)
  - src/mir/lowering/variables.rb:314 `MIRLoweringVariables#owned_binding_source_alloc` param `value` (31 node types)
  - src/semantic/escape_analysis.rb:866 `EscapeAnalysis#borrow_return_expr?` param `expr` (31 node types)
  - src/ast/ast.rb:663 `AST#wrapped_children` param `expr` (30 node types)
  - src/ast/type.rb:3673 `TypeHelper#check_prefixed_int_range!` param `node` (30 node types)
  - src/ast/type.rb:3695 `TypeHelper#integer_literal_range_value` param `node` (30 node types)
  - src/mir/cleanup_classifier.rb:1077 `CleanupClassifier#optional_empty_initializer?` param `value` (29 node types)
  - src/mir/mir_pass.rb:487 `MIRPass#recurse_branches!` param `stmt` (29 node types)
  - src/mir/hoist.rb:115 `Hoist#child_bodies` param `stmt` (27 node types)
  - src/mir/hoist.rb:624 `MIRHoistLowering#hoist_alloc` param `ast_node` (27 node types)
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads` param `stmt` (26 node types)
  - src/mir/hoist.rb:320 `Hoist#concat?` param `node` (26 node types)
  - src/semantic/escape_analysis.rb:784 `EscapeAnalysis#heap_binding_carries_sources?` param `value` (26 node types)
  - src/mir/cleanup_classifier.rb:943 `CleanupClassifier#contains_call?` param `node` (23 node types)
  - src/mir/fsm_transform.rb:251 `FsmTransform#local_entry_for_node` param `node` (23 node types)
  - src/annotator/helpers/function_analysis.rb:1260 `FunctionAnalysis#return_is_borrow?` param `node` (21 node types)
  - src/mir/hoist.rb:396 `Hoist#ast_access_path?` param `ast_node` (21 node types)
  - src/mir/lowering/control_flow.rb:1206 `MIRLoweringControlFlow#call_union_return_needs_hoist?` param `ast_node` (20 node types)
  - src/mir/hoist.rb:1174 `MIRHoistLowering#hoist_cleanup_entry` param `ast_node` (19 node types)
  - src/mir/lowering/control_flow.rb:1175 `MIRLoweringControlFlow#collect_returned_binding_names` param `expr` (18 node types)
  - src/mir/mir_lowering.rb:2645 `MIRLowering#placement_for_node` param `node` (18 node types)
  - src/ast/parser.rb:1942 `ClearParser#parse_suffixes` param `lhs` (17 node types)
  - src/semantic/escape_analysis.rb:1015 `EscapeAnalysis#borrowed_return?` param `expr` (16 node types)
  - src/semantic/escape_analysis.rb:1052 `EscapeAnalysis#owning_return_type` param `expr` (16 node types)
  - src/semantic/escape_analysis.rb:728 `EscapeAnalysis#ownership_bearing_transfer_expr?` param `arg` (16 node types)
  - src/mir/mir_lowering.rb:2634 `MIRLowering#symbol_storage_for_node` param `node` (15 node types)
  - src/semantic/escape_analysis.rb:742 `EscapeAnalysis#heap_owned_transfer_source?` param `arg` (15 node types)
  - src/semantic/escape_analysis.rb:833 `EscapeAnalysis#ownership_transferring_expr?` param `expr` (15 node types)
  - src/semantic/escape_analysis.rb:874 `EscapeAnalysis#expr_has_heap_identifier?` param `expr` (15 node types)
  - src/semantic/escape_analysis.rb:544 `EscapeAnalysis#mark_expr_roots_heap!` param `expr` (14 node types)
  - src/semantic/escape_analysis.rb:849 `EscapeAnalysis#string_concat_expr?` param `expr` (14 node types)
  - src/ast/parser.rb:1790 `ClearParser#parse_binary_op` param `lhs` (13 node types)
  - src/mir/lowering/control_flow.rb:1221 `MIRLoweringControlFlow#universal_poly_arg_needs_addr?` param `arg_node` (13 node types)
  - src/mir/lowering/functions.rb:1147 `MIRLoweringFunctions#borrowed_ownership_operand?` param `arg` (13 node types)
  - src/mir/lowering/functions.rb:1307 `MIRLoweringFunctions#wants_ptr?` param `a` (13 node types)
  - src/mir/mir_lowering.rb:2415 `MIRLowering#moved_arg_root` param `arg` (13 node types)
  - src/mir/rewriters/pipeline_rewriter.rb:587 `PipelineRewriter#build_terminal_action` param `terminal` (13 node types)
  - src/mir/fsm_transform/segments.rb:361 `FsmTransform::Segments#suspend_for` param `v` (11 node types)
  - src/mir/hoist.rb:29 `MIRHoistFacts#container_borrow_expr?` param `ast_node` (11 node types)
  - src/mir/lowering/variables.rb:618 `MIRLoweringVariables#source_already_has_declared_capability?` param `source_node` (11 node types)
  - src/mir/rewriters/pipeline_rewriter.rb:393 `PipelineRewriter#build_init` param `terminal` (11 node types)
  - src/mir/rewriters/pipeline_rewriter.rb:489 `PipelineRewriter#build_recursive_body` param `terminal` (11 node types)
  - src/mir/fsm_transform/segments.rb:295 `FsmTransform::Segments#stmt_unsupported?` param `stmt` (10 node types)
  - src/mir/hoist.rb:1229 `MIRHoistLowering#cleanup_entry_for_owned_result` param `ast_node` (10 node types)
  - src/mir/lowering/expressions.rb:1210 `MIRLoweringExpressions#comptime_number_literal?` param `node` (10 node types)
  - src/mir/lowering/expressions.rb:651 `MIRLoweringExpressions#unit_variant_access` param `node` (10 node types)
  - src/mir/rewriters/pipeline_rewriter.rb:783 `PipelineRewriter#replace_placeholder` param `node` (10 node types)
  - src/semantic/escape_analysis.rb:886 `EscapeAnalysis#expr_has_owned_inline_value?` param `expr` (10 node types)
  - src/mir/rewriters/pipeline_rewriter.rb:721 `PipelineRewriter#build_final_result` param `terminal` (9 node types)
  - src/semantic/escape_analysis.rb:380 `EscapeAnalysis#apply_escape_sink!` param `node` (9 node types)
  - src/semantic/escape_analysis.rb:752 `EscapeAnalysis#mark_receiver_scope_escapes!` param `receiver` (9 node types)
  - src/ast/source_error.rb:95 `ErrorHelper#note!` param `node_or_token` (8 node types)
  - src/mir/lowering/expressions.rb:1935 `MIRLoweringExpressions#type_info_for` param `ast_node` (8 node types)
  - src/tools/migration_suggester_helpers.rb:106 `MigrationSuggesterHelpers#classify_uses!` param `node` (8 node types)
  - src/annotator/helpers/pipe_analysis.rb:1311 `PipeAnalysis#sharded_get_index_access` param `node` (7 node types)
  - src/mir/hoist.rb:207 `Hoist#moved_arg?` param `node` (7 node types)
  - src/ast/parser.rb:2055 `ClearParser#extract_paren_bindings` param `node` (6 node types)
  - src/mir/fsm_transform.rb:316 `FsmTransform#suspend_value?` param `value` (6 node types)
  - src/mir/lowering/expressions.rb:996 `MIRLoweringExpressions#or_fallback_access_path?` param `ast_node` (6 node types)
  - src/mir/lowering/concurrency.rb:474 `MIRLoweringConcurrency#do_branch_stmt_nodes` param `expr` (5 node types)
  - src/annotator/helpers/capabilities.rb:1133 `CapabilityHelper#record_capture_site!` param `node` (4 node types)
  - src/annotator/helpers/pipe_analysis.rb:1174 `PipeAnalysis#collect_sharded_names` param `node` (4 node types)
  - src/ast/parser.rb:3967 `ClearParser#deep_clone_node` param `node` (4 node types)
  - src/mir/cleanup_classifier.rb:1187 `CleanupClassifier#classify_struct_cleanup_fields` param `node` (4 node types)
  - src/annotator/helpers/generic_analysis.rb:44 `GenericAnalysis#validate_type_param_list!` param `node` (3 node types)
  - src/mir/lowering/functions.rb:1442 `MIRLoweringFunctions#call_owned_return?` param `node` (3 node types)
  - src/annotator/helpers/function_analysis.rb:350 `FunctionAnalysis#resolve_call` param `node` (2 node types)
  - src/annotator/helpers/test_annotation.rb:100 `TestAnnotation#visit_test_hook_bodies` param `node` (2 node types)
  - src/annotator/helpers/test_annotation.rb:79 `TestAnnotation#visit_test_lets` param `node` (2 node types)
  - src/ast/parser.rb:2077 `ClearParser#validate_no_bare_bind!` param `node` (2 node types)
  - src/ast/scope.rb:406 `Scope#get_path_to_root` param `node` (2 node types)
  - src/mir/lowering/functions.rb:1218 `MIRLoweringFunctions#matched_call_signature` param `node` (2 node types)
  - src/mir/lowering/functions.rb:1266 `MIRLoweringFunctions#finalize_call_result` param `node` (2 node types)
- `MirNode` (MIR::*): 54 param slot(s)
  - src/mir/mir_checker.rb:1029 `MIRChecker#collect_linear_expr_ident_names` param `expr` (99 node types)
  - src/mir/mir_checker.rb:992 `MIRChecker#check_nested_linear_expr_bodies!` param `expr` (98 node types)
  - src/mir/mir_checker.rb:2913 `MIRChecker#allocating_expr?` param `expr` (79 node types)
  - src/mir/mir_checker.rb:579 `MIRChecker#check_linear_stmt!` param `stmt` (76 node types)
  - src/mir/hoist.rb:822 `MIRHoistLowering#normalize_allocating_mir_stmt!` param `stmt` (69 node types)
  - src/mir/mir_checker.rb:2822 `MIRChecker#check_stmt_for_unhoisted` param `node` (69 node types)
  - src/mir/hoist.rb:1047 `MIRHoistLowering#replace_mir_expr_child!` param `parent` (68 node types)
  - src/mir/mir_checker.rb:1007 `MIRChecker#linear_expr_consumed_names` param `expr` (59 node types)
  - src/mir/mir_checker.rb:969 `MIRChecker#check_linear_expr_uses!` param `expr` (59 node types)
  - src/mir/mir_checker.rb:1022 `MIRChecker#linear_expr_ident_names` param `expr` (58 node types)
  - src/mir/hoist.rb:930 `MIRHoistLowering#normalize_allocating_result_expr!` param `expr` (52 node types)
  - src/mir/hoist.rb:805 `MIRHoistLowering#consumes_owned_children?` param `node` (50 node types)
  - src/mir/hoist.rb:1047 `MIRHoistLowering#replace_mir_expr_child!` param `old_child` (49 node types)
  - src/mir/mir_checker.rb:2874 `MIRChecker#check_owned_expr_position_for_unhoisted` param `expr` (49 node types)
  - src/mir/hoist.rb:1047 `MIRHoistLowering#replace_mir_expr_child!` param `new_child` (46 node types)
  - src/mir/hoist.rb:1039 `MIRHoistLowering#mir_consumes_owned_operands?` param `expr` (45 node types)
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` param `init` (38 node types)
  - src/mir/lowering/variables.rb:379 `MIRLoweringVariables#var_decl_suppression` param `init` (38 node types)
  - src/mir/lowering/variables.rb:396 `MIRLoweringVariables#stamp_var_decl_init_target!` param `init` (38 node types)
  - src/mir/hoist.rb:1174 `MIRHoistLowering#hoist_cleanup_entry` param `mir` (24 node types)
  - src/mir/lowering/control_flow.rb:919 `MIRLoweringControlFlow#return_payload_pointer_value` param `value` (20 node types)
  - src/mir/lowering/control_flow.rb:937 `MIRLoweringControlFlow#heap_carry_return_value` param `value` (20 node types)
  - src/mir/lowering/control_flow.rb:950 `MIRLoweringControlFlow#heap_carry_recursive_param_value` param `value` (20 node types)
  - src/mir/lowering/control_flow.rb:962 `MIRLoweringControlFlow#tail_call_return?` param `value` (20 node types)
  - src/mir/mir_lowering.rb:2202 `MIRLowering#with_ownership_consumption_for_value` param `value_mir` (18 node types)
  - src/mir/lowering/control_flow.rb:968 `MIRLoweringControlFlow#return_with_transfer_marks` param `value` (17 node types)
  - src/mir/lowering/functions.rb:993 `MIRLoweringFunctions#cross_boundary_arg` param `arg` (17 node types)
  - src/mir/mir.rb:2720 `MIR#initialize` param `source` (14 node types)
  - src/mir/hoist.rb:904 `MIRHoistLowering#normalize_used_expr_attr!` param `stmt` (12 node types)
  - src/mir/mir.rb:2853 `MIR#initialize` param `source` (12 node types)
  - src/mir/lowering/variables.rb:795 `MIRLoweringVariables#fallible_self_fallback_reassign?` param `value` (11 node types)
  - src/mir/hoist.rb:1029 `MIRHoistLowering#normalized_alloc_wrapper_alias?` param `expr` (10 node types)
  - src/mir/hoist.rb:1093 `MIRHoistLowering#refresh_ownership_consumption_for_replaced_child!` param `parent` (10 node types)
  - src/mir/mir_lowering.rb:790 `MIRLowering#place_owned_branch_value_for_destination` param `mir` (10 node types)
  - src/backends/mir_emitter.rb:1068 `MIREmitter#emit_flow_stmt` param `stmt` (9 node types)
  - src/mir/fsm_lowering.rb:182 `FsmLowering#coerce_fsm_result_value` param `value` (9 node types)
  - src/mir/hoist.rb:746 `MIRHoistLowering#hoist_normalized_alloc_expr` param `expr` (9 node types)
  - src/mir/lowering/control_flow.rb:100 `MIRLoweringControlFlow#loop_condition_expr` param `cond` (9 node types)
  - src/mir/mir_checker.rb:1364 `MIRChecker#value_constructor_expr?` param `node` (8 node types)
  - src/mir/hoist.rb:1093 `MIRHoistLowering#refresh_ownership_consumption_for_replaced_child!` param `old_child` (7 node types)
  - src/mir/lowering/expressions.rb:981 `MIRLoweringExpressions#materialize_or_fallback_value` param `value` (7 node types)
  - src/mir/mir.rb:3649 `MIR#initialize` param `receiver` (7 node types)
  - src/mir/mir_lowering.rb:1358 `MIRLowering#place_discarded_owned_branch_value` param `mir` (7 node types)
  - src/mir/mir_lowering.rb:3462 `MIRLowering#try_catch_with_provenance` param `catch_body` (7 node types)
  - src/mir/lowering/variables.rb:1017 `MIRLoweringVariables#lower_map_indexed_assignment` param `idx` (6 node types)
  - src/mir/mir.rb:2698 `MIR#initialize` param `init` (6 node types)
  - src/mir/hoist.rb:1264 `MIRHoistLowering#cleanup_entry_for_ownership_effect` param `mir` (5 node types)
  - src/mir/lowering/concurrency.rb:474 `MIRLoweringConcurrency#do_branch_stmt_nodes` param `mir` (5 node types)
  - src/mir/lowering/variables.rb:123 `MIRLoweringVariables#compose_capability_wrap` param `inner_mir` (5 node types)
  - src/mir/mir.rb:2920 `MIR#initialize` param `inner` (5 node types)
  - src/mir/hoist.rb:1248 `MIRHoistLowering#typed_cleanup_entry_for_mir_result` param `mir` (4 node types)
  - src/backends/mir_emitter.rb:484 `MIREmitter#sharded_map_template` param `node` (2 node types)
  - src/backends/mir_emitter.rb:491 `MIREmitter#sharded_map_substitute_common` param `node` (2 node types)
  - src/mir/hoist.rb:502 `MIRHoistLowering#with_pending` param `node` (2 node types)
- `SchemasNode` (Schemas::*): 3 param slot(s)
  - src/ast/schemas.rb:379 `Schemas#union?` param `s` (4 node types)
  - src/ast/schemas.rb:382 `Schemas#enum?` param `s` (4 node types)
  - src/ast/schemas.rb:385 `Schemas#resource?` param `s` (4 node types)

### Untyped Evidence Gaps
- The residual NoEvidence, by category x WHY, then listed with locations. Each is a triage candidate (dead code / missing test / should-be-void / untraceable arg), not a classifier defect.

|  | unseen | arg untraced | only nil | discarded return | collection no elements | struct unobserved | Total |
|---|---|---|---|---|---|---|---|
| Params | 1 | 53 | 1 | 0 | 0 | 0 | 55 |
| Returns | 0 | 0 | 0 | 5 | 0 | 0 | 5 |
| Struct/ivar | 0 | 0 | 0 | 0 | 0 | 12 | 12 |
| Collections | 0 | 0 | 0 | 0 | 65 | 0 | 65 |
| **Total** | 1 | 53 | 1 | 5 | 65 | 12 | 137 |
- `unseen`: Not reached by the collect workload (a superset of every suite) and no runtime record -- genuinely dead/unreachable, or a real missing test. Investigate or delete.
- `arg untraced`: Block / kwarg / splat arg -- the tracer types only positional named args (these are ~always Proc; low value)
- `only nil`: Only ever nil at runtime -- likely unused / optional-dead; verify it is reachable with a real value
- `discarded return`: Return value never consumed -- likely should be `sig { ... .void }`
- `collection no elements`: Collection never observed holding an element -- only-empty, or built/consumed off any instrumented path
- `struct unobserved`: Struct/class field never observed assigned during collect -- the tracer signal for fields is struct_field_runtime/ivar_runtime, not line coverage, so the method-oriented coverage split does not apply. Either the class is never constructed by the workload, or the field is always left at its default.
- 1 unseen
  - src/mir/mir_lowering.rb:3250 `MIRLowering#importable_module_item?` param `item`
- 53 arg untraced
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls` param `block`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls` param `block`
  - src/annotator/helpers/capabilities.rb:1102 `CapabilityHelper#with_fiber_capture_analysis` param `blk`
  - src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves` param `blk`
  - src/annotator/helpers/capabilities.rb:41 `Capabilities#validate!` param `error_handler`
  - src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!` param `kwargs`
  - src/annotator/helpers/pipe_analysis.rb:146 `PipeAnalysis#lift_to_observable_if_terminal!` param `type_kwargs`
  - src/annotator/helpers/pipe_analysis.rb:165 `PipeAnalysis#mark_observable_terminal!` param `type_kwargs`
  - src/annotator/helpers/pipe_analysis.rb:1845 `PipeAnalysis#with_soa_tracking` param `blk`
  - src/ast/ast.rb:1069 `AST::Locatable#finalize_storage!` param `schema_lookup`
  - src/ast/ast.rb:118 `AST#initialize` param `kw`
  - src/ast/ast.rb:1341 `AST#initialize` param `args`
  - src/ast/ast.rb:145 `AST#initialize` param `kw`
  - src/ast/ast.rb:1540 `AST#initialize` param `kw`
  - src/ast/ast.rb:1567 `AST#initialize` param `args`
  - src/ast/ast.rb:1591 `AST#initialize` param `args`
  - src/ast/ast.rb:1644 `AST#initialize` param `args`
  - src/ast/ast.rb:1776 `AST#initialize` param `args`
  - src/ast/ast.rb:1806 `AST#initialize` param `args`
  - src/ast/ast.rb:1937 `AST#initialize` param `args`
  - src/ast/ast.rb:195 `AST#initialize` param `kw`
  - src/ast/ast.rb:2103 `AST#initialize` param `kw`
  - src/ast/ast.rb:2301 `AST#initialize` param `args`
  - src/ast/ast.rb:2334 `AST#initialize` param `args`
  - src/ast/ast.rb:2383 `AST#initialize` param `args`
  - src/ast/ast.rb:2440 `AST#initialize` param `args`
  - src/ast/ast.rb:254 `AST#initialize` param `kw`
  - src/ast/ast.rb:2562 `AST#initialize` param `args`
  - src/ast/ast.rb:307 `AST#initialize` param `kw`
  - src/ast/ast.rb:720 `AST#each_bg_block` param `block`
  - src/ast/ast.rb:727 `AST#_bg_visit_recursive` param `block`
  - src/ast/ast.rb:745 `AST#_expr_each_bg_block_recursive` param `block`
  - src/ast/ast.rb:777 `AST#each_bg_block_in_stmt` param `block`
  - src/ast/ast.rb:792 `AST#_expr_each_bg_block_shallow` param `block`
  - src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture` param `block`
  - src/ast/parser.rb:54 `ClearParser#stmt` param `block`
  - src/ast/parser.rb:70 `ClearParser#primary` param `block`
  - src/ast/parser.rb:85 `ClearParser#suffix` param `block`
  - src/ast/source_error.rb:141 `ErrorHelper#fixable!` param `kwargs`
  - src/ast/source_error.rb:31 `ErrorHelper#error!` param `kwargs`
  - src/ast/source_error.rb:76 `ErrorHelper#diagnostic_message` param `kwargs`
  - src/ast/type.rb:2695 `Type#slot_size` param `lookup_block`
  - src/ast/type.rb:2756 `Type#copyable?` param `lookup_block`
  - src/ast/type.rb:2788 `Type#bg_capture_is_value_copy?` param `lookup_block`
  - src/ast/type.rb:2815 `Type#implicitly_copyable?` param `lookup_block`
  - src/lsp/document_store.rb:83 `LSP::DocumentStore#each` param `block`
  - src/mir/cleanup_classifier.rb:766 `CleanupClassifier#each_capture_binding` param `block`
  - src/mir/cleanup_entry.rb:40 `CleanupEntry#build` param `extra`
  - src/mir/control_flow.rb:1707 `LoopFrameAnalysis#walk_all_nodes` param `block`
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents` param `block`
  - ... +3 more
- 1 only nil
  - src/mir/mir_checker.rb:351 `MIRChecker#initialize` param `fn_name`
- 5 discarded return
  - src/annotator/helpers/fixable_helpers.rb:1054 `FixableHelper#emit_with_materialized_needs_tense!` return
  - src/annotator/helpers/fixable_helpers.rb:898 `FixableHelper#emit_with_guard_all_bindings_need_as!` return
  - src/ast/parser.rb:614 `ClearParser#emit_consume_error_with_fix` return
  - src/ast/parser.rb:633 `ClearParser#emit_syntax_insert_end_of_line!` return
  - src/ast/parser.rb:661 `ClearParser#emit_syntax_insert_before_token!` return
- 65 collection no elements
  - src/annotator/helpers/capabilities.rb:22 `T.let` ``
  - src/annotator/helpers/generic_analysis.rb:308 `T.let` ``
  - src/ast/ast.rb:1318 `AST::Program.statements`
  - src/ast/ast.rb:1327 `AST::FunctionDef.captures`
  - src/ast/ast.rb:1562 `AST::StructDef.type_params`
  - src/ast/ast.rb:1931 `AST::WithBlock.body`
  - src/ast/ast.rb:2008 `AST::EachOp.body`
  - src/ast/ast.rb:23 `T.let` ``
  - src/ast/ast.rb:2525 `AST::BgStreamBlock.body`
  - src/ast/ast.rb:2556 `AST::MatchStatement.cases`
  - src/ast/ast.rb:2586 `AST::ForRange.body`
  - src/ast/ast.rb:2666 `AST::TestThat.body`
  - src/ast/ast.rb:2704 `T.let` ``
  - src/ast/ast.rb:2717 `T.let` ``
  - src/ast/ast.rb:2736 `T.let` ``
  - src/ast/parser.rb:3662 `T.let` ``
  - src/ast/parser.rb:3675 `T.let` ``
  - src/ast/parser.rb:384 `T.let` ``
  - src/ast/parser.rb:94 `T.let` ``
  - src/ast/std_lib.rb:1379 `T.let` ``
  - src/ast/syntax_typo_scanner.rb:34 `T.let` ``
  - src/backends/transpiler.rb:162 `ZigTranspiler#transpile_as_module` param `pkg_paths`
  - src/compiler/module_importer.rb:38 `T.let` ``
  - src/compiler/module_importer.rb:39 `T.let` ``
  - src/compiler/module_importer.rb:41 `T.let` ``
  - src/lsp/document_store.rb:39 `T.let` ``
  - src/lsp/server.rb:142 `LSP::Server#handle_initialize` param `_params`
  - src/lsp/server.rb:159 `LSP::Server#handle_initialized` param `_params`
  - src/lsp/server.rb:169 `LSP::Server#handle_shutdown` param `_params`
  - src/lsp/server.rb:45 `T.let` ``
  - src/mir/control_flow.rb:62 `T.let` ``
  - src/mir/control_flow.rb:63 `T.let` ``
  - src/mir/control_flow.rb:64 `T.let` ``
  - src/mir/control_flow.rb:87 `T.let` ``
  - src/mir/fsm_transform/liveness.rb:229 `T.let` ``
  - src/mir/fsm_transform/segments.rb:188 `T.let` ``
  - src/mir/hoist.rb:812 `T.let` ``
  - src/mir/hoist.rb:945 `T.let` ``
  - src/mir/lowering/control_flow.rb:105 `T.let` ``
  - src/mir/lowering/control_flow.rb:322 `T.let` ``
  - src/mir/lowering/expressions.rb:1160 `T.let` ``
  - src/mir/lowering/functions.rb:787 `MIRLoweringFunctions#build_post_inner_fn` param `comptime_params`
  - src/mir/lowering/functions.rb:798 `MIRLoweringFunctions#build_post_outer_fn` param `comptime_params`
  - src/mir/lowering/literals.rb:110 `T.let` ``
  - src/mir/lowering/variables.rb:1272 `T.let` ``
  - src/mir/lowering/variables.rb:1294 `T.let` ``
  - src/mir/mir_checker.rb:354 `T.let` ``
  - src/mir/mir_lowering.rb:3284 `T.let` ``
  - src/mir/mir_lowering.rb:3291 `T.let` ``
  - src/mir/test_lowering.rb:193 `T.let` ``
  - ... +15 more
- 12 struct unobserved
  - `AST::CatchClause` (src/ast/ast.rb:2097): 4 field(s) -- filter_messages, filter_types, kinds, types
  - `AST::Cast` (src/ast/ast.rb:1911): 2 field(s) -- target, value
  - `AST::Param` (src/ast/ast.rb:112): 2 field(s) -- default, type
  - `AST::Capture` (src/ast/ast.rb:139): 1 field(s) -- storage
  - `AST::MatchCase` (src/ast/ast.rb:189): 1 field(s) -- indirect_payload_as
  - `AST::Require` (src/ast/ast.rb:1927): 1 field(s) -- path
  - `MIR::DeepCopy` (src/mir/mir.rb:2839): 1 field(s) -- copy_shape

### Signature Slot Evidence
- primary reason: the single strongest current explanation for why this weak/untyped signature slot has not been safely strengthened
- evidence count: runtime observations plus static callsite/origin records feeding the slot
- candidate action: an existing nil-kill action that could rewrite this slot, if one exists

#### Param Slot Evidence
- blocked: unknown callsite expression: 235 slot(s); weak 0, untyped 235; evidence 4248
  - src/mir/mir_lowering.rb:1901 `MIRLowering#ownership_contract_source_node` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/mir_lowering.rb:1739 expr; src/mir/mir_lowering.rb:1758 expr; src/mir/mir_ ...; evidence 127
  - src/mir/mir_lowering.rb:2106 `MIRLowering#ownership_contract_for_node` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/hoist.rb:1040 expr; src/mir/mir_lowering.rb:2077 surface_node; protocol hint  ...; evidence 127
  - src/annotator/helpers/auto_inference.rb:242 `AutoConstraintCollector#record_constraint` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/annotator/helpers/auto_inference.rb:225 node; protocol hint dire ...; evidence 119
  - src/mir/mir_checker.rb:1029 `MIRChecker#collect_linear_expr_ident_names` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/mir_checker.rb:1011 node; src/mir/mir_checker.rb:1024 expr; src/mir/mir_che ...; evidence 103
  - src/mir/mir_checker.rb:992 `MIRChecker#check_nested_linear_expr_bodies!` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/mir_checker.rb:987 expr; src/mir/mir_checker.rb:1000 sub; protocol hint med ...; evidence 101
  - src/mir/hoist.rb:599 `MIRHoistLowering#each_mir_expr_in_value` value; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/hoist.rb:593 value; src/mir/hoist.rb:603 child; src/mir/hoist.rb:605 child; protocol ...; evidence 99
  - src/mir/hoist.rb:230 `Hoist#each_call_like` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/hoist.rb:218 node; src/mir/hoist.rb:226 node; src/mir/hoist.rb:247 c; protocol hint direct protocol: non ...; evidence 98
  - src/mir/hoist.rb:611 `MIRHoistLowering#mir_expr_child?` value; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/hoist.rb:600 value; protocol hint medium direct protocol #expr?; other potential options, n ...; evidence 97
- candidate: runtime-only param observation: 186 slot(s); weak 0, untyped 186; evidence 2484
  - src/ast/schemas.rb:244 Schemas::InlineStructVariant#== other; `T.untyped`; single observed type; narrow candidate; untyped instance variable; src/annotator/domains/control_flow.rb:65 :moved; src/annotator/domains/control_flow.rb:260 :Int64; s ...; evidence 1715
  - src/mir/fsm_transform/segments.rb:174 `FsmTransform::Segments#split` body; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/annotator/annotator.rb:701 '::'; src/annotator/domains/lifetimes.rb:504 "."; src/annot ...; evidence 47
  - src/backends/fsm_wrapper_emitter.rb:705 `FsmWrapperEmitter#indent_block` text; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/backends/fsm_wrapper_emitter.rb:95 capture_fields; src/backends/fsm_wrapper_emitte ...; evidence 46
  - src/ast/source_error.rb:141 `ErrorHelper#fixable!` raise_in_collector; `T.untyped`; boolean pair; T::Boolean candidate; untyped literal/static expression; src/annotator/domains/lifetimes.rb:698 true; src/annotator/domains/lifetimes.rb:767 true; ...; evidence 27
  - src/mir/fsm_transform.rb:301 `FsmTransform#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_transform.rb:295 body; src/mir/fsm_transform.rb:307 body; src/mir/fsm_trans ...; evidence 20
  - src/mir/fsm_transform/recursive_splitter.rb:310 `FsmTransform::RecursiveSplitter#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_transform.rb:295 body; src/mir/fsm_tr ...; evidence 20
  - src/mir/fsm_transform/segments.rb:322 `FsmTransform::Segments#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_transform.rb:295 body; src/mir/fsm_transform.rb:307 body ...; evidence 20
  - src/mir/mir_lowering.rb:556 `MIRLowering#place_value_for_destination` dest_type; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_lowering.rb:110 expr_t; src/mir/lowering/concurrency.rb:919 inner_t; src ...; evidence 17
- weak declared type: union: 155 slot(s); weak 155, untyped 0; evidence 459
  - src/semantic/ownership_identity.rb:34 `OwnershipIdentity::PlaceId#from_path` path; T.any(String, Symbol, PlaceId); weak declared type: union; untyped forwarded return; src/mir/cleanup_classifier.rb:66 name; src/mir/cleanup_classifier.rb:75 na ...; evidence 20
  - src/ast/ast.rb:613 `AST#child_bodies` node; T.nilable(T.any(AST::Node, Struct)); weak declared type: union; untyped unknown expression; src/mir/cleanup_classifier.rb:257 node; src/mir/cleanup_classifier.rb:280 node; src/mir/cleanup_classifier ...; evidence 15
  - src/ast/ast.rb:134 `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; src/annotator/domains/variables.rb:63 target_t; src/annotator/helpers/auto_inference.rb:623 Type.new(:"#{element_ ...; evidence 14
  - src/ast/ast.rb:1551 `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; src/annotator/domains/variables.rb:63 target_t; src/annotator/helpers/auto_inference.rb:623 Type.new(:"#{element ...; evidence 14
  - src/ast/ast.rb:1598 `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; src/annotator/domains/variables.rb:63 target_t; src/annotator/helpers/auto_inference.rb:623 Type.new(:"#{element ...; evidence 14
  - src/ast/ast.rb:163 `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; src/annotator/domains/variables.rb:63 target_t; src/annotator/helpers/auto_inference.rb:623 Type.new(:"#{element_ ...; evidence 14
  - src/ast/ast.rb:1651 `AST#type=` val; T.nilable(T.any(Type, Symbol, String)); weak declared type: union; untyped forwarded return; src/annotator/domains/variables.rb:63 target_t; src/annotator/helpers/auto_inference.rb:623 Type.new(:"#{element ...; evidence 14
  - src/semantic/ownership_graph.rb:502 `OwnershipGraph#place_id` path; T.any(String, PlaceId); weak declared type: union; untyped forwarded return; src/semantic/ownership_graph.rb:197 path; src/semantic/ownership_graph.rb:215 to; src/semantic/ow ...; evidence 14
- blocked: forwarded return argument: 142 slot(s); weak 0, untyped 142; evidence 4963
  - src/ast/source_error.rb:31 `ErrorHelper#error!` node_or_token; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator/annotator.rb:523 node; src/annotator/domains/control_flow.rb:161 b.expr; src/annotator/ ...; evidence 467
  - src/backends/mir_emitter.rb:55 `MIREmitter#emit` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/backends/fsm_wrapper_emitter.rb:240 stmt; src/backends/fsm_wrapper_emitter.rb:525 s.alloc_expr; src/backe ...; evidence 342
  - src/mir/mir_lowering.rb:918 `MIRLowering#lower` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/mir/fsm_lowering.rb:109 last_step.expr; src/mir/fsm_lowering.rb:309 step.expr; src/mir/fsm_lowering.rb:489 ...; evidence 264
  - src/annotator/helpers/auto_inference.rb:215 `AutoConstraintCollector#walk` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator/helpers/auto_inference.rb:173 program_node; src/annotator/helpers/aut ...; evidence 149
  - src/ast/type.rb:3104 `Type#from_node!` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator/domains/lifetimes.rb:155 node.value; src/annotator/domains/lifetimes.rb:632 info.type; src/annotator/doma ...; evidence 141
  - src/mir/mir_lowering.rb:1886 `MIRLowering#ownership_fact_source` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/mir/mir_checker.rb:2416 fact; src/mir/mir_lowering.rb:1613 alloc_mark; src/mir/mir_loweri ...; evidence 138
  - src/mir/hoist.rb:570 `MIRHoistLowering#mir_allocates?` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/mir/fsm_lowering.rb:111 last_mir; src/mir/hoist.rb:521 expr; src/mir/hoist.rb:576 child; protocol h ...; evidence 100
  - src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/ast/ast.rb:834 node; src/ast/ast.rb:847 node.left; src/ast/ast.rb:848 node.right; protocol hint str ...; evidence 90
- weak declared type: array element evidence needed: 94 slot(s); weak 94, untyped 0; evidence 441
  - src/backends/mir_emitter.rb:2841 `MIREmitter#emit_body` stmts; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/backends/mir_emitter.rb:233 plan.promoted_decls; src/backends/mir_emitter.rb: ...; evidence 31
  - src/ast/parser.rb:70 `ClearParser#primary` pattern; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; src/ast/parser.rb:229 ['CAST', '(', :expression, 'AS', :type_annotation, ')'];  ...; evidence 30
  - src/mir/mir_checker.rb:570 `MIRChecker#check_linear_stmts!` stmts; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/mir/mir_checker.rb:561 body; src/mir/mir_checker.rb:658 stmt.body; src/mi ...; evidence 25
  - src/ast/diagnostic_registry.rb:2987 `DiagnosticRegistry#format` args; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/mir/lowering/capabilities.rb:884 b; src/mir/pre_mir_type_check.rb:46 n ...; evidence 18
  - src/ast/ast.rb:28 `AST::BodySlot#replace` body; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/mir/hoist.rb:924 normalize_allocating_mir_body(slot.body); src/mir/mir_checker.rb:954 source ...; evidence 15
  - src/mir/mir_checker.rb:1048 `MIRChecker#verify_move_mark_scope!` body; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/mir/mir_checker.rb:449 fn_def.body; src/mir/mir_checker.rb:1059 stmt. ...; evidence 13
  - src/semantic/local_binding_facts.rb:47 `MIR::LocalBindingAnalysis#each_direct_loop_node` body; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/mir/cleanup_classifier.rb:292 body; src/mir/c ...; evidence 13
  - src/mir/control_flow.rb:126 `FunctionCFG#build_body` stmts; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/mir/control_flow.rb:113 fn_node.body || []; src/mir/control_flow.rb:139 stmt.the ...; evidence 11
- blocked: no static callsite evidence: 74 slot(s); weak 0, untyped 74; evidence 135
  - src/mir/lowering/control_flow.rb:1206 `MIRLoweringControlFlow#call_union_return_needs_hoist?` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none ...; evidence 24
  - src/mir/lowering/control_flow.rb:1206 `MIRLoweringControlFlow#call_union_return_needs_hoist?` ast_node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint strong direct pro ...; evidence 21
  - src/mir/mir.rb:2720 `MIR#initialize` source; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 14
  - src/mir/mir.rb:2853 `MIR#initialize` source; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 12
  - src/ast/symbol_entry.rb:471 `SymbolEntry#initialize` reg; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in @reg ...; evidence 10
  - src/mir/mir.rb:3649 `MIR#initialize` receiver; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 7
  - src/mir/mir.rb:2698 `MIR#initialize` init; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; evidence 6
  - src/ast/fixable_error.rb:99 `FixableFinding#initialize` token; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in ...; evidence 5
- weak declared type: hash key/value evidence needed: 36 slot(s); weak 36, untyped 0; evidence 87
  - src/annotator/helpers/generic_analysis.rb:368 `GenericAnalysis#apply_type_subst` subst; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; src/annotator/domains/control_flow.rb:295 union_ ...; evidence 10
  - src/mir/mir_checker.rb:2288 `MIRChecker#verify_callable_contract!` allocs; T::Hash[String, T::Array[`T.untyped`]]; weak declared type: hash key/value evidence needed; untyped unknown expression; src/mir/mir_checker.rb:2275 allocs; src/mir/mir_c ...; evidence 5
  - src/mir/test_lowering.rb:299 `TestLowering#collect_identifier_refs` name_set; T::Hash[String, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/mir/test_lowering.rb:275 let_ast_map; src ...; evidence 5
  - src/annotator/domains/errors.rb:350 `Annotator::Domains::Errors#emit_error_type_conflict!` conflict; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped unknown expression; src/annotator/domains/errors.rb:3 ...; evidence 3
  - src/annotator/helpers/generic_analysis.rb:337 `GenericAnalysis#extract_type_bindings!` subst; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/annotator/helpers/generic ...; evidence 3
  - src/annotator/helpers/reentrance.rb:667 `ReentranceBridge#compute_reachable` graph; T::Hash[String, T::Set[`T.untyped`]]; weak declared type: hash key/value evidence needed; untyped forwarded return; src/annotator/helpers/reentrance.rb:655 func ...; evidence 3
  - src/ast/parser.rb:3105 `ClearParser#apply_element_capability!` result; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/ast/parser.rb:3086 result; src/ast/parser.rb:308 ...; evidence 3
  - src/ast/source_error.rb:59 `ErrorHelper#format_diagnostic_template` kwargs; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped unknown expression; src/ast/source_error.rb:44 kwargs; src/ast/source_error.rb ...; evidence 3
- weak declared type: nested `T.untyped`: 17 slot(s); weak 17, untyped 0; evidence 9
  - src/mir/hoist.rb:230 `Hoist#each_call_like` matches; `T.proc`.params(candidate: `T.untyped`).returns(T::Boolean); weak declared type: nested `T.untyped`; untyped unknown expression; src/mir/hoist.rb:218 ->(candidate) { candidate.is_a?(AST::MethodCa ...; evidence 6
  - src/mir/hoist.rb:245 `Hoist#each_call_like_child` matches; `T.proc`.params(candidate: `T.untyped`).returns(T::Boolean); weak declared type: nested `T.untyped`; untyped unknown expression; src/mir/hoist.rb:240 matches; evidence 2
  - src/ast/ast.rb:22 `AST::BodySlot#initialize` writer; `T.proc`.params(body: T::Array[`T.untyped`]).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 1
  - src/ast/ast.rb:384 `AST#walk_body` visitor; `T.proc`.params(node: `T.untyped`).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/ast/parser.rb:3928 `ClearParser#parse_comma_seq` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/ast/scope.rb:502 `ScopeHelper#with_new_scope` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/mir/hoist.rb:217 `Hoist#each_method_call` blk; `T.proc`.params(arg0: `T.untyped`).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/mir/hoist.rb:225 `Hoist#each_call` blk; `T.proc`.params(arg0: `T.untyped`).void; weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
- blocked: runtime union policy: 11 slot(s); weak 0, untyped 11; evidence 2204
  - src/ast/type.rb:1429 Type#== other; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped instance variable; src/annotator/domains/control_flow.rb:65 :moved; src/annotator/domains/control_flow.rb:260 :Int64; src/annotator/domains/cont ...; evidence 1716
  - src/ast/source_error.rb:31 `ErrorHelper#error!` code_or_message; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/annotator/annotator.rb:523 :WITH_SNAPSHOT_BODY_NOT_PURE; src/annotator/domains/control ...; evidence 403
  - src/mir/hoist.rb:1174 `MIRHoistLowering#hoist_cleanup_entry` ast_node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/mir/hoist.rb:637 ast_node; src/mir/hoist.rb:752 nil; src/mir/hoist.rb:998 nil; p ...; evidence 32
  - src/mir/rewriters/pipeline_rewriter.rb:291 `PipelineRewriter#fuse_pipeline` terminal; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/mir/rewriters/pipeline_rewriter.rb:170 terminal; src/mir/rewriter ...; evidence 14
  - src/backends/fsm_wrapper_emitter.rb:45 `FsmWrapperEmitter#render` body; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/backends/mir_emitter.rb:288 plan; src/lsp/server.rb:258 doc; src/mir/fsm_ops.rb ...; evidence 8
  - src/mir/hoist.rb:1220 `MIRHoistLowering#deep_copy_zig_type` ast_node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/mir/hoist.rb:666 nil; src/mir/hoist.rb:1191 ast_node; protocol hint direct protoc ...; evidence 8
  - src/mir/cleanup_classifier.rb:1187 `CleanupClassifier#classify_struct_cleanup_fields` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/mir/cleanup_classifier.rb:587 nil; src/mir/cleanup_classifi ...; evidence 7
  - src/lsp/document_store.rb:30 `LSP::DocumentStore#cached_findings=` value; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/lsp/document_store.rb:56 nil; src/lsp/server.rb:271 result; protocol hint dir ...; evidence 6
- blocked: collection/hash argument evidence: 7 slot(s); weak 0, untyped 7; evidence 82
  - src/mir/mir_lowering.rb:1331 `MIRLowering#materialize_statement_discard` stmt; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/mir/lowering/concurrency.rb:907 expr; src/mir/mir_lowering.rb:1310 s ...; evidence 34
  - src/annotator/helpers/pipe_analysis.rb:1277 `PipeAnalysis#each_shard_scan_node` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/annotator/helpers/pipe_analysis.rb:1176 node; src/annotator/h ...; evidence 16
  - src/mir/fsm_ops.rb:487 `FsmOps#walk` block; `T.untyped`; slot not observed: source index did not model this param shape; untyped struct/array/collection value; src/annotator/helpers/auto_inference.rb:723 name_map; src/annotator/helpers/auto_inf ...; evidence 14
  - src/mir/control_flow.rb:1707 `LoopFrameAnalysis#walk_all_nodes` nodes; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/mir/control_flow.rb:1718 body; src/mir/control_flow.rb:1742 expr; protocol h ...; evidence 7
  - src/annotator/helpers/fixable_helpers.rb:68 `FixableHelper#closest_name` candidates; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/annotator/helpers/fixable_helpers.rb:112 candidates; src/annot ...; evidence 5
  - src/mir/fsm_transform/segments.rb:219 `FsmTransform::Segments#split_while_loop_next` body; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/mir/fsm_transform/segments.rb:181 body; protocol hint me ...; evidence 3
  - src/mir/fsm_transform/segments.rb:406 `FsmTransform::Segments#rewrite_pipeline_io` body; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/mir/fsm_transform/segments.rb:179 body; protocol hint weak ...; evidence 3
- weak declared type: collection element evidence needed: 2 slot(s); weak 2, untyped 0; evidence 6
  - src/annotator/helpers/fixable_helpers.rb:1540 `FixableHelper#build_auto_op_evidence_block` ops; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; src/annotator/helpers/fixable_he ...; evidence 3
  - src/annotator/helpers/with_match_check.rb:359 `WithMatchCheck#expand_snapshotted` family_set; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped forwarded return; src/annotator/domains/execution_boundaries.rb:5 ...; evidence 3

#### Return Slot Evidence
- blocked: forwarded return chain: 71 slot(s); weak 0, untyped 71; evidence 986
  - src/ast/parser.rb:1911 `ClearParser#parse_unary` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; static AST::UnaryOp.new(op_token, AST::OP_TO_OP_CODE[v], right); static AST::CallSiteOverride.new(sigil_tok ...; evidence 63
  - src/ast/parser.rb:2473 `ClearParser#parse_primary` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped instance_exec(&rule); call_untyped parse_unary(); call_untyped parse_suffixes(lit); evidence 63
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped lower_next_expr(node.value, decl_alloc); call_untyped place_value_ ...; evidence 60
  - src/ast/parser.rb:719 `ClearParser#parse_statement` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown result; call_untyped instance_exec(&rule); unknown expr; evidence 45
  - src/mir/mir_lowering.rb:2592 `MIRLowering#with_decl_alloc` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped blk.call; evidence 41
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; nil return; nil return; nil return; evidence 30
  - src/mir/lowering/control_flow.rb:937 `MIRLoweringControlFlow#heap_carry_return_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown value; unknown value; unknown value; evidence 27
  - src/mir/lowering/control_flow.rb:919 `MIRLoweringControlFlow#return_payload_pointer_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown value; unknown value; unknown value; evidence 26
- weak declared type: array element evidence needed: 50 slot(s); weak 50, untyped 0; evidence 148
  - src/ast/ast.rb:680 `AST#expression_children` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; static []; static []; typed_call [node.value].compact; evidence 16
  - src/mir/rewriters/pipeline_rewriter.rb:393 `PipelineRewriter#build_init` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [decl]; static [sum_decl, cnt_decl]; static ...; evidence 9
  - src/mir/rewriters/pipeline_rewriter.rb:489 `PipelineRewriter#build_recursive_body` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; typed_call build_terminal_action(terminal, current_va ...; evidence 9
  - src/mir/hoist.rb:115 `Hoist#child_bodies` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [stmt.body]; static [stmt.do_branch]; typed_call [stmt.then_branch, stmt.e ...; evidence 7
  - src/ast/ast.rb:663 `AST#wrapped_children` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; typed_call (expr.fields&.values || []).compact; call_untyped (expr.items || []).compact; stati ...; evidence 6
  - src/mir/hoist.rb:256 `Hoist#non_body_exprs` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [node.condition]; static [node.start_expr, node.end_expr]; static [node. ...; evidence 6
  - src/ast/parser.rb:1647 `ClearParser#parse_effects_decl` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [nil, nil]; static [:reentrant, { start_tok: span_start, end ...; evidence 5
  - src/ast/error_registry.rb:126 `AST#register_type!` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [false, nil]; static [true, nil]; static [true, { existing_kind:  ...; evidence 4
- weak declared type: union: 35 slot(s); weak 35, untyped 0; evidence 79
  - src/annotator/domains/member_access.rb:425 `Annotator::Domains::MemberAccess#visit_ListLit` return; T.nilable(T.any(Symbol, Type)); weak declared type: union; untyped literal/static expression; nil return; nil return; nil return; evidence 5
  - src/mir/lower/pipeline/pipeline_host.rb:536 `PipelineHost#visit` return; T.any(String, MIR::Node); weak declared type: union; untyped forwarded return; typed_call visit_mir(node); unknown replacement; static "__soa_#{target.field}[__soa_i]"; evidence 5
  - src/mir/mir.rb:1498 `MIR::MutualThunkArm#fetch` return; T.any(String, T::Array[ThunkBaseCase], T::Array[ThunkFrameInit]); weak declared type: union; untyped forwarded return; static variant_name; call_untyped base_cases; call_untyped target_v ...; evidence 5
  - src/mir/lowering/concurrency.rb:1000 `MIRLoweringConcurrency#lower_bg_stream_block` return; T.any(MIR::BgBlock, MIR::BlockExpr, MIR::InlineBc, MIR::StreamSpawn); weak declared type: union; untyped literal/static expression; unknown spawn; sta ...; evidence 4
  - src/mir/lowering/expressions.rb:675 `MIRLoweringExpressions#union_variant_key` return; T.nilable(T.any(String, Symbol)); weak declared type: union; untyped struct/array/collection value; static field; static field_s; static field_sym; evidence 4
  - src/mir/lowering/functions.rb:258 `MIRLoweringFunctions#lower_extern_struct` return; T.any(MIR::Node, T::Array[MIR::Node]); weak declared type: union; untyped forwarded return; call_untyped T.must(items.first); unknown items; static MIR::Noop ...; evidence 4
  - src/annotator/domains/lifetimes.rb:1036 `Annotator::Domains::Lifetimes#get_lifetime_paths` return; T::Array[T.any(String, Symbol)]; weak declared type: union; untyped forwarded return; static []; static [:wildcard]; call_untyped sources.filte ...; evidence 3
  - src/mir/lowering/capabilities.rb:584 `MIRLoweringCapabilities#lower_with_block` return; T.any(MIR::BlockExpr, MIR::ScopeBlock); weak declared type: union; untyped literal/static expression; typed_call lower_with_match_block(node); typed_call  ...; evidence 3
- candidate: runtime-only return observation: 30 slot(s); weak 0, untyped 30; evidence 98
  - src/annotator/helpers/intrinsic_registry.rb:117 `IntrinsicRegistry#to_return_def` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; typed_call_inferred FunctionReturn.fixed(Type.new(:Void)); typed_c ...; evidence 7
  - src/backends/mir_emitter.rb:1666 `MIREmitter#reassign_success_only_expr` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; nil nil; nil nil; candidate action fix_sig_return (review); evidence 7
  - src/annotator/helpers/intrinsic_registry.rb:221 `IntrinsicRegistry#fs` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; unknown x; typed_call convert_entry(name, x, registries); candidate  ...; evidence 6
  - src/annotator/helpers/intrinsic_registry.rb:72 `IntrinsicRegistry#nested_emit` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; static IntrinsicEmit.new(registry: name || :unknown); static ...; evidence 6
  - src/mir/mir_lowering.rb:2697 `MIRLowering#root_receiver_node` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil nil; unknown root; call_untyped root_receiver_node(node.target); candidate action fix_sig_r ...; evidence 6
  - src/ast/source_error.rb:141 `ErrorHelper#fixable!` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil return; call_untyped $stderr.puts "#{tag} #{rendered_message}#{loc}"; typed_call raise err_class.new(t ...; evidence 5
  - src/annotator/helpers/fixable_helpers.rb:987 `FixableHelper#emit_with_read_needs_write_lock!` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; typed_call_inferred error!(node, :WITH_READ_NEEDS_WRITE_LOCK, n ...; evidence 4
  - src/annotator/helpers/intrinsic_registry.rb:162 `IntrinsicRegistry#normalize_lifetime` return; `T.untyped`; single observed type; narrow candidate; untyped struct/array/collection value; static []; unknown value; static [value]; candidate actio ...; evidence 4
- blocked: runtime union policy: 29 slot(s); weak 0, untyped 29; evidence 325
  - src/mir/mir_lowering.rb:1901 `MIRLowering#ownership_contract_source_node` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static current; evidence 119
  - src/mir/mir_checker.rb:1369 `MIRChecker#ownership_source_expr` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static current; evidence 30
  - src/ast/parser.rb:2934 `ClearParser#parse_concurrent_inner_op` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static AST::SelectOp.new(previous, expr); static AST::WhereOp.new(previous, expr); t ...; evidence 17
  - src/mir/lowering/expressions.rb:227 `MIRLoweringExpressions#lower_identifier` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::FnRef.new(zig_safe_name(node.name)); static `MIR::Ident.ne` ...; evidence 13
  - src/ast/parser.rb:999 `ClearParser#parse_visibility_decl` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; typed_call parse_function_def(visibility); typed_call parse_function_def(visibility, is_m ...; evidence 10
  - src/mir/test_lowering.rb:325 `TestLowering#stub_intercept_for` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; nil nil; static MIR::Ident.new(stub_info[:var]); static MIR::BlockExpr.new(label, su ...; evidence 10
  - src/mir/lowering/expressions.rb:187 `MIRLoweringExpressions#lower_literal` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::Lit.new("\"#{escaped}\""); static MIR::Lit.new(node.value.to ...; evidence 9
  - src/mir/lowering/expressions.rb:692 `MIRLoweringExpressions#lower_smooth` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; typed_call lower_complex_smooth(node); typed_call lower_collect_smooth(no ...; evidence 9
- blocked: unknown return expression: 26 slot(s); weak 0, untyped 26; evidence 439
  - src/mir/mir_lowering.rb:918 `MIRLowering#lower` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown mir; typed_call apply_lowered_coercion(mir, node); evidence 79
  - src/ast/parser.rb:1754 `ClearParser#parse_expression` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown lhs; evidence 61
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown init; unknown init; unknown init; evidence 43
  - src/semantic/escape_analysis.rb:579 `EscapeAnalysis#unwrap_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown current; evidence 37
  - src/mir/hoist.rb:624 `MIRHoistLowering#hoist_alloc` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown expr; unknown expr; static MIR::Ident.new(plan.name); evidence 27
  - src/mir/lowering/control_flow.rb:950 `MIRLoweringControlFlow#heap_carry_recursive_param_value` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown value; unknown value; unknown value; evidence 26
  - src/ast/parser.rb:1942 `ClearParser#parse_suffixes` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown lhs; evidence 19
  - src/mir/rewriters/pipeline_rewriter.rb:783 `PipelineRewriter#replace_placeholder` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown node; typed_call replacement.dup; unknown new_node; evidence 13
- weak declared type: hash key/value evidence needed: 20 slot(s); weak 20, untyped 0; evidence 42
  - src/ast/parser.rb:3081 `ClearParser#parse_element_capability` return; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; static result; static result; static result; candidat ...; evidence 4
  - src/annotator/helpers/effects.rb:250 `EffectTracker#compute_effects!` return; T::Hash[`T.untyped`, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; call_untyped fn_nodes.each do |name, fn_node| fn_node.e ...; evidence 2
  - src/annotator/helpers/effects.rb:499 `EffectTracker#compute_can_fail!` return; T::Hash[`T.untyped`, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; call_untyped fn_nodes.each do |name, fn_node| ef = (er ...; evidence 2
  - src/annotator/helpers/effects.rb:801 `EffectTracker#compute_fsm_eligibility!` return; T::Hash[`T.untyped`, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; call_untyped fn_nodes.each do |_name, fn_node|  ...; evidence 2
  - src/annotator/helpers/effects.rb:834 `EffectTracker#enumerate_fsm_suspend_points!` return; T::Hash[`T.untyped`, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; call_untyped fn_nodes.each do |_name, fn_n ...; evidence 2
  - src/annotator/helpers/generic_analysis.rb:286 `GenericAnalysis#infer_generic_type_args!` return; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped unknown expression; unknown subst; candidate action narro ...; evidence 2
  - src/annotator/helpers/intrinsic_registry.rb:194 `IntrinsicRegistry#sigs` return; T::Hash[`T.untyped`, LookupResult]; weak declared type: hash key/value evidence needed; untyped unknown expression; unknown SIGS_CACHE[reg.object_id] ||= reg.each_ ...; evidence 2
  - src/annotator/helpers/reentrance.rb:391 `ReentranceBridge#validate_max_depth_mutual_cycle!` return; T::Hash[`T.untyped`, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped forwarded return; call_untyped fn_nodes.each do |na ...; evidence 2
- candidate: void return: 6 slot(s); weak 0, untyped 6; evidence 40
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped check_reads_in_expr(stmt.value, state); call_untyped check_reads_in_exp ...; evidence 14
  - src/ast/ast.rb:777 `AST#each_bg_block_in_stmt` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; unknown yield stmt; typed_call _expr_each_bg_block_shallow(stmt.value, &block); nil implicit else; candid ...; evidence 9
  - src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped blk.call; candidate action fix_sig_return (review); evidence 5
  - src/ast/scope.rb:383 `Scope#mark_read` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; nil return; call_untyped entry.mark_read!; candidate action fix_sig_return (review); evidence 5
  - src/annotator/annotator.rb:714 `SemanticAnnotator#visit_Program` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped finalize_program_semantics!(node); candidate action fix_sig_return (review ...; evidence 4
  - src/mir/cleanup_classifier.rb:766 `CleanupClassifier#each_capture_binding` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped AST.walk_body(body) do |node| case node when AST::WhileBindLoop  ...; evidence 3
- blocked: collection/field return evidence: 5 slot(s); weak 0, untyped 5; evidence 40
  - src/mir/control_flow.rb:956 `OwnershipDataflow#transfer_stmt` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call update_declared_owner!(state, stmt.name.to_s, stmt); typed_call update ...; evidence 16
  - src/mir/mir_lowering.rb:2853 `MIRLowering#lower_union_def` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call helper_structs + [generic_fn]; unknown generic_fn; typed_call helper_stru ...; evidence 7
  - src/mir/test_lowering.rb:392 `TestLowering#lower_stub_decl` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static MIR::Let.new(stub_var, val, false, nil, nil); static MIR::Let.new(cap_name,  ...; evidence 7
  - src/annotator/helpers/generic_analysis.rb:337 `GenericAnalysis#extract_type_bindings!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; unknown subst[p_res] = actual_binding; typed_call param_ ...; evidence 6
  - src/mir/lowering/control_flow.rb:968 `MIRLoweringControlFlow#return_with_transfer_marks` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static ret; typed_call marks + [ret]; candidate action ...; evidence 4
- weak declared type: nested `T.untyped`: 2 slot(s); weak 2, untyped 0; evidence 13
  - src/mir/hoist.rb:990 `MIRHoistLowering#normalize_allocating_used_expr` return; [T::Array[MIR::Node], `T.untyped`]; weak declared type: nested `T.untyped`; untyped struct/array/collection value; static [prefix, expr]; static [prefix, expr]; static ...; evidence 8
  - src/mir/mir_lowering.rb:1331 `MIRLowering#materialize_statement_discard` return; [`T.untyped`, T::Boolean]; weak declared type: nested `T.untyped`; untyped struct/array/collection value; static [mir, false]; static [mir, false]; static [mir, fals ...; evidence 5
- nil only observed: 1 slot(s); weak 0, untyped 1; evidence 3
  - src/ast/ast.rb:792 `AST#_expr_each_bg_block_shallow` return; `T.untyped`; nil only observed; untyped literal/static expression; nil return; nil nil; candidate action fix_sig_return (review); evidence 3
- slot not observed: method hit but return was not captured: 1 slot(s); weak 0, untyped 1; evidence 1
  - src/ast/source_error.rb:31 `ErrorHelper#error!` return; `T.untyped`; slot not observed: method hit but return was not captured; untyped literal/static expression; typed_call raise err_class.new(token, message, T.cast(T.unsafe(self).instance_var ...; evidence 1
- weak declared type: collection element evidence needed: 1 slot(s); weak 1, untyped 0; evidence 3
  - src/annotator/helpers/with_match_check.rb:359 `WithMatchCheck#expand_snapshotted` return; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; static family_set; static out; candida ...; evidence 3

### Return Hygiene
- control shape: whether the method return is branchless or depends on branching control flow
- return syntax: whether the method uses implicit return, explicit `return`, or a mix
- return value usage: whether static callsites use this method's return value, forward it, or ignore it
- return source kind: the kind of expression that produces the return value
- fixability: the report's estimate of whether the return is already addressed, directly fixable, cascading, or needs more evidence
- row percent: share of all return slots; strength percents: share within that row
- Return slots indexed: 5414
- Return slot strength: strong 5137 (94.9%); weak 108 (2.0%); untyped 169 (3.1%); nilable 779 (14.4%)

#### Control Shape

- branchless: total 3399 (62.8%) of all returns; strong 3301 (97.1%); weak 56 (1.6%); untyped 42 (1.2%); nilable 335 (9.9%) within row
- branching: total 2015 (37.2%) of all returns; strong 1836 (91.1%); weak 52 (2.6%); untyped 127 (6.3%); nilable 444 (22.0%) within row

#### Return Syntax

- implicit: total 3984 (73.6%) of all returns; strong 3825 (96.0%); weak 80 (2.0%); untyped 79 (2.0%); nilable 411 (10.3%) within row
- mixed: total 1424 (26.3%) of all returns; strong 1309 (91.9%); weak 28 (2.0%); untyped 87 (6.1%); nilable 366 (25.7%) within row
- explicit: total 6 (0.1%) of all returns; strong 3 (50.0%); weak 0 (0.0%); untyped 3 (50.0%); nilable 2 (33.3%) within row

#### Return Value Usage

- used as value: total 3198 (59.1%) of all returns; strong 2975 (93.0%); weak 70 (2.2%); untyped 153 (4.8%); nilable 541 (16.9%) within row
- ambiguous method name: total 1051 (19.4%) of all returns; strong 1016 (96.7%); weak 26 (2.5%); untyped 9 (0.9%); nilable 110 (10.5%) within row
- declared void: total 822 (15.2%) of all returns; strong 822 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- no static callsites found: total 177 (3.3%) of all returns; strong 172 (97.2%); weak 3 (1.7%); untyped 2 (1.1%); nilable 54 (30.5%) within row
- unused statement-only: total 151 (2.8%) of all returns; strong 138 (91.4%); weak 9 (6.0%); untyped 4 (2.6%); nilable 71 (47.0%) within row
- unused via return-forwarding: total 11 (0.2%) of all returns; strong 10 (90.9%); weak 0 (0.0%); untyped 1 (9.1%); nilable 3 (27.3%) within row
- declared noreturn: total 4 (0.1%) of all returns; strong 4 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row

#### Return Source Kind

- collection lookup: total 1489 (27.5%) of all returns; strong 1368 (91.9%); weak 76 (5.1%); untyped 45 (3.0%); nilable 129 (8.7%) within row
- literal/static: total 1356 (25.0%) of all returns; strong 1336 (98.5%); weak 6 (0.4%); untyped 14 (1.0%); nilable 208 (15.3%) within row
- implicit/direct forwarded return: total 840 (15.5%) of all returns; strong 788 (93.8%); weak 15 (1.8%); untyped 37 (4.4%); nilable 160 (19.0%) within row
- Ruby stdlib call: total 584 (10.8%) of all returns; strong 581 (99.5%); weak 0 (0.0%); untyped 3 (0.5%); nilable 53 (9.1%) within row
- unknown source: total 510 (9.4%) of all returns; strong 493 (96.7%); weak 8 (1.6%); untyped 9 (1.8%); nilable 68 (13.3%) within row
- mixed sources: total 330 (6.1%) of all returns; strong 313 (94.8%); weak 2 (0.6%); untyped 15 (4.5%); nilable 84 (25.5%) within row
- mixed/direct forwarded return: total 249 (4.6%) of all returns; strong 205 (82.3%); weak 1 (0.4%); untyped 43 (17.3%); nilable 66 (26.5%) within row
- mutation/setter assignment: total 51 (0.9%) of all returns; strong 51 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 11 (21.6%) within row
- explicit/direct forwarded return: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row
- struct/class field or instance variable: total 2 (0.0%) of all returns; strong 2 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row

#### Fixability

- addressed: strong: total 4311 (79.6%) of all returns; strong 4311 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 769 (17.8%) within row
- addressed: void: total 822 (15.2%) of all returns; strong 822 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- addressed: weak: total 108 (2.0%) of all returns; strong 0 (0.0%); weak 108 (100.0%); untyped 0 (0.0%); nilable 10 (9.3%) within row
- cascade: forwarded return: total 43 (0.8%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 43 (100.0%); nilable 0 (0.0%) within row
- review action: void from runtime_void: total 17 (0.3%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 17 (100.0%); nilable 0 (0.0%) within row
- manual review: total 11 (0.2%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 11 (100.0%); nilable 0 (0.0%) within row
- needs collection/field evidence: total 8 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 8 (100.0%); nilable 0 (0.0%) within row
- review action: Array from review: total 7 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 7 (100.0%); nilable 0 (0.0%) within row
- addressed: noreturn: total 4 (0.1%) of all returns; strong 4 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- missing action: static/RBI candidate T.any(MIR::Deref, MIR::FieldGet, MIR::Ident): total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: Integer from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::IfBind, AST::IfStatement) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, MIR::Let) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, MIR::ReturnStmt) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(FalseClass, Lexer::Token) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::IfStmt, MIR::ScopeBlock) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::StructInit) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ForStmt, MIR::ScopeBlock, MIR::WhileStmt) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(FunctionSignature) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(FsmTransform::Segments::IoSuspend, FsmTransform::Segments::NextSuspend)) from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: Type from review: total 2 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- auto-fixable: MIR::DefaultValue: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- missing action: no singular static/RBI candidate: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: AST::Identifier from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: AST::ReturnNode from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: FunctionReturn from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: String from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BatchWindowOp, AST::WindowOp) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BgBlock, AST::BgStreamBlock) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BinaryOp, AST::GetField, AST::Identifier) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BinaryOp, AST::RangeLit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BlockExpr, AST::ForEach) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::CapabilityWrap, AST::Literal, AST::MethodCall) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::ExternFnDecl, AST::ExternStructDecl) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::ForEach, AST::ForRange) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::ForEach, AST::ForRange, AST::WhileLoop) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::GetField, AST::Identifier, AST::Literal) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::WhileBindLoop, AST::WhileLoop) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, MIR::FnDef, MIR::UnionTypeDef) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, Module) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(IO, StringIO) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::CapWrap, MIR::ContainerInit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::MethodCall, MIR::NextPromiseList) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Call, MIR::DupeSlice) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Call, MIR::ExternTrampoline) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::CapWrap, MIR::Ident) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::CapWrap, MIR::RcRetain, MIR::SharePromote) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Cast, MIR::Lit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ExprStmt, MIR::ScopeBlock) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::FnDef, MIR::StructDef) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::FnRef, MIR::Ident, MIR::MethodCall) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Ident, MIR::Lit, MIR::RegistryCall) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ScopeBlock, MIR::Set) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Module, Symbol, Type) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(AST::Identifier) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(Array) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(IntrinsicEmit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(Lexer::Token) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(MIR::Call) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(Symbol) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(AST::Assignment, AST::BindExpr)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, CapabilityHelper::CaptureAnalysis)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Hash, Module)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Module, OwnershipDataflow::OwnerEntry)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Set, TrueClass)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Type)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(FixableHelper::AnchorToken, Lexer::Token, `T.untyped`)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(FunctionSignature, Symbol)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(IO, StringIO, Thread)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(LSP::Analyzer::SyntheticFinding, StubFinding)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(MIR::BlockExpr, MIR::Call, MIR::Ident)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Module, TrueClass)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(SymbolEntry, Type, TypePlacement)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: `T.noreturn` from noreturn_body: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[Integer] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[T::Array[`T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[T::Hash[Symbol, `T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, T::Hash[Symbol, `T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, T::Hash[Symbol, T::Hash[Symbol, Integer]]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, T::Hash[T.any(String, Symbol), `T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- Easily addressable/addressed returns: 5245 (100.0%)

#### Top Return Hygiene Actions

- src/mir/lowering/expressions.rb:1019 `MIRLoweringExpressions#or_pass_fallback`: auto-fixable: MIR::DefaultValue; used as value; literal/static
- src/annotator/annotator.rb:689 `SemanticAnnotator#visit`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return
- src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return
- src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:522 `ClearParser#run_action`: cascade: forwarded return; used as value; explicit/direct forwarded return
- src/ast/parser.rb:719 `ClearParser#parse_statement`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:999 `ClearParser#parse_visibility_decl`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/parser.rb:1833 `ClearParser#parse_or_rescue`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/parser.rb:1957 `ClearParser#parse_var_id`: cascade: forwarded return; used as value; explicit/direct forwarded return
- src/ast/parser.rb:2473 `ClearParser#parse_primary`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:2518 `ClearParser#parse_lit`: cascade: forwarded return; used as value; explicit/direct forwarded return
- src/ast/parser.rb:2587 `ClearParser#parse_sigil_construct`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:2934 `ClearParser#parse_concurrent_inner_op`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/parser.rb:3861 `ClearParser#parse_bg_body_stmt`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:3967 `ClearParser#deep_clone_node`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/scope.rb:195 `Scope#resolve_type_definition`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/scope.rb:502 `ScopeHelper#with_new_scope`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/mir/fsm_ops.rb:487 `FsmOps#walk`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return


## Review Actions (1653)

### Nil Source Fixes (161)
- src/mir/lowering/control_flow.rb:209: affects 2 of 161 nil source fixes; source calls 1326
  - src/mir/lowering/control_flow.rb:209 tight; candidate T::Boolean; top source src/mir/lowering/control_flow.rb:209; source calls 719
  - src/mir/lowering/control_flow.rb:209 mark_per_iter; candidate T::Boolean; top source src/mir/lowering/control_flow.rb:209; source calls 607
- src/lsp/hover.rb:92: affects 2 of 161 nil source fixes; source calls 11
  - src/lsp/hover.rb:92 entry; candidate Hash; auto-default {}; top source src/lsp/hover.rb:92; source calls 6
  - src/lsp/hover.rb:92 example; candidate Hash; auto-default {}; top source src/lsp/hover.rb:92; source calls 5
- src/mir/fsm_transform/segments.rb:125: affects 2 of 161 nil source fixes; source calls 4
  - src/mir/fsm_transform/segments.rb:125 with_node; candidate T.any(AST::WithBlock, `T.untyped`); top source src/mir/fsm_transform/segments.rb:125; source calls 3
  - src/mir/fsm_transform/segments.rb:125 cap; candidate T.any(CapabilityPlan::CapabilityTransition, Hash, Symbol); top source src/mir/fsm_transform/segments.rb:125; source calls 1
- src/ast/symbol_entry.rb:471: affects 1 of 161 nil source fix; source calls 1022422
  - src/ast/symbol_entry.rb:471 reg; top source src/ast/symbol_entry.rb:471; source calls 1022422
- src/annotator/helpers/intrinsic_arg_spec.rb:37: affects 1 of 161 nil source fix; source calls 104314
  - src/annotator/helpers/intrinsic_arg_spec.rb:37 raw; candidate T.any(Array, Symbol); top source src/annotator/helpers/intrinsic_arg_spec.rb:37; source calls 104314
- src/annotator/helpers/function_signature.rb:377: affects 1 of 161 nil source fix; source calls 77589
  - src/annotator/helpers/function_signature.rb:377 arg_spec; candidate T.any(Array, Symbol); top source src/annotator/helpers/function_signature.rb:377; source calls 77589
- src/annotator/helpers/auto_inference.rb:215: affects 1 of 161 nil source fix; source calls 75957
  - src/annotator/helpers/auto_inference.rb:215 node; top source src/annotator/helpers/auto_inference.rb:215; source calls 75957
- src/annotator/helpers/intrinsic_registry.rb:162: affects 1 of 161 nil source fix; source calls 74052
  - src/annotator/helpers/intrinsic_registry.rb:162 value; candidate T.any(Array, String, Symbol); top source src/annotator/helpers/intrinsic_registry.rb:162; source calls 74052
- src/tools/lint_fix_rewriter.rb:212: affects 1 of 161 nil source fix; source calls 42948
  - src/tools/lint_fix_rewriter.rb:212 n; top source src/tools/lint_fix_rewriter.rb:212; source calls 42948
- src/mir/hoist.rb:599: affects 1 of 161 nil source fix; source calls 33444
  - src/mir/hoist.rb:599 value; top source src/mir/hoist.rb:599; source calls 33444
- src/mir/hoist.rb:611: affects 1 of 161 nil source fix; source calls 33444
  - src/mir/hoist.rb:611 value; top source src/mir/hoist.rb:611; source calls 33444
- src/mir/pre_mir_type_check.rb:70: affects 1 of 161 nil source fix; source calls 31604
  - src/mir/pre_mir_type_check.rb:70 node; top source src/mir/pre_mir_type_check.rb:70; source calls 31604
- src/tools/predicate_rewriter.rb:129: affects 1 of 161 nil source fix; source calls 31116
  - src/tools/predicate_rewriter.rb:129 n; top source src/tools/predicate_rewriter.rb:129; source calls 31116
- src/tools/method_rewriter.rb:141: affects 1 of 161 nil source fix; source calls 31060
  - src/tools/method_rewriter.rb:141 node; top source src/tools/method_rewriter.rb:141; source calls 31060
- src/tools/predicate_rewriter.rb:114: affects 1 of 161 nil source fix; source calls 30870
  - src/tools/predicate_rewriter.rb:114 node; top source src/tools/predicate_rewriter.rb:114; source calls 30870
- src/annotator/helpers/intrinsic_registry.rb:170: affects 1 of 161 nil source fix; source calls 26725
  - src/annotator/helpers/intrinsic_registry.rb:170 spec; candidate T.any(Array, Symbol); top source src/annotator/helpers/intrinsic_registry.rb:170; source calls 26725
- src/mir/hoist.rb:230: affects 1 of 161 nil source fix; source calls 23064
  - src/mir/hoist.rb:230 node; top source src/mir/hoist.rb:230; source calls 23064
- src/mir/hoist.rb:245: affects 1 of 161 nil source fix; source calls 23064
  - src/mir/hoist.rb:245 child; top source src/mir/hoist.rb:245; source calls 23064
- src/annotator/helpers/intrinsic_registry.rb:117: affects 1 of 161 nil source fix; source calls 21857
  - src/annotator/helpers/intrinsic_registry.rb:117 v; top source src/annotator/helpers/intrinsic_registry.rb:117; source calls 21857
- src/tools/lint_fix_rewriter.rb:198: affects 1 of 161 nil source fix; source calls 21473
  - src/tools/lint_fix_rewriter.rb:198 node; top source src/tools/lint_fix_rewriter.rb:198; source calls 21473
- ... 138 more source group(s)

### Union / `T.any` Candidates (440)
- src/mir/hoist.rb:1047: affects 3 of 440 union candidates; source calls 0
  - src/mir/hoist.rb:1047 new_child; observed MIR::AddressOf, MIR::AllocatorRef, MIR::ArrayInit, MIR::BinOp, MIR::BlockExpr, MIR::Call, MIR::CapabilityLockAddress, MIR::CapabilityLockTarget, ...; no source callsite
  - src/mir/hoist.rb:1047 old_child; observed MIR::AddressOf, MIR::AllocatorRef, MIR::ArrayInit, MIR::BinOp, MIR::BlockExpr, MIR::Call, MIR::CapabilityLockAddress, MIR::CapabilityLockTarget, ...; no source callsite
  - src/mir/hoist.rb:1047 parent; observed MIR::AddressOf, MIR::ArrayInit, MIR::AssertStmt, MIR::BgBlock, MIR::BinOp, MIR::Call, MIR::CapWrap, MIR::CapabilityLockAddress, ...; no source callsite
- src/mir/lowering/variables.rb:1017: affects 3 of 440 union candidates; source calls 0
  - src/mir/lowering/variables.rb:1017 idx; observed MIR::Call, MIR::ConcatStr, MIR::DeepCopy, MIR::Ident, MIR::Lit, MIR::RegistryCall; no source callsite
  - src/mir/lowering/variables.rb:1017 target; observed MIR::FieldGet, MIR::Ident; no source callsite
  - src/mir/lowering/variables.rb:1017 target_node; observed AST::GetField, AST::Identifier; no source callsite
- src/mir/lowering/variables.rb:1078: affects 3 of 440 union candidates; source calls 0
  - src/mir/lowering/variables.rb:1078 idx; observed MIR::FieldGet, MIR::Ident, MIR::Lit; no source callsite
  - src/mir/lowering/variables.rb:1078 target; observed MIR::Ident, MIR::IndexGet; no source callsite
  - src/mir/lowering/variables.rb:1078 target_node; observed AST::GetIndex, AST::Identifier; no source callsite
- src/mir/mir_lowering.rb:3462: affects 3 of 440 union candidates; source calls 0
  - src/mir/mir_lowering.rb:3462 catch_body; observed MIR::BlockExpr, MIR::BreakExpr, MIR::DefaultValue, MIR::Ident, MIR::Lit, MIR::ScopeBlock, MIR::UnaryOp; no source callsite
  - src/mir/mir_lowering.rb:3462 fallback; observed AST::Literal, MIR::BlockExpr, MIR::Lit, MIR::UnaryOp; no source callsite
  - src/mir/mir_lowering.rb:3462 left; observed MIR::Call, MIR::Ident, MIR::RegistryCall; no source callsite
- src/tools/lint_fix_rewriter.rb:67: affects 2 of 440 union candidates; source calls 690267
  - src/tools/lint_fix_rewriter.rb:67 in_bg; observed FalseClass, TrueClass; src/tools/lint_fix_rewriter.rb:67; source calls 532435
  - src/tools/lint_fix_rewriter.rb:67 node; observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BatchWindowOp, AST::BenchmarkStmt, AST::BgBlock, ...; src/tools/lint_fix_rewriter.rb:67; source calls 157832
- src/annotator/helpers/intrinsic_registry.rb:221: affects 2 of 440 union candidates; source calls 19995
  - src/annotator/helpers/intrinsic_registry.rb:221 name; observed String, Symbol; src/annotator/helpers/intrinsic_registry.rb:221; source calls 10012
  - src/annotator/helpers/intrinsic_registry.rb:221 x; observed FunctionSignature, Hash, Symbol; src/annotator/helpers/intrinsic_registry.rb:221; source calls 9983
- src/annotator/helpers/function_analysis.rb:89: affects 2 of 440 union candidates; source calls 18710
  - src/annotator/helpers/function_analysis.rb:89 body; observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; src/annotator/helpers/function_analysis.rb:89; source calls 9355
  - src/annotator/helpers/function_analysis.rb:89 declared_return; observed Symbol, Type; src/annotator/helpers/function_analysis.rb:89; source calls 9355
- src/ast/type.rb:3665: affects 2 of 440 union candidates; source calls 16457
  - src/ast/type.rb:3665 source_type; observed Symbol, Type; src/ast/type.rb:3665; source calls 8487
  - src/ast/type.rb:3665 target_type; observed Symbol, Type; src/ast/type.rb:3665; source calls 7970
- src/mir/lowering/control_flow.rb:209: affects 2 of 440 union candidates; source calls 1204
  - src/mir/lowering/control_flow.rb:209 tight; observed FalseClass, TrueClass; src/mir/lowering/control_flow.rb:209; source calls 689
  - src/mir/lowering/control_flow.rb:209 mark_per_iter; observed FalseClass, TrueClass; src/mir/lowering/control_flow.rb:209; source calls 515
- src/ast/source_error.rb:31: affects 2 of 440 union candidates; source calls 1101
  - src/ast/source_error.rb:31 code_or_message; observed String, Symbol; src/ast/source_error.rb:31; source calls 1099
  - src/ast/source_error.rb:31 node_or_token; observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, ...; src/ast/source_error.rb:31; source calls 2
- src/ast/source_error.rb:141: affects 2 of 440 union candidates; source calls 936
  - src/ast/source_error.rb:141 raise_in_collector; observed FalseClass, TrueClass; src/ast/source_error.rb:141; source calls 935
  - src/ast/source_error.rb:141 node_or_token; observed AST::Assignment, AST::BgBlock, AST::BindExpr, AST::FunctionDef, AST::GetField, AST::GetIndex, AST::Identifier, AST::Literal, ...; src/ast/source_error.rb:141; source calls 1
- src/mir/fsm_transform.rb:65: affects 2 of 440 union candidates; source calls 576
  - src/mir/fsm_transform.rb:65 lowering; observed MIRLowering, `T.untyped`; src/mir/fsm_transform.rb:65; source calls 575
  - src/mir/fsm_transform.rb:65 bg_block; observed AST::BgBlock, `T.untyped`; src/mir/fsm_transform.rb:65; source calls 1
- src/annotator/helpers/fixable_helpers.rb:68: affects 2 of 440 union candidates; source calls 236
  - src/annotator/helpers/fixable_helpers.rb:68 candidates; observed Array, Set; src/annotator/helpers/fixable_helpers.rb:68; source calls 119
  - src/annotator/helpers/fixable_helpers.rb:68 input; observed String, Symbol; src/annotator/helpers/fixable_helpers.rb:68; source calls 117
- src/mir/fsm_transform/segments.rb:125: affects 2 of 440 union candidates; source calls 6
  - src/mir/fsm_transform/segments.rb:125 cap; observed CapabilityPlan::CapabilityTransition, Hash, Symbol; src/mir/fsm_transform/segments.rb:125; source calls 3
  - src/mir/fsm_transform/segments.rb:125 with_node; observed AST::WithBlock, `T.untyped`; src/mir/fsm_transform/segments.rb:125; source calls 3
- src/mir/hoist.rb:1093: affects 2 of 440 union candidates; source calls 0
  - src/mir/hoist.rb:1093 old_child; observed MIR::Call, MIR::ConcatStr, MIR::DeepCopy, MIR::Ident, MIR::MakeList, MIR::RegistryCall, MIR::TryExpr; no source callsite
  - src/mir/hoist.rb:1093 parent; observed MIR::ArrayInit, MIR::CapWrap, MIR::Cast, MIR::DupeSlice, MIR::HeapCreate, MIR::IfOptional, MIR::MethodCall, MIR::ShardedMapGet, ...; no source callsite
- src/mir/hoist.rb:1174: affects 2 of 440 union candidates; source calls 0
  - src/mir/hoist.rb:1174 ast_node; observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, ...; no source callsite
  - src/mir/hoist.rb:1174 mir; observed MIR::AllocSlice, MIR::BgBlock, MIR::BlockExpr, MIR::Call, MIR::CapWrap, MIR::Cast, MIR::ConcatStr, MIR::ContainerInit, ...; no source callsite
- src/mir/lowering/concurrency.rb:474: affects 2 of 440 union candidates; source calls 0
  - src/mir/lowering/concurrency.rb:474 expr; observed AST::BgBlock, AST::FuncCall, AST::Identifier, AST::Literal, AST::WithBlock; no source callsite
  - src/mir/lowering/concurrency.rb:474 mir; observed MIR::BgBlock, MIR::Call, MIR::Ident, MIR::Lit, MIR::ScopeBlock; no source callsite
- src/mir/lowering/expressions.rb:1916: affects 2 of 440 union candidates; source calls 0
  - src/mir/lowering/expressions.rb:1916 left; observed AST::BinaryOp, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::Literal, AST::MethodCall; no source callsite
  - src/mir/lowering/expressions.rb:1916 right; observed AST::Identifier, AST::Literal, AST::UnaryOp; no source callsite
- src/mir/lowering/expressions.rb:981: affects 2 of 440 union candidates; source calls 0
  - src/mir/lowering/expressions.rb:981 ast_node; observed AST::BinaryOp, AST::CopyNode, AST::GetField, AST::Literal, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; no source callsite
  - src/mir/lowering/expressions.rb:981 value; observed MIR::BinOp, MIR::DeepCopy, MIR::Ident, MIR::Lit, MIR::RegistryCall, MIR::StructInit, MIR::UnaryOp; no source callsite
- src/mir/lowering/functions.rb:993: affects 2 of 440 union candidates; source calls 0
  - src/mir/lowering/functions.rb:993 a; observed AST::BinaryOp, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LambdaLit, AST::Literal, ...; no source callsite
  - src/mir/lowering/functions.rb:993 arg; observed MIR::BinOp, MIR::Call, MIR::Cast, MIR::DeepCopy, MIR::Deref, MIR::FieldGet, MIR::FnRef, MIR::Ident, ...; no source callsite
- ... 393 more source group(s)

### Missing Sigs Needing Manual Review (79)
- src/mir/lowering/functions.rb:454 add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- src/mir/lowering/functions.rb:617 add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- src/mir/pre_mir_type_check.rb:70 add_sig: add missing sig
- src/tools/atomic_escape_suggester.rb:24 add_sig: add missing sig
- src/tools/atomic_escape_suggester.rb:52 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:56 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:63 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:106 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:125 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:131 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:179 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:44 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:50 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:85 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:116 add_sig: add missing sig
- src/tools/completions.rb:30 add_sig: add missing sig
- src/tools/completions.rb:43 add_sig: add missing sig
- src/tools/completions.rb:91 add_sig: add missing sig
- src/tools/completions.rb:126 add_sig: add missing sig
- src/tools/doctor.rb:72 add_sig: add missing sig
- ... 59 more

### Other Review Actions (973)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::Param#name` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::Param#takes` as T.any(FalseClass, Lexer::Token, TrueClass) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `BinaryOpResult#type` as Type (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::StructLit#fields` as T.any(Array, Hash, T::Hash[`T.untyped`, `T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::Call#callee` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::Call#owned_return` as T.any(FalseClass, T::Boolean, TrueClass) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::StructField#borrowed` as T::Boolean (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::MethodCall#args` as T.any(Array, T::Array[MIR::Node], T::Array[`T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::Capability#capability` as Symbol (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::Capability#alias_mutable` as T::Boolean (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::FieldDef#zig_type` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::IfStmt#then_body` as T.any(Array, T::Array[MIR::IfStmt], T::Array[`T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::MatchCase#kind` as Symbol (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::AssertStmt#message` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `FsmOps::IoSubmit#waiter` as FsmOps::StateField (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `CompilerFrontend::Result#ast` as AST::Program (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `CompilerFrontend::Result#fn_nodes` as T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `CompilerFrontend::Result#fn_sigs` as T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `CompilerFrontend::Result#moved_guard_info` as T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `Formatter::Emitter::FnSig#arrow_idx` as Integer (struct field RBI)
- ... 953 more
## High-Confidence Actions (15)
- src/ast/ast.rb:1710 add_sig: add missing sig
  - method: `AST#name`
  - proposed: sig { returns(String) }
- src/ast/ast.rb:1871 add_sig: add missing sig
  - method: `AST#name`
  - proposed: sig { returns(String) }
- src/ast/ast.rb:1886 add_sig: add missing sig
  - method: `AST#name`
  - proposed: sig { returns(String) }
- src/compiler/module_importer.rb:36 narrow_generic_param: narrow generic param pkg_paths from T::Hash[`T.untyped`, `T.untyped`] to T::Hash[String, String]
  - method: `ModuleImporter#initialize`
  - current: sig { params(base_dir: String, pkg_paths: T::Hash[`T.untyped`, `T.untyped`], use_mir: T::Boolean, stdlib_root: String).void }
  - evidence: observed T::Hash[String, String]
- src/mir/lowering/expressions.rb:1019 fix_sig_return: existing sig return is `T.untyped`; static return origins suggest MIR::DefaultValue
  - method: `MIRLoweringExpressions#or_pass_fallback`
  - current: sig { params(node: `T.untyped`).returns(`T.untyped`) }
  - proposed: change return to MIR::DefaultValue
  - evidence: static candidate MIR::DefaultValue
- src/tools/pprof.rb:228 add_sig: add missing sig
  - method: `Pprof::Profile#write_gzip`
  - proposed: sig { params(path: String).returns(Integer) }
- src/tools/pprof.rb:221 add_sig: add missing sig
  - method: `Pprof::Profile#encode_gzip`
  - proposed: sig { returns(String) }
- src/tools/pprof.rb:180 add_sig: add missing sig
  - method: `Pprof::Profile#encode`
  - proposed: sig { returns(String) }
- src/tools/pprof.rb:99 add_sig: add missing sig
  - method: `Pprof::Profile#set_period_type`
  - proposed: sig { params(type: String, unit: String, period: Integer).returns(Integer) }
- src/tools/pprof.rb:106 add_sig: add missing sig
  - method: `Pprof::Profile#default_sample_type=`
  - proposed: sig { params(type: String).returns(Integer) }
- src/tools/pprof_converter.rb:354 add_sig: add missing sig
  - method: `PprofConverter#resolve_addrs`
  - proposed: sig { params(addrs: Array, binary: T.nilable(String), profile_dir: String).returns(Hash) }
- src/tools/pprof_converter.rb:163 add_sig: add missing sig
  - method: `PprofConverter#build_location_index`
  - proposed: sig { params(pb: Pprof::Profile, addrs: Array, resolved: Hash, profile_dir: String).returns(Hash) }
- src/tools/pprof_converter.rb:335 add_sig: add missing sig
  - method: `PprofConverter#parse_tabbed_columns`
  - proposed: sig { params(path: String, min_cols: Integer).returns(Array) }
- src/tools/fmt_verifier.rb:72 add_sig: add missing sig
  - method: `FmtVerifier#normalize_for_compare`
  - proposed: sig { params(zig_source: String).returns(String) }
- src/mir/rewriters/pipeline_rewriter.rb:23 narrow_tlet: narrow existing `T.let` to T.nilable(SemanticAnnotator)
  - proposed: change `T.let` type to T.nilable(SemanticAnnotator)
  - evidence: observed T.nilable(SemanticAnnotator)

## Gap Actions (0)
- none

## Untyped Slots
- bucket: runtime-observation state for the current `T.untyped` slot, such as unobserved, nil-only, single-type, or runtime union
- source category: static origin category explaining where the untyped value appears to come from
- unknown expression cause: parser/indexer reason the report could not classify the expression more precisely

### Param `T.untyped` Buckets
- runtime union; kept `T.untyped` by policy: 408
  - 3 slots: src/mir/hoist.rb:1047 `MIRHoistLowering#replace_mir_expr_child!` parent; 139766 call(s); observed MIR::AddressOf, MIR::ArrayInit, MIR::AssertStmt, MIR::BgBlock, MIR::BinOp, MIR::Call, MIR::CapWrap, MIR::CapabilityLockAddress, ...; me ...
  - 3 slots: src/mir/lowering/variables.rb:1017 `MIRLoweringVariables#lower_map_indexed_assignment` target_node; 618 call(s); observed AST::GetField, AST::Identifier; direct protocol: none observed; analysis gaps: forwarded to extract_root_var_na ...
  - 3 slots: src/mir/lowering/variables.rb:1078 `MIRLoweringVariables#lower_template_indexed_assignment` target_node; 117 call(s); observed AST::GetIndex, AST::Identifier; direct protocol: none observed; analysis gaps: forwarded to extract_root_v ...
  - 3 slots: src/mir/mir_lowering.rb:3462 `MIRLowering#try_catch_with_provenance` left; 292 call(s); observed MIR::Call, MIR::Ident, MIR::RegistryCall; direct protocol: none observed; analysis gaps: forwarded to strip_try slot 0 at src/mir/mir_lo ...
  - 2 slots: src/annotator/helpers/fixable_helpers.rb:1174 `FixableHelper#emit_type_mismatch_assign_error!` node; 10 call(s); observed AST::Assignment, AST::BindExpr; medium direct protocol #value; other potential options, not exhaustive: AST, AS ...
  - 2 slots: src/annotator/helpers/fixable_helpers.rb:1228 `FixableHelper#build_cast_wrap_fix` value; 13 call(s); observed AST::FuncCall, AST::Identifier, AST::Literal, AST::PassStmt, AST::StructLit, NilClass; strong direct protocol #name, #token ...
  - 2 slots: src/annotator/helpers/fixable_helpers.rb:68 `FixableHelper#closest_name` input; 123 call(s); observed String, Symbol; weak direct protocol #to_s
  - 2 slots: src/annotator/helpers/function_analysis.rb:89 `FunctionAnalysis#analyze_routine` body; 9422 call(s); observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; medium direct protocol #resolved_type; other potential options, not ex ...
- single observed type; narrow candidate: 181
  - 4 slots: src/lsp/code_actions.rb:59 `LSP::CodeActions#build_action` fix; 14 call(s); observed Fix
  - 3 slots: src/ast/diagnostic_examples.rb:143 `DiagnosticExamples#find_block_end` lines; 3936 call(s); observed Array
  - 3 slots: src/lsp/hover.rb:64 `LSP::Hover#find_overlapping` result; 16 call(s); observed LSP::AnalysisResult
  - 3 slots: src/lsp/hover.rb:92 `LSP::Hover#build_markdown` diag; 13 call(s); observed Hash
  - 2 slots: src/annotator/helpers/fixable_helpers.rb:987 `FixableHelper#emit_with_read_needs_write_lock!` name; 2 call(s); observed String
  - 2 slots: src/annotator/helpers/generic_analysis.rb:433 `GenericAnalysis#same_generic_binding?` left; 21 call(s); observed Type
  - 2 slots: src/annotator/helpers/intrinsic_registry.rb:141 `IntrinsicRegistry#convert_entry` h; 75552 call(s); observed Hash
  - 2 slots: src/annotator/helpers/intrinsic_registry.rb:264 `IntrinsicRegistry#overloads` reg; 12185 call(s); observed Hash
- slot not observed: source index did not model this param shape: 55
  - 1 slot: src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls` block; 1629 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls` block; 1468 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/capabilities.rb:1102 `CapabilityHelper#with_fiber_capture_analysis` blk; 2501 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves` blk; 1021 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/capabilities.rb:41 `Capabilities#validate!` error_handler; 17681 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!` kwargs; 14 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/pipe_analysis.rb:146 `PipeAnalysis#lift_to_observable_if_terminal!` type_kwargs; 1084 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/pipe_analysis.rb:165 `PipeAnalysis#mark_observable_terminal!` type_kwargs; 1084 call(s); observed no observed runtime type
- nil only observed: 5
  - 1 slot: src/ast/ast.rb:1782 `AST#params=` val; 1 call(s); observed NilClass
  - 1 slot: src/ast/ast.rb:2354 `AST#params=` val; 1 call(s); observed NilClass
  - 1 slot: src/backends/transpiler.rb:154 `ZigTranspiler#main_stack_variant` override; 846 call(s); observed NilClass
  - 1 slot: src/mir/fsm_transform/segments.rb:174 `FsmTransform::Segments#split` lowering; 3 call(s); observed NilClass
  - 1 slot: src/mir/mir_checker.rb:351 `MIRChecker#initialize` fn_name; 1904 call(s); observed NilClass
- boolean pair; T::Boolean candidate: 5
  - 2 slots: src/mir/lowering/control_flow.rb:209 `MIRLoweringControlFlow#prepend_loop_mark` mark_per_iter; 1477 call(s); observed FalseClass, NilClass, TrueClass
  - 1 slot: src/ast/diagnostic_examples.rb:167 `DiagnosticExamples#extract_first_heredoc_in_it` expecting_raise; 1968 call(s); observed FalseClass, TrueClass
  - 1 slot: src/ast/source_error.rb:141 `ErrorHelper#fixable!` raise_in_collector; 1074 call(s); observed FalseClass, TrueClass
  - 1 slot: src/mir/lowering/control_flow.rb:246 `MIRLoweringControlFlow#finalize_loop_frame_alloc_scopes!` mark_per_iter; 1477 call(s); observed FalseClass, NilClass, TrueClass
- slot not observed: method was not hit: 1
  - 1 slot: src/mir/mir_lowering.rb:3250 `MIRLowering#importable_module_item?` item; 0 call(s); observed no observed runtime type

### Return `T.untyped` Buckets
- runtime union; kept `T.untyped` by policy: 115
  - 1 slot: src/annotator/annotator.rb:689 `SemanticAnnotator#visit` return; 210714 call(s); observed Array, FunctionSignature, Integer, Module, NilClass, Symbol, SymbolEntry, TrueClass, ...
  - 1 slot: src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls` return; 1629 call(s); observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST::Li ...
  - 1 slot: src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk` return; 817 call(s); observed AST::BindExpr, AST::HashLit, AST::Identifier, AST::ListLit, AST::Literal, AST::ReturnNode, AST::VarDecl, Array, ...
  - 1 slot: src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls` return; 1468 call(s); observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST: ...
  - 1 slot: src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops` return; 1359 call(s); observed AST::Assert, AST::Assignment, AST::BindExpr, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST::ListLit, ...
  - 1 slot: src/annotator/helpers/generic_analysis.rb:337 `GenericAnalysis#extract_type_bindings!` return; 104 call(s); observed Array, NilClass, Type
  - 1 slot: src/ast/ast.rb:1022 `AST::Locatable#coerced_type` return; 147639 call(s); observed FunctionSignature, NilClass, Symbol
  - 1 slot: src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture` return; 150934 call(s); observed Array, CapabilityHelper::CaptureAnalysis, NilClass
- single observed type; narrow candidate: 30
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:987 `FixableHelper#emit_with_read_needs_write_lock!` return; 2 call(s); observed NilClass, Symbol
  - 1 slot: src/annotator/helpers/intrinsic_registry.rb:117 `IntrinsicRegistry#to_return_def` return; 78244 call(s); observed FunctionReturn
  - 1 slot: src/annotator/helpers/intrinsic_registry.rb:162 `IntrinsicRegistry#normalize_lifetime` return; 77057 call(s); observed Array
  - 1 slot: src/annotator/helpers/intrinsic_registry.rb:170 `IntrinsicRegistry#params_from_arg_spec` return; 75552 call(s); observed Array
  - 1 slot: src/annotator/helpers/intrinsic_registry.rb:209 `IntrinsicRegistry#registries` return; 75284 call(s); observed Hash
  - 1 slot: src/annotator/helpers/intrinsic_registry.rb:221 `IntrinsicRegistry#fs` return; 11060 call(s); observed FunctionSignature, NilClass
  - 1 slot: src/annotator/helpers/intrinsic_registry.rb:72 `IntrinsicRegistry#nested_emit` return; 37 call(s); observed IntrinsicEmit, NilClass
  - 1 slot: src/annotator/helpers/pipe_analysis.rb:214 `PipeAnalysis#analyze_higher_order_op` return; 2357 call(s); observed Type
- nil only observed: 12
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:1097 `FixableHelper#emit_with_restrict_immutable_error!` return; 10 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:1571 `FixableHelper#emit_auto_resolved_finding!` return; 22 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:1597 `FixableHelper#emit_auto_shape_resolved_finding!` return; 9 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:1641 `FixableHelper#emit_auto_ambiguity_finding!` return; 4 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:1674 `FixableHelper#emit_auto_unresolved_finding!` return; 9 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!` return; 14 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:812 `FixableHelper#emit_return_borrowed_no_copy_error!` return; 8 call(s); observed NilClass
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:933 `FixableHelper#emit_with_guard_mutable_mutated!` return; 9 call(s); observed NilClass
- void candidate; return value appears unused: 6
  - 1 slot: src/annotator/annotator.rb:714 `SemanticAnnotator#visit_Program` return; 6342 call(s); observed Module, Symbol, Type
  - 1 slot: src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves` return; 1021 call(s); observed NilClass, SymbolEntry, Type, TypePlacement
  - 1 slot: src/ast/ast.rb:777 `AST#each_bg_block_in_stmt` return; 19838 call(s); observed Array, NilClass, Set, TrueClass
  - 1 slot: src/ast/scope.rb:383 `Scope#mark_read` return; 40381 call(s); observed Module, NilClass, TrueClass
  - 1 slot: src/mir/cleanup_classifier.rb:766 `CleanupClassifier#each_capture_binding` return; 4629 call(s); observed Array, Module
  - 1 slot: src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads` return; 16828 call(s); observed Array, Hash, Module, NilClass
- slot not observed: method hit but return was not captured: 6
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:1054 `FixableHelper#emit_with_materialized_needs_tense!` return; 3 call(s); observed no observed runtime type
  - 1 slot: src/annotator/helpers/fixable_helpers.rb:898 `FixableHelper#emit_with_guard_all_bindings_need_as!` return; 2 call(s); observed no observed runtime type
  - 1 slot: src/ast/parser.rb:614 `ClearParser#emit_consume_error_with_fix` return; 103 call(s); observed no observed runtime type
  - 1 slot: src/ast/parser.rb:633 `ClearParser#emit_syntax_insert_end_of_line!` return; 8 call(s); observed no observed runtime type
  - 1 slot: src/ast/parser.rb:661 `ClearParser#emit_syntax_insert_before_token!` return; 7 call(s); observed no observed runtime type
  - 1 slot: src/ast/source_error.rb:31 `ErrorHelper#error!` return; 1101 call(s); observed no observed runtime type

### Param `T.untyped` Source Categories
- untyped unknown expression: 422
  - src/annotator/helpers/auto_inference.rb:68 `AutoSlotId#eql?` other; no static callsite origin
  - src/annotator/helpers/auto_inference.rb:242 `AutoConstraintCollector#record_constraint` node; src/annotator/helpers/auto_inference.rb:225 node
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls` block; no static callsite origin
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls` block; no static callsite origin
  - src/annotator/helpers/capabilities.rb:41 `Capabilities#validate!` node; src/annotator/domains/variables.rb:131 node
  - src/annotator/helpers/capabilities.rb:41 `Capabilities#validate!` error_handler; no static callsite origin
  - src/annotator/helpers/capabilities.rb:1102 `CapabilityHelper#with_fiber_capture_analysis` blk; no static callsite origin
  - src/annotator/helpers/capabilities.rb:1133 `CapabilityHelper#record_capture_site!` node; src/annotator/domains/lifetimes.rb:14 node; src/annotator/domains/lifetimes.rb:117 node; src/annotator/domains/lifetimes.rb:172 node
- untyped forwarded return: 195
  - src/annotator/helpers/auto_inference.rb:215 `AutoConstraintCollector#walk` node; src/annotator/helpers/auto_inference.rb:173 program_node; src/annotator/helpers/auto_inference.rb:221 c; src/annotator/helpers/auto_inference.rb:223 v
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls` node; src/annotator/helpers/auto_inference.rb:730 fn.body; src/annotator/helpers/auto_inference.rb:746 node.value; src/annotator/helpers/auto_inference. ...
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk` node; src/annotator/helpers/auto_inference.rb:173 program_node; src/annotator/helpers/auto_inference.rb:221 c; src/annotator/helpers/auto_inference.rb:223 v
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls` node; src/annotator/helpers/auto_inference.rb:887 fn.body; src/annotator/helpers/auto_inference.rb:901 node.value; src/annotator/helpers/auto_inferen ...
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops` node; src/annotator/helpers/auto_inference.rb:874 fn.body; src/annotator/helpers/auto_inference.rb:924 node.left; src/annotator/helpers/auto_inference.rb:925  ...
  - src/annotator/helpers/capabilities.rb:1037 `CapabilityHelper#capability_alias_type` type; src/annotator/helpers/capabilities.rb:945 source_type; src/annotator/helpers/capabilities.rb:960 capability_source_type(fact); src/annotator/helpers/cap ...
  - src/annotator/helpers/fixable_helpers.rb:110 `FixableHelper#emit_registry_mismatch!` name; src/annotator/domains/errors.rb:223 item.name; src/annotator/domains/errors.rb:233 item.name; src/annotator/domains/execution_boundaries.rb:591 name
  - src/annotator/helpers/fixable_helpers.rb:149 `FixableHelper#emit_typo_suggestion!` token; src/annotator/domains/control_flow.rb:232 name_tok; src/annotator/domains/control_flow.rb:623 name_tok; src/annotator/domains/member_access.rb:105 node. ...
- untyped struct/array/collection value: 18
  - src/annotator/helpers/fixable_helpers.rb:68 `FixableHelper#closest_name` candidates; src/annotator/helpers/fixable_helpers.rb:112 candidates; src/annotator/helpers/fixable_helpers.rb:152 candidates; src/annotator/helpers/fixable_helpers.rb:22 ...
  - src/annotator/helpers/intrinsic_registry.rb:277 `IntrinsicRegistry#lookup` reg; src/annotator/helpers/intrinsic_registry.rb:234 registry; src/annotator/helpers/intrinsic_registry.rb:245 MAP_METHODS; src/annotator/helpers/intrinsic_registry.rb ...
  - src/annotator/helpers/pipe_analysis.rb:1277 `PipeAnalysis#each_shard_scan_node` node; src/annotator/helpers/pipe_analysis.rb:1176 node; src/annotator/helpers/pipe_analysis.rb:1270 nodes; src/annotator/helpers/pipe_analysis.rb:1280 child
  - src/annotator/helpers/pipe_analysis.rb:1823 `PipeAnalysis#check_soa_opportunity!` item_type; src/annotator/helpers/pipe_analysis.rb:1850 item_type
  - src/annotator/helpers/pipe_analysis.rb:1845 `PipeAnalysis#with_soa_tracking` item_type; src/annotator/helpers/pipe_analysis.rb:325 item_type; src/annotator/helpers/pipe_analysis.rb:856 item_type; src/annotator/helpers/pipe_analysis.rb:1030 it ...
  - src/ast/diagnostic_examples.rb:71 `DiagnosticExamples#lookup` code; src/annotator/helpers/intrinsic_registry.rb:234 registry; src/annotator/helpers/intrinsic_registry.rb:245 MAP_METHODS; src/annotator/helpers/intrinsic_registry.rb:255 registr ...
  - src/ast/diagnostic_examples.rb:88 `DiagnosticExamples#scan_file` out; src/ast/diagnostic_examples.rb:80 out
  - src/ast/diagnostic_examples.rb:143 `DiagnosticExamples#find_block_end` lines; src/ast/diagnostic_examples.rb:103 lines; src/ast/diagnostic_examples.rb:171 block_lines
- untyped literal/static expression: 16
  - src/annotator/helpers/function_analysis.rb:89 `FunctionAnalysis#analyze_routine` declared_return; src/annotator/helpers/function_analysis.rb:193 :Any; src/annotator/helpers/function_analysis.rb:246 declared_return
  - src/ast/diagnostic_examples.rb:167 `DiagnosticExamples#extract_first_heredoc_in_it` expecting_raise; src/ast/diagnostic_examples.rb:107 true; src/ast/diagnostic_examples.rb:109 false
  - src/ast/source_error.rb:31 `ErrorHelper#error!` code_or_message; src/annotator/annotator.rb:523 :WITH_SNAPSHOT_BODY_NOT_PURE; src/annotator/domains/control_flow.rb:161 :IF_AS_NEEDS_OPTIONAL; src/annotator/domains/control_flow.rb:219 :MATCH_NE ...
  - src/ast/source_error.rb:141 `ErrorHelper#fixable!` raise_in_collector; src/annotator/domains/lifetimes.rb:698 true; src/annotator/domains/lifetimes.rb:767 true; src/annotator/domains/variables.rb:232 false
  - src/backends/fsm_wrapper_emitter.rb:45 `FsmWrapperEmitter#render` body; src/backends/mir_emitter.rb:288 plan; src/lsp/server.rb:258 doc; src/mir/fsm_ops.rb:426 "__ctx_#{@ctx_id}"
  - src/lsp/code_actions.rb:104 `LSP::CodeActions#range_position` side; src/lsp/code_actions.rb:96 :end; src/lsp/code_actions.rb:96 :start; src/lsp/code_actions.rb:97 :end
  - src/lsp/document_store.rb:30 `LSP::DocumentStore#cached_findings=` value; src/lsp/document_store.rb:56 nil; src/lsp/server.rb:271 result
  - src/lsp/hover.rb:32 `LSP::Hover#render` document; src/backends/mir_emitter.rb:288 plan; src/lsp/server.rb:258 doc; src/mir/fsm_ops.rb:426 "__ctx_#{@ctx_id}"
- untyped instance variable: 4
  - src/ast/schemas.rb:244 Schemas::InlineStructVariant#== other; src/annotator/domains/control_flow.rb:65 :moved; src/annotator/domains/control_flow.rb:260 :Int64; src/annotator/domains/control_flow.rb:260 :Float64
  - src/ast/type.rb:1429 Type#== other; src/annotator/domains/control_flow.rb:65 :moved; src/annotator/domains/control_flow.rb:260 :Int64; src/annotator/domains/control_flow.rb:260 :Float64
  - src/lsp/rpc.rb:34 `LSP::RPC#read_message` io; src/lsp/server.rb:54 @stdin
  - src/lsp/rpc.rb:55 `LSP::RPC#write_message` io; src/lsp/server.rb:129 @stdout

### Return `T.untyped` Source Categories
- untyped forwarded return: 86
  - src/annotator/annotator.rb:689 `SemanticAnnotator#visit`
  - src/annotator/annotator.rb:714 `SemanticAnnotator#visit_Program`
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
  - src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves`
  - src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!`
- untyped literal/static expression: 62
  - src/annotator/helpers/intrinsic_registry.rb:72 `IntrinsicRegistry#nested_emit`
  - src/annotator/helpers/intrinsic_registry.rb:117 `IntrinsicRegistry#to_return_def`
  - src/annotator/helpers/intrinsic_registry.rb:209 `IntrinsicRegistry#registries`
  - src/annotator/helpers/intrinsic_registry.rb:221 `IntrinsicRegistry#fs`
  - src/ast/ast.rb:792 `AST#_expr_each_bg_block_shallow`
  - src/ast/ast.rb:1022 `AST::Locatable#coerced_type`
  - src/ast/diagnostic_examples.rb:143 `DiagnosticExamples#find_block_end`
  - src/ast/parser.rb:710 `ClearParser#match!`
- untyped struct/array/collection value: 12
  - src/annotator/helpers/generic_analysis.rb:337 `GenericAnalysis#extract_type_bindings!`
  - src/annotator/helpers/intrinsic_registry.rb:162 `IntrinsicRegistry#normalize_lifetime`
  - src/ast/ast.rb:1782 `AST#params=`
  - src/ast/ast.rb:2354 `AST#params=`
  - src/ast/parser.rb:3928 `ClearParser#parse_comma_seq`
  - src/lsp/code_actions.rb:104 `LSP::CodeActions#range_position`
  - src/mir/control_flow.rb:956 `OwnershipDataflow#transfer_stmt`
  - src/mir/hoist.rb:491 `MIRHoistLowering#lower_head`
- untyped unknown expression: 9
  - src/ast/diagnostic_examples.rb:65 `DiagnosticExamples#all`
  - src/ast/parser.rb:1754 `ClearParser#parse_expression`
  - src/ast/parser.rb:1942 `ClearParser#parse_suffixes`
  - src/lsp/diagnostics.rb:59 `LSP::Diagnostics#from_result`
  - src/mir/lowering/control_flow.rb:361 `MIRLoweringControlFlow#for_each_loop_stmt`
  - src/mir/lowering/expressions.rb:963 `MIRLoweringExpressions#or_fallback_expected_type`
  - src/mir/mir.rb:4781 `MIR::StdlibDefFsCoercion#stdlib_def=`
  - src/mir/rewriters/pipeline_rewriter.rb:756 `PipelineRewriter#patch_chain_source!`

### Param Unknown Expression Causes
- unknown operation unresolved constant Compiler::Entrypoint::NAME: 12
  - src/annotator/domains/errors.rb:89 ==(0) Compiler::Entrypoint::NAME
  - src/annotator/helpers/effects.rb:453 ==(0) Compiler::Entrypoint::NAME
  - src/annotator/helpers/effects.rb:524 ==(0) Compiler::Entrypoint::NAME
  - src/annotator/helpers/effects.rb:682 ==(0) Compiler::Entrypoint::NAME
  - src/annotator/phases/import_resolution.rb:36 ==(0) Compiler::Entrypoint::NAME
  - src/backends/transpiler.rb:211 ==(0) Compiler::Entrypoint::NAME
  - src/mir/lowering/capabilities.rb:295 ==(0) Compiler::Entrypoint::NAME
  - src/mir/mir_lowering.rb:2581 ==(0) Compiler::Entrypoint::NAME
- unknown operation SelfNode: 5
  - src/annotator/domains/member_access.rb:23 resolve(2) self
  - src/annotator/helpers/method_analysis.rb:93 resolve(2) self
  - src/annotator/phases/expression_domains.rb:118 resolve(2) self
  - src/annotator/phases/expression_domains.rb:159 resolve(2) self
  - src/mir/lowering/concurrency.rb:532 transform(2) self
- unknown operation unresolved constant STD_LIB: 5
  - src/annotator/phases/expression_domains.rb:134 overloads(0) STD_LIB
  - src/annotator/phases/expression_domains.rb:270 overloads(0) STD_LIB
  - src/mir/lowering/functions.rb:1186 lookup(0) STD_LIB
  - src/mir/rewriters/pipeline_rewriter.rb:223 lookup(0) STD_LIB
  - src/mir/rewriters/pipeline_rewriter.rb:702 lookup(0) STD_LIB
- unknown expression with multiple unknown types: 4
  - src/annotator/helpers/lock_helper.rb:464 error!(0) anchor || semantic_program
  - src/annotator/helpers/pipe_analysis.rb:1307 sharded_unsynced_entry?(0) node.symbol || lookup_scope_for(node.name)&.resolve_entry(node.name)
  - src/mir/lowering/variables.rb:1234 placement_for_node(0) root_receiver_node(node.name) || node.name
  - src/mir/lowering/variables.rb:1329 placement_for_node(0) root_receiver_node(node.name) || node.name
- unknown operation unresolved constant HEAP_STRING_TYPE: 2
  - src/ast/type.rb:739 ==(0) HEAP_STRING_TYPE
  - src/ast/type.rb:739 ==(0) HEAP_STRING_TYPE
- unknown operation RegularExpressionNode: 2
  - src/lsp/diagnostics.rb:161 split(0) /(%\{[^}]+\})/
  - src/tools/doctor.rb:452 split(0) /\t/
- unknown operation unresolved constant UNINIT: 2
  - src/mir/control_flow.rb:894 ==(0) UNINIT
  - src/mir/control_flow.rb:895 ==(0) UNINIT
- unknown operation unresolved constant Arc: 2
  - src/mir/fiber_ctx_builder.rb:85 ==(0) Arc
  - src/mir/fiber_ctx_builder.rb:90 ==(0) Arc
- unknown operation unresolved constant CaptureCleanupKind::CapturedValue: 2
  - src/mir/fiber_ctx_builder.rb:119 ==(0) CaptureCleanupKind::CapturedValue
  - src/mir/fiber_ctx_builder.rb:158 ==(0) CaptureCleanupKind::CapturedValue
- unknown operation unresolved constant CaptureCleanupKind::UniformValue: 2
  - src/mir/fiber_ctx_builder.rb:126 ==(0) CaptureCleanupKind::UniformValue
  - src/mir/fiber_ctx_builder.rb:159 ==(0) CaptureCleanupKind::UniformValue
- unknown local variable kind: 2
  - src/mir/lowering/expressions.rb:1278 fs(1) :"#{kind}_get"
  - src/mir/lowering/variables.rb:971 fs(1) :"#{kind}_set"
- unknown local variable node: 1
  - src/annotator/domains/errors.rb:334 error!(0) site_tok || node
- unknown operation unresolved constant SUSPENDS: 1
  - src/annotator/helpers/effects.rb:201 ==(0) SUSPENDS
- unknown operation unresolved constant SUSPENDS_LOOP: 1
  - src/annotator/helpers/effects.rb:381 ==(0) SUSPENDS_LOOP
- unknown operation unresolved constant SUSPENDS_CONDITIONAL: 1
  - src/annotator/helpers/effects.rb:382 ==(0) SUSPENDS_CONDITIONAL
- unknown local variable auto_tok: 1
  - src/annotator/helpers/fixable_helpers.rb:1696 fixable!(0) auto_tok || slot.decl_node
- unknown operation unresolved constant Kind::Fixed: 1
  - src/annotator/helpers/function_return.rb:66 ==(0) Kind::Fixed
- unknown operation unresolved constant MAP_METHODS: 1
  - src/annotator/helpers/intrinsic_registry.rb:245 lookup(0) MAP_METHODS
- unknown global variable $0: 1
  - src/backends/transpiler.rb:279 ==(0) $0
- unknown instance variable @stdin: 1
  - src/lsp/server.rb:54 read_message(0) @stdin
- unknown instance variable @stdout: 1
  - src/lsp/server.rb:129 write_message(0) @stdout
- unknown struct/array/collection value Array: 1
  - src/mir/control_flow.rb:651 each_locatable(0) fn_node.body || []
- unknown operation unresolved constant MOVED: 1
  - src/mir/control_flow.rb:915 ==(0) MOVED
- unknown operation unresolved constant CaptureCleanupKind::None: 1
  - src/mir/fiber_ctx_builder.rb:109 ==(0) CaptureCleanupKind::None
- unknown operation unresolved constant CaptureCleanupKind::RcRelease: 1
  - src/mir/fiber_ctx_builder.rb:133 ==(0) CaptureCleanupKind::RcRelease
- unknown operation unresolved constant PipelineConcurrentSourceKind::RuntimeList: 1
  - src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:317 ==(0) PipelineConcurrentSourceKind::RuntimeList
- unknown operation unresolved constant PipelineConcurrentTerminalKind::Each: 1
  - src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:318 ==(0) PipelineConcurrentTerminalKind::Each
- unknown operation unresolved constant PipelineSourceKind::RangeChain: 1
  - src/mir/lower/pipeline/pipeline_plan.rb:72 ==(0) PipelineSourceKind::RangeChain
- unknown operation unresolved constant PipelineSourceKind::BindingChain: 1
  - src/mir/lower/pipeline/pipeline_plan.rb:77 ==(0) PipelineSourceKind::BindingChain
- unknown operation unresolved constant PipelineTerminalKind::Concurrent: 1
  - src/mir/lower/pipeline/pipeline_plan.rb:82 ==(0) PipelineTerminalKind::Concurrent
- unknown operation unresolved constant PipelineTerminalKind::Each: 1
  - src/mir/lower/pipeline/pipeline_plan.rb:87 ==(0) PipelineTerminalKind::Each
- unknown operation unresolved constant PipelineIndexValueOwnership::Owned: 1
  - src/mir/lower/pipeline/pipeline_set_index_lowerer.rb:322 ==(0) PipelineIndexValueOwnership::Owned
- unknown operation unresolved constant PipelineIndexValueOwnership::Borrowed: 1
  - src/mir/lower/pipeline/pipeline_set_index_lowerer.rb:353 ==(0) PipelineIndexValueOwnership::Borrowed
- unknown operation unresolved constant POOL_METHODS: 1
  - src/mir/lowering/expressions.rb:1312 lookup(0) POOL_METHODS
- unknown operation unresolved constant FailureActionKind::Block: 1
  - src/mir/mir.rb:2498 ==(0) FailureActionKind::Block
- unknown operation unresolved constant CatchDefaultAction::Body: 1
  - src/mir/mir.rb:2601 ==(0) CatchDefaultAction::Body
- unknown operation unresolved constant MIR::Orelse: 1
  - src/mir/mir_lowering.rb:569 owned_or_destination?(3) MIR::Orelse
- unknown operation unresolved constant MIR::TryCatch: 1
  - src/mir/mir_lowering.rb:570 owned_or_destination?(3) MIR::TryCatch
- unknown operation unresolved constant BUILTIN_OPS: 1
  - src/mir/mir_lowering.rb:3396 lookup(0) BUILTIN_OPS
- unknown operation unresolved constant SET_METHODS: 1
  - src/mir/rewriters/pipeline_rewriter.rb:712 lookup(0) SET_METHODS

### Return Unknown Expression Causes
- unknown local variable value: 20
  - src/annotator/helpers/intrinsic_registry.rb:162 `IntrinsicRegistry#normalize_lifetime` value
  - src/mir/fsm_lowering.rb:182 `FsmLowering#coerce_fsm_result_value` value
  - src/mir/fsm_lowering.rb:182 `FsmLowering#coerce_fsm_result_value` value
  - src/mir/lowering/control_flow.rb:919 `MIRLoweringControlFlow#return_payload_pointer_value` value
  - src/mir/lowering/control_flow.rb:919 `MIRLoweringControlFlow#return_payload_pointer_value` value
  - src/mir/lowering/control_flow.rb:919 `MIRLoweringControlFlow#return_payload_pointer_value` value
  - src/mir/lowering/control_flow.rb:919 `MIRLoweringControlFlow#return_payload_pointer_value` value
  - src/mir/lowering/control_flow.rb:937 `MIRLoweringControlFlow#heap_carry_return_value` value
- unknown local variable result: 7
  - src/annotator/annotator.rb:689 `SemanticAnnotator#visit` result
  - src/ast/parser.rb:719 `ClearParser#parse_statement` result
  - src/ast/parser.rb:3861 `ClearParser#parse_bg_body_stmt` result
  - src/mir/hoist.rb:455 `MIRHoistLowering#lower_scoped` result
  - src/mir/lowering/control_flow.rb:547 `MIRLoweringControlFlow#lower_match` result
  - src/mir/lowering/variables.rb:709 `MIRLoweringVariables#lower_bind_expr` result
  - src/mir/lowering/variables.rb:709 `MIRLoweringVariables#lower_bind_expr` result
- unknown local variable expr: 6
  - src/ast/parser.rb:719 `ClearParser#parse_statement` expr
  - src/ast/parser.rb:3861 `ClearParser#parse_bg_body_stmt` expr
  - src/mir/hoist.rb:624 `MIRHoistLowering#hoist_alloc` expr
  - src/mir/hoist.rb:624 `MIRHoistLowering#hoist_alloc` expr
  - src/mir/mir_pass.rb:378 `MIRPass#unwrap_return_expr` expr
  - src/mir/mir_pass.rb:378 `MIRPass#unwrap_return_expr` expr
- unknown local variable left: 6
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue` left
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue` left
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue` left
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue` left
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue` left
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue` left
- unknown local variable mir: 6
  - src/mir/lowering/functions.rb:1902 `MIRLoweringFunctions#lower_extern_arg` mir
  - src/mir/mir_lowering.rb:790 `MIRLowering#place_owned_branch_value_for_destination` mir
  - src/mir/mir_lowering.rb:918 `MIRLowering#lower` mir
  - src/mir/mir_lowering.rb:1358 `MIRLowering#place_discarded_owned_branch_value` mir
  - src/mir/mir_lowering.rb:1358 `MIRLowering#place_discarded_owned_branch_value` mir
  - src/mir/mir_lowering.rb:1358 `MIRLowering#place_discarded_owned_branch_value` mir
- unknown local variable node: 4
  - src/ast/parser.rb:2518 `ClearParser#parse_lit` node
  - src/mir/hoist.rb:502 `MIRHoistLowering#with_pending` node
  - src/mir/rewriters/pipeline_rewriter.rb:765 `PipelineRewriter#replace_named_placeholder` node
  - src/mir/rewriters/pipeline_rewriter.rb:783 `PipelineRewriter#replace_placeholder` node
- unknown local variable init: 4
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
  - src/mir/lowering/variables.rb:198 `MIRLoweringVariables#ensure_cleanup_binding_owns_string_init` init
- unknown local variable inner: 4
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init` inner
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init` inner
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init` inner
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init` inner
- unknown local variable call: 3
  - src/mir/lowering/concurrency.rb:1222 `MIRLoweringConcurrency#lower_next_expr` call
  - src/mir/lowering/concurrency.rb:1222 `MIRLoweringConcurrency#lower_next_expr` call
  - src/mir/rewriters/pipeline_rewriter.rb:94 `PipelineRewriter#rewrite_pipeline` call
- unknown local variable block: 3
  - src/mir/lowering/concurrency.rb:1222 `MIRLoweringConcurrency#lower_next_expr` block
  - src/mir/lowering/concurrency.rb:1222 `MIRLoweringConcurrency#lower_next_expr` block
  - src/mir/lowering/literals.rb:81 `MIRLoweringLiterals#lower_list_lit` block
- unknown expression with multiple unknown types: 2
  - src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture` yield node.capture_analysis
  - src/mir/lowering/expressions.rb:963 `MIRLoweringExpressions#or_fallback_expected_type` function_state.current_expected_type || node.full_type!(context: "OR fallback expected type")
- unknown local variable lhs: 2
  - src/ast/parser.rb:1754 `ClearParser#parse_expression` lhs
  - src/ast/parser.rb:1942 `ClearParser#parse_suffixes` lhs
- unknown local variable lit: 2
  - src/ast/parser.rb:2518 `ClearParser#parse_lit` lit
  - src/ast/parser.rb:2518 `ClearParser#parse_lit` lit
- unknown local variable loop_stmt: 2
  - src/mir/lowering/control_flow.rb:304 `MIRLoweringControlFlow#lower_for_each` loop_stmt
  - src/mir/lowering/control_flow.rb:361 `MIRLoweringControlFlow#for_each_loop_stmt` loop_stmt
- unknown local variable arg: 2
  - src/mir/lowering/functions.rb:993 `MIRLoweringFunctions#cross_boundary_arg` arg
  - src/mir/lowering/functions.rb:993 `MIRLoweringFunctions#cross_boundary_arg` arg
- unknown local variable intercept: 2
  - src/mir/lowering/functions.rb:1331 `MIRLoweringFunctions#lower_func_call` intercept
  - src/mir/lowering/functions.rb:1388 `MIRLoweringFunctions#lower_method_call` intercept
- unknown local variable new_node: 2
  - src/mir/rewriters/pipeline_rewriter.rb:765 `PipelineRewriter#replace_named_placeholder` new_node
  - src/mir/rewriters/pipeline_rewriter.rb:783 `PipelineRewriter#replace_placeholder` new_node
- unknown local variable actual_binding: 1
  - src/annotator/helpers/generic_analysis.rb:337 `GenericAnalysis#extract_type_bindings!` subst[p_res] = actual_binding
- unknown local variable x: 1
  - src/annotator/helpers/intrinsic_registry.rb:221 `IntrinsicRegistry#fs` x
- unknown local variable stmt: 1
  - src/ast/ast.rb:777 `AST#each_bg_block_in_stmt` yield stmt
- unknown operation InstanceVariableOrWriteNode: 1
  - src/ast/diagnostic_examples.rb:65 `DiagnosticExamples#all` @all ||= load!
- unknown local variable k: 1
  - src/ast/diagnostic_examples.rb:143 `DiagnosticExamples#find_block_end` k
- unknown local variable bind: 1
  - src/ast/parser.rb:737 `ClearParser#try_parse_bind_or_assign` bind
- unknown local variable asgn: 1
  - src/ast/parser.rb:737 `ClearParser#try_parse_bind_or_assign` asgn
- unknown local variable schema: 1
  - src/ast/scope.rb:479 `ScopeHelper#lookup_type_schema` schema
- unknown local variable node_or_token: 1
  - src/ast/source_error.rb:168 `ErrorHelper#diagnostic_token` node_or_token
- unknown local variable diags: 1
  - src/lsp/diagnostics.rb:59 `LSP::Diagnostics#from_result` diags
- unknown local variable strict: 1
  - src/lsp/hover.rb:64 `LSP::Hover#find_overlapping` strict
- unknown local variable cond: 1
  - src/mir/lowering/control_flow.rb:100 `MIRLoweringControlFlow#loop_condition_expr` cond
- unknown local variable lowered: 1
  - src/mir/lowering/control_flow.rb:114 `MIRLoweringControlFlow#lower_control_condition` lowered
- unknown local variable success: 1
  - src/mir/lowering/expressions.rb:963 `MIRLoweringExpressions#or_fallback_expected_type` success
- unknown local variable eu_success: 1
  - src/mir/lowering/expressions.rb:963 `MIRLoweringExpressions#or_fallback_expected_type` eu_success
- unknown local variable boundary_arg: 1
  - src/mir/lowering/functions.rb:1230 `MIRLoweringFunctions#lower_call_arg_from_facts` boundary_arg
- unknown local variable inner_mir: 1
  - src/mir/lowering/variables.rb:123 `MIRLoweringVariables#compose_capability_wrap` inner_mir
- unknown local variable placed: 1
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init` placed
- unknown local variable set: 1
  - src/mir/lowering/variables.rb:1254 `MIRLoweringVariables#lower_auto_lock_assignment` set
- unknown forwarded return fs: 1
  - src/mir/mir.rb:4781 `MIR::StdlibDefFsCoercion#stdlib_def=` super(IntrinsicRegistry.fs(v))
- unknown local variable root: 1
  - src/mir/mir_lowering.rb:2697 `MIRLowering#root_receiver_node` root
- unknown local variable generic_fn: 1
  - src/mir/mir_lowering.rb:2853 `MIRLowering#lower_union_def` generic_fn
- unknown local variable union_node: 1
  - src/mir/mir_lowering.rb:2853 `MIRLowering#lower_union_def` union_node
- unknown local variable op: 1
  - src/mir/rewriters/pipeline_rewriter.rb:94 `PipelineRewriter#rewrite_pipeline` op
- unknown local variable wrapper: 1
  - src/mir/rewriters/pipeline_rewriter.rb:291 `PipelineRewriter#fuse_pipeline` wrapper
- unknown local variable new_source: 1
  - src/mir/rewriters/pipeline_rewriter.rb:756 `PipelineRewriter#patch_chain_source!` cursor.left = new_source
- unknown local variable current: 1
  - src/semantic/escape_analysis.rb:579 `EscapeAnalysis#unwrap_value` current

## Nilability Pressure By Root Callsite
- pressure: how many review actions are attributed to the same source location
- root callsite: the caller/source location where nil entered one or more typed slots
- src/ast/symbol_entry.rb:471 priority 7.01; affects `T.nilable` in 1 signature slot(s), 1022422 observed call(s)
  - src/ast/symbol_entry.rb:471 reg
- src/annotator/helpers/intrinsic_arg_spec.rb:37 priority 6.02; affects `T.nilable` in 1 signature slot(s), 104314 observed call(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:37 raw (candidate T.any(Array, Symbol))
- src/annotator/helpers/function_signature.rb:377 priority 5.89; affects `T.nilable` in 1 signature slot(s), 77589 observed call(s)
  - src/annotator/helpers/function_signature.rb:377 arg_spec (candidate T.any(Array, Symbol))
- src/annotator/helpers/auto_inference.rb:215 priority 5.88; affects `T.nilable` in 1 signature slot(s), 75957 observed call(s)
  - src/annotator/helpers/auto_inference.rb:215 node
- src/annotator/helpers/intrinsic_registry.rb:162 priority 5.87; affects `T.nilable` in 1 signature slot(s), 74052 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:162 value (candidate T.any(Array, String, Symbol))
- src/mir/lowering/control_flow.rb:209 priority 5.83; affects `T.nilable` in 2 signature slot(s), 1326 observed call(s)
  - src/mir/lowering/control_flow.rb:209 mark_per_iter (candidate T::Boolean)
  - src/mir/lowering/control_flow.rb:209 tight (candidate T::Boolean)
- src/tools/lint_fix_rewriter.rb:212 priority 5.63; affects `T.nilable` in 1 signature slot(s), 42948 observed call(s)
  - src/tools/lint_fix_rewriter.rb:212 n
- src/mir/hoist.rb:599 priority 5.52; affects `T.nilable` in 1 signature slot(s), 33444 observed call(s)
  - src/mir/hoist.rb:599 value
- src/mir/hoist.rb:611 priority 5.52; affects `T.nilable` in 1 signature slot(s), 33444 observed call(s)
  - src/mir/hoist.rb:611 value
- src/mir/pre_mir_type_check.rb:70 priority 5.50; affects `T.nilable` in 1 signature slot(s), 31604 observed call(s)
  - src/mir/pre_mir_type_check.rb:70 node
- src/tools/predicate_rewriter.rb:129 priority 5.49; affects `T.nilable` in 1 signature slot(s), 31116 observed call(s)
  - src/tools/predicate_rewriter.rb:129 n
- src/tools/method_rewriter.rb:141 priority 5.49; affects `T.nilable` in 1 signature slot(s), 31060 observed call(s)
  - src/tools/method_rewriter.rb:141 node
- src/tools/predicate_rewriter.rb:114 priority 5.49; affects `T.nilable` in 1 signature slot(s), 30870 observed call(s)
  - src/tools/predicate_rewriter.rb:114 node
- src/annotator/helpers/intrinsic_registry.rb:170 priority 5.43; affects `T.nilable` in 1 signature slot(s), 26725 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:170 spec (candidate T.any(Array, Symbol))
- src/mir/hoist.rb:230 priority 5.36; affects `T.nilable` in 1 signature slot(s), 23064 observed call(s)
  - src/mir/hoist.rb:230 node
- src/mir/hoist.rb:245 priority 5.36; affects `T.nilable` in 1 signature slot(s), 23064 observed call(s)
  - src/mir/hoist.rb:245 child
- src/annotator/helpers/intrinsic_registry.rb:117 priority 5.34; affects `T.nilable` in 1 signature slot(s), 21857 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:117 v
- src/tools/lint_fix_rewriter.rb:67 priority 5.33; affects `T.nilable` in 1 signature slot(s), 21473 observed call(s)
  - src/tools/lint_fix_rewriter.rb:67 node
- src/tools/lint_fix_rewriter.rb:198 priority 5.33; affects `T.nilable` in 1 signature slot(s), 21473 observed call(s)
  - src/tools/lint_fix_rewriter.rb:198 node
- src/tools/lint_fix_rewriter.rb:88 priority 5.33; affects `T.nilable` in 1 signature slot(s), 21472 observed call(s)
  - src/tools/lint_fix_rewriter.rb:88 node
- src/mir/hoist.rb:646 priority 5.27; affects `T.nilable` in 1 signature slot(s), 18451 observed call(s)
  - src/mir/hoist.rb:646 ast_node (candidate AST::Literal)
- src/tools/method_rewriter.rb:65 priority 5.26; affects `T.nilable` in 1 signature slot(s), 18219 observed call(s)
  - src/tools/method_rewriter.rb:65 node
- src/ast/type.rb:3074 priority 5.08; affects `T.nilable` in 1 signature slot(s), 11962 observed call(s)
  - src/ast/type.rb:3074 vt (candidate T.any(Schemas::InlineStructVariant, Type))
- src/annotator/helpers/intrinsic_arg_spec.rb:67 priority 5.04; affects `T.nilable` in 1 signature slot(s), 10932 observed call(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:67 value (candidate T.any(String, Symbol))
- src/ast/ast.rb:745 priority 4.98; affects `T.nilable` in 1 signature slot(s), 9482 observed call(s)
  - src/ast/ast.rb:745 expr
- src/annotator/helpers/intrinsic_arg_spec.rb:59 priority 4.81; affects `T.nilable` in 1 signature slot(s), 6454 observed call(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:59 value (candidate T.any(String, Symbol))
- src/ast/ast.rb:839 priority 4.79; affects `T.nilable` in 1 signature slot(s), 6114 observed call(s)
  - src/ast/ast.rb:839 node
- src/mir/hoist.rb:990 priority 4.77; affects `T.nilable` in 1 signature slot(s), 5830 observed call(s)
  - src/mir/hoist.rb:990 expr
- src/mir/test_lowering.rb:325 priority 4.72; affects `T.nilable` in 1 signature slot(s), 5234 observed call(s)
  - src/mir/test_lowering.rb:325 receiver
- src/annotator/helpers/function_signature.rb:280 priority 4.70; affects `T.nilable` in 1 signature slot(s), 4958 observed call(s)
  - src/annotator/helpers/function_signature.rb:280 x
- src/mir/mir_checker.rb:1007 priority 4.51; affects `T.nilable` in 1 signature slot(s), 3251 observed call(s)
  - src/mir/mir_checker.rb:1007 expr
- src/mir/mir_checker.rb:1022 priority 4.51; affects `T.nilable` in 1 signature slot(s), 3251 observed call(s)
  - src/mir/mir_checker.rb:1022 expr
- src/mir/mir_checker.rb:1029 priority 4.51; affects `T.nilable` in 1 signature slot(s), 3251 observed call(s)
  - src/mir/mir_checker.rb:1029 expr
- src/mir/hoist.rb:1220 priority 4.45; affects `T.nilable` in 1 signature slot(s), 2805 observed call(s)
  - src/mir/hoist.rb:1220 ast_node
- src/semantic/escape_analysis.rb:1032 priority 4.30; affects `T.nilable` in 1 signature slot(s), 1987 observed call(s)
  - src/semantic/escape_analysis.rb:1032 expr
- src/semantic/escape_analysis.rb:1015 priority 4.30; affects `T.nilable` in 1 signature slot(s), 1987 observed call(s)
  - src/semantic/escape_analysis.rb:1015 expr
- src/semantic/escape_analysis.rb:1052 priority 4.30; affects `T.nilable` in 1 signature slot(s), 1987 observed call(s)
  - src/semantic/escape_analysis.rb:1052 expr
- src/mir/lowering/control_flow.rb:912 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1921 observed call(s)
  - src/mir/lowering/control_flow.rb:912 value
- src/mir/lowering/control_flow.rb:919 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1921 observed call(s)
  - src/mir/lowering/control_flow.rb:919 value
- src/mir/lowering/control_flow.rb:937 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1921 observed call(s)
  - src/mir/lowering/control_flow.rb:937 value
- src/mir/lowering/control_flow.rb:950 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1921 observed call(s)
  - src/mir/lowering/control_flow.rb:950 value
- src/mir/lowering/control_flow.rb:962 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1921 observed call(s)
  - src/mir/lowering/control_flow.rb:962 value
- src/mir/lowering/control_flow.rb:968 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1921 observed call(s)
  - src/mir/lowering/control_flow.rb:968 value
- src/mir/lowering/control_flow.rb:1175 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1912 observed call(s)
  - src/mir/lowering/control_flow.rb:1175 expr
- src/mir/mir_checker.rb:351 priority 4.28; affects `T.nilable` in 1 signature slot(s), 1904 observed call(s)
  - src/mir/mir_checker.rb:351 fn_name
- src/mir/mir_checker.rb:969 priority 4.21; affects `T.nilable` in 1 signature slot(s), 1628 observed call(s)
  - src/mir/mir_checker.rb:969 expr
- src/mir/mir_checker.rb:992 priority 4.21; affects `T.nilable` in 1 signature slot(s), 1628 observed call(s)
  - src/mir/mir_checker.rb:992 expr
- src/mir/mir.rb:2891 priority 4.06; affects `T.nilable` in 1 signature slot(s), 1139 observed call(s)
  - src/mir/mir.rb:2891 capacity (candidate Integer)
- src/semantic/escape_analysis.rb:1176 priority 4.02; affects `T.nilable` in 1 signature slot(s), 1047 observed call(s)
  - src/semantic/escape_analysis.rb:1176 returned_names (candidate Set)
- src/backends/transpiler.rb:154 priority 3.93; affects `T.nilable` in 1 signature slot(s), 846 observed call(s)
  - src/backends/transpiler.rb:154 override

## Union Pressure Downgraded To `T.untyped`
- downgrade: a slot observed with multiple runtime types was kept as `T.untyped` instead of emitted as `T.any(...)`
- why it happens: `T.any(...)` is risky when the runtime sample may not include every type that can reach the slot
Changing these to T.any(...) can be dangerous unless you are certain the runtime sample includes every type that can reach the slot. Static analysis can separately look for other types that could be passed without breaking the function.
- src/ast/type.rb:3665 priority 7.68; affects `T.any` in 2 signature slot(s), 26903 observed call(s)
  - src/ast/type.rb:3665 source_type (observed Symbol, Type)
  - src/ast/type.rb:3665 target_type (observed Symbol, Type)
- src/annotator/helpers/intrinsic_registry.rb:221 priority 7.56; affects `T.any` in 2 signature slot(s), 22117 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:221 x (observed FunctionSignature, Hash, Symbol)
  - src/annotator/helpers/intrinsic_registry.rb:221 name (observed String, Symbol)
- src/annotator/helpers/function_analysis.rb:89 priority 7.46; affects `T.any` in 2 signature slot(s), 18777 observed call(s)
  - src/annotator/helpers/function_analysis.rb:89 body (observed AST::BinaryOp, AST::Identifier, AST::Literal, Array)
  - src/annotator/helpers/function_analysis.rb:89 declared_return (observed Symbol, Type)
- src/annotator/helpers/auto_inference.rb:215 priority 7.12; affects `T.any` in 1 signature slot(s), 1304184 observed call(s)
  - src/annotator/helpers/auto_inference.rb:215 node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- src/ast/lexer.rb:294 priority 7.04; affects `T.any` in 1 signature slot(s), 1106676 observed call(s)
  - src/ast/lexer.rb:294 val (observed Float, Integer, String)
- src/mir/hoist.rb:245 priority 6.92; affects `T.any` in 1 signature slot(s), 825714 observed call(s)
  - src/mir/hoist.rb:245 child (observed AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, ...)
- src/mir/hoist.rb:230 priority 6.91; affects `T.any` in 1 signature slot(s), 804549 observed call(s)
  - src/mir/hoist.rb:230 node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- src/mir/hoist.rb:599 priority 6.67; affects `T.any` in 1 signature slot(s), 465139 observed call(s)
  - src/mir/hoist.rb:599 value (observed AST::BinaryOp, Array, FalseClass, FunctionSignature, Hash, ...)
- src/mir/hoist.rb:611 priority 6.67; affects `T.any` in 1 signature slot(s), 465139 observed call(s)
  - src/mir/hoist.rb:611 value (observed AST::BinaryOp, Array, FalseClass, FunctionSignature, Hash, ...)
- src/annotator/helpers/function_signature.rb:280 priority 6.18; affects `T.any` in 1 signature slot(s), 151377 observed call(s)
  - src/annotator/helpers/function_signature.rb:280 x (observed Array, FunctionSignature, Symbol, Type)
- src/annotator/helpers/intrinsic_arg_spec.rb:20 priority 6.11; affects `T.any` in 1 signature slot(s), 128562 observed call(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:20 raw (observed Hash, Symbol)
- src/ast/type.rb:1429 priority 6.07; affects `T.any` in 1 signature slot(s), 117685 observed call(s)
  - src/ast/type.rb:1429 other (observed Symbol, Type)
- src/annotator/helpers/intrinsic_arg_spec.rb:37 priority 5.99; affects `T.any` in 1 signature slot(s), 97661 observed call(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:37 raw (observed Array, Symbol)
- src/mir/lowering/control_flow.rb:209 priority 5.96; affects `T.any` in 2 signature slot(s), 1628 observed call(s)
  - src/mir/lowering/control_flow.rb:209 mark_per_iter (observed FalseClass, TrueClass)
  - src/mir/lowering/control_flow.rb:209 tight (observed FalseClass, TrueClass)
- src/annotator/helpers/intrinsic_registry.rb:45 priority 5.88; affects `T.any` in 1 signature slot(s), 75588 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:45 h (observed Hash, Symbol, `T.untyped`)
- src/annotator/helpers/intrinsic_registry.rb:141 priority 5.88; affects `T.any` in 1 signature slot(s), 75552 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:141 _name (observed String, Symbol)
- src/annotator/helpers/intrinsic_registry.rb:117 priority 5.75; affects `T.any` in 1 signature slot(s), 56387 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:117 v (observed Hash, Proc, String, Symbol, Type)
- src/ast/source_error.rb:31 priority 5.72; affects `T.any` in 2 signature slot(s), 1103 observed call(s)
  - src/ast/source_error.rb:31 node_or_token (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
  - src/ast/source_error.rb:31 code_or_message (observed String, Symbol)
- src/ast/source_error.rb:141 priority 5.70; affects `T.any` in 2 signature slot(s), 1075 observed call(s)
  - src/ast/source_error.rb:141 node_or_token (observed AST::Assignment, AST::BgBlock, AST::BindExpr, AST::FunctionDef, AST::GetField, ...)
  - src/ast/source_error.rb:141 raise_in_collector (observed FalseClass, TrueClass)
- src/annotator/helpers/function_signature.rb:377 priority 5.69; affects `T.any` in 1 signature slot(s), 48834 observed call(s)
  - src/annotator/helpers/function_signature.rb:377 arg_spec (observed Array, Symbol)
- src/annotator/helpers/intrinsic_registry.rb:170 priority 5.69; affects `T.any` in 1 signature slot(s), 48827 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:170 spec (observed Array, Symbol)
- src/backends/zig_type_mapper.rb:39 priority 5.53; affects `T.any` in 1 signature slot(s), 34103 observed call(s)
  - src/backends/zig_type_mapper.rb:39 type (observed String, Symbol, Type)
- src/annotator/helpers/intrinsic_registry.rb:277 priority 5.48; affects `T.any` in 1 signature slot(s), 30196 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:277 name (observed String, Symbol)
- src/ast/type.rb:3660 priority 5.43; affects `T.any` in 1 signature slot(s), 27020 observed call(s)
  - src/ast/type.rb:3660 input (observed Symbol, Type)
- src/ast/type.rb:3673 priority 5.39; affects `T.any` in 1 signature slot(s), 24702 observed call(s)
  - src/ast/type.rb:3673 effective_type (observed FunctionSignature, Symbol, Type)
- src/mir/fsm_transform.rb:65 priority 5.32; affects `T.any` in 2 signature slot(s), 577 observed call(s)
  - src/mir/fsm_transform.rb:65 bg_block (observed AST::BgBlock, `T.untyped`)
  - src/mir/fsm_transform.rb:65 lowering (observed MIRLowering, `T.untyped`)
- src/ast/type.rb:3091 priority 5.29; affects `T.any` in 1 signature slot(s), 19443 observed call(s)
  - src/ast/type.rb:3091 node (observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, ...)
- src/mir/alloc.rb:29 priority 5.25; affects `T.any` in 1 signature slot(s), 17679 observed call(s)
  - src/mir/alloc.rb:29 final_type (observed Symbol, Type)
- src/ast/ast.rb:397 priority 5.21; affects `T.any` in 1 signature slot(s), 16320 observed call(s)
  - src/ast/ast.rb:397 root (observed AST::BgBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::Cast, ...)
- src/ast/type.rb:3074 priority 5.05; affects `T.any` in 1 signature slot(s), 11346 observed call(s)
  - src/ast/type.rb:3074 vt (observed Schemas::InlineStructVariant, Type)
- src/ast/ast.rb:1014 priority 5.03; affects `T.any` in 1 signature slot(s), 10730 observed call(s)
  - src/ast/ast.rb:1014 val (observed Symbol, Type)
- src/semantic/effect_set.rb:44 priority 4.92; affects `T.any` in 1 signature slot(s), 8348 observed call(s)
  - src/semantic/effect_set.rb:44 effects (observed Array, Set)
- src/ast/type.rb:3104 priority 4.90; affects `T.any` in 1 signature slot(s), 7977 observed call(s)
  - src/ast/type.rb:3104 node (observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, ...)
- src/mir/mir_lowering.rb:1331 priority 4.87; affects `T.any` in 1 signature slot(s), 7376 observed call(s)
  - src/mir/mir_lowering.rb:1331 mir (observed Array, MIR::AllocMark, MIR::AssertStmt, MIR::BinOp, MIR::BlockExpr, ...)
- src/annotator/helpers/function_analysis.rb:873 priority 4.80; affects `T.any` in 1 signature slot(s), 6297 observed call(s)
  - src/annotator/helpers/function_analysis.rb:873 node (observed AST::FuncCall, AST::MethodCall, `T.untyped`)
- src/annotator/helpers/fixable_helpers.rb:68 priority 4.80; affects `T.any` in 2 signature slot(s), 246 observed call(s)
  - src/annotator/helpers/fixable_helpers.rb:68 input (observed String, Symbol)
  - src/annotator/helpers/fixable_helpers.rb:68 candidates (observed Array, Set)
- src/annotator/helpers/auto_inference.rb:242 priority 4.74; affects `T.any` in 1 signature slot(s), 5469 observed call(s)
  - src/annotator/helpers/auto_inference.rb:242 node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- src/mir/cleanup_classifier.rb:474 priority 4.67; affects `T.any` in 1 signature slot(s), 4715 observed call(s)
  - src/mir/cleanup_classifier.rb:474 full_type (observed Object, Type)
- src/mir/lowering/expressions.rb:221 priority 4.65; affects `T.any` in 1 signature slot(s), 4487 observed call(s)
  - src/mir/lowering/expressions.rb:221 value (observed Float, Integer)
- src/tools/lint_fix_rewriter.rb:254 priority 4.61; affects `T.any` in 1 signature slot(s), 4037 observed call(s)
  - src/tools/lint_fix_rewriter.rb:254 t (observed String, Symbol, Type)
- src/mir/control_flow.rb:1707 priority 4.58; affects `T.any` in 1 signature slot(s), 3823 observed call(s)
  - src/mir/control_flow.rb:1707 nodes (observed AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::ListLit, Array)
- src/ast/type.rb:3706 priority 4.54; affects `T.any` in 1 signature slot(s), 3478 observed call(s)
  - src/ast/type.rb:3706 effective_type (observed Symbol, Type)
- src/mir/fsm_transform/liveness.rb:257 priority 4.50; affects `T.any` in 1 signature slot(s), 3164 observed call(s)
  - src/mir/fsm_transform/liveness.rb:257 node (observed AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, ...)
- src/annotator/helpers/intrinsic_registry.rb:162 priority 4.48; affects `T.any` in 1 signature slot(s), 3005 observed call(s)
  - src/annotator/helpers/intrinsic_registry.rb:162 value (observed Array, String, Symbol)
- src/annotator/helpers/function_signature.rb:315 priority 4.36; affects `T.any` in 1 signature slot(s), 2300 observed call(s)
  - src/annotator/helpers/function_signature.rb:315 borrows (observed Array, Symbol)
- src/annotator/helpers/intrinsic_arg_spec.rb:67 priority 4.30; affects `T.any` in 1 signature slot(s), 1996 observed call(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:67 value (observed String, Symbol)
- src/ast/diagnostic_examples.rb:167 priority 4.29; affects `T.any` in 1 signature slot(s), 1968 observed call(s)
  - src/ast/diagnostic_examples.rb:167 expecting_raise (observed FalseClass, TrueClass)
- src/mir/mir.rb:4781 priority 4.14; affects `T.any` in 1 signature slot(s), 1392 observed call(s)
  - src/mir/mir.rb:4781 v (observed FunctionSignature, Hash)
- src/ast/ast.rb:745 priority 4.13; affects `T.any` in 1 signature slot(s), 1346 observed call(s)
  - src/ast/ast.rb:745 expr (observed AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, ...)
- src/mir/lowering/control_flow.rb:246 priority 4.10; affects `T.any` in 1 signature slot(s), 1260 observed call(s)
  - src/mir/lowering/control_flow.rb:246 mark_per_iter (observed FalseClass, TrueClass)

## `T.any` Downgrades By Signature
- signature downgrade: an individual param or return slot where union evidence exists but the report kept the current `T.untyped` signature
- src/annotator/helpers/function_signature.rb:377 arg_spec: observed Array, Symbol; kept as `T.untyped`
- src/annotator/helpers/intrinsic_arg_spec.rb:37 raw: observed Array, Symbol; kept as `T.untyped`
- src/annotator/helpers/function_signature.rb:315 borrows: observed Array, Symbol; kept as `T.untyped`
- src/ast/lexer.rb:294 val: observed Float, Integer, String; kept as `T.untyped`
- src/ast/parser.rb:1942 lhs: observed AST::BinaryOp, AST::CapabilityWrap, AST::CloneNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::ListLit, AST::Literal, AST::MethodCall, AST::NextExpr, AST::RangeLit, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/ast/symbol_entry.rb:471 reg: observed AST::BindExpr, AST::Identifier, AST::LetBinding, AST::StubDecl, AST::VarDecl, OpenStruct, String, Symbol, `T.untyped`; kept as `T.untyped`
- src/ast/ast.rb:397 root: observed AST::BgBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::Cast, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::Program, AST::ResolveNode, AST::StringConcat, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, Array; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:89 body: observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:89 declared_return: observed Symbol, Type; kept as `T.untyped`
- src/annotator/helpers/generic_analysis.rb:506 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/ast/type.rb:3673 node: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/ast/type.rb:3673 effective_type: observed FunctionSignature, Symbol, Type; kept as `T.untyped`
- src/ast/type.rb:3695 node: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/ast/type.rb:3706 effective_type: observed Symbol, Type; kept as `T.untyped`
- src/mir/alloc.rb:29 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/mir/alloc.rb:29 final_type: observed Symbol, Type; kept as `T.untyped`
- src/mir/alloc.rb:16 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator/helpers/generic_analysis.rb:582 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/ast/schemas.rb:376 s: observed Schemas::EnumSchema, Schemas::ResourceSchema, Schemas::StructSchema, Schemas::UnionSchema; kept as `T.untyped`
- src/ast/schemas.rb:379 s: observed Schemas::EnumSchema, Schemas::ResourceSchema, Schemas::StructSchema, Schemas::UnionSchema; kept as `T.untyped`
- src/annotator/helpers/capabilities.rb:41 node: observed AST::BindExpr, AST::VarDecl, Symbol; kept as `T.untyped`
- src/annotator/helpers/generic_analysis.rb:591 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator/helpers/generic_analysis.rb:607 expr: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, `T.untyped`; kept as `T.untyped`
- src/annotator/helpers/function_signature.rb:280 x: observed Array, FunctionSignature, Symbol, Type; kept as `T.untyped`
- src/annotator/helpers/function_signature.rb:341 fn: observed AST::FunctionDef, Object, `T.untyped`; kept as `T.untyped`
- src/annotator/helpers/function_signature.rb:672 fn: observed AST::FunctionDef, Object, `T.untyped`; kept as `T.untyped`
- src/annotator/helpers/auto_inference.rb:215 node: observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BatchWindowOp, AST::BenchmarkStmt, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BindExpr, AST::Binding, AST::BreakNode, AST::Capability, AST::CapabilityWrap, AST::Capture, AST::Cast, AST::CatchClause, AST::CatchFilter, AST::CatchItem, AST::CloneNode, AST::CollectOp, AST::ConcurrentOp, AST::ContinueNode, AST::CopyNode, AST::CountOp, AST::DefaultLit, AST::DeferredDrop, AST::DistinctOp, AST::DoBlock, AST::DoBranch, AST::EachOp, AST::EnumDef, AST::ErrorClause, AST::ExternFnDecl, AST::ExternStructDecl, AST::FindOp, AST::ForEach, AST::ForRange, AST::FreezeNode, AST::FuncCall, AST::FunctionDef, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfBind, AST::IfStatement, AST::IndexOp, AST::JoinOp, AST::LambdaLit, AST::LimitOp, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchCase, AST::MatchStatement, AST::MaxOp, AST::MethodCall, AST::MinOp, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::OrBreak, AST::OrExit, AST::OrPass, AST::OrPrune, AST::OrRaise, AST::OrderByOp, AST::Param, AST::PassStmt, AST::PatternField, AST::ProfileStmt, AST::Program, AST::Raise, AST::RangeLit, AST::RecoverOp, AST::ReduceOp, AST::RequireNode, AST::ResolveNode, AST::ReturnNode, AST::SelectOp, AST::ShardOp, AST::ShareNode, AST::SkipOp, AST::Slice, AST::SmashStmt, AST::StaticCall, AST::StructDef, AST::StructField, AST::StructLit, AST::StructPattern, AST::StubDecl, AST::SumOp, AST::SyncPolicyDecl, AST::TakeWhileOp, AST::TapOp, AST::TestBlock, AST::TestThat, AST::ThenChain, AST::ThenStep, AST::UnaryOp, AST::UnionDef, AST::UnionVariantLit, AST::UnnestOp, AST::VarDecl, AST::WhenBlock, AST::WhereOp, AST::WhileBindLoop, AST::WhileLoop, AST::WindowOp, AST::WithBlock, AST::YieldExpr, Array, CapabilityPlan::WithCapabilityPlan, FalseClass, Float, Hash, Integer, Lexer::Token, Schemas::InlineStructVariant, Scope, String, Symbol, SymbolEntry, TrueClass, Type; kept as `T.untyped`
- src/annotator/helpers/auto_inference.rb:242 node: observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BatchWindowOp, AST::BenchmarkStmt, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BindExpr, AST::Binding, AST::BreakNode, AST::Capability, AST::CapabilityWrap, AST::Capture, AST::Cast, AST::CatchClause, AST::CatchFilter, AST::CatchItem, AST::CloneNode, AST::CollectOp, AST::ConcurrentOp, AST::ContinueNode, AST::CopyNode, AST::CountOp, AST::DefaultLit, AST::DeferredDrop, AST::DistinctOp, AST::DoBlock, AST::DoBranch, AST::EachOp, AST::EnumDef, AST::ErrorClause, AST::ExternFnDecl, AST::ExternStructDecl, AST::FindOp, AST::ForEach, AST::ForRange, AST::FreezeNode, AST::FuncCall, AST::FunctionDef, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfBind, AST::IfStatement, AST::IndexOp, AST::JoinOp, AST::LambdaLit, AST::LimitOp, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchCase, AST::MatchStatement, AST::MaxOp, AST::MethodCall, AST::MinOp, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::OrBreak, AST::OrExit, AST::OrPass, AST::OrPrune, AST::OrRaise, AST::OrderByOp, AST::Param, AST::PassStmt, AST::PatternField, AST::ProfileStmt, AST::Program, AST::Raise, AST::RangeLit, AST::RecoverOp, AST::ReduceOp, AST::RequireNode, AST::ResolveNode, AST::ReturnNode, AST::SelectOp, AST::ShardOp, AST::ShareNode, AST::SkipOp, AST::Slice, AST::SmashStmt, AST::StaticCall, AST::StructDef, AST::StructField, AST::StructLit, AST::StructPattern, AST::StubDecl, AST::SumOp, AST::SyncPolicyDecl, AST::TakeWhileOp, AST::TapOp, AST::TestBlock, AST::TestThat, AST::ThenChain, AST::ThenStep, AST::UnaryOp, AST::UnionDef, AST::UnionVariantLit, AST::UnnestOp, AST::VarDecl, AST::WhenBlock, AST::WhereOp, AST::WhileBindLoop, AST::WhileLoop, AST::WindowOp, AST::WithBlock, AST::YieldExpr, CapabilityPlan::WithCapabilityPlan, Lexer::Token, Schemas::InlineStructVariant, Scope, SymbolEntry; kept as `T.untyped`
- src/ast/ast.rb:727 node: observed AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode, AST::ContinueNode, AST::CopyNode, AST::DoBlock, AST::ForEach, AST::ForRange, AST::FuncCall, AST::FunctionDef, AST::GetField, AST::Identifier, AST::IfBind, AST::IfStatement, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::PassStmt, AST::Raise, AST::ReturnNode, AST::StructDef, AST::ThenChain, AST::VarDecl, AST::WhileBindLoop, AST::WhileLoop, AST::WithBlock, AST::YieldExpr; kept as `T.untyped`
- src/ast/ast.rb:745 expr: observed AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CollectOp, AST::ConcurrentOp, AST::CopyNode, AST::CountOp, AST::DistinctOp, AST::FindOp, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::IndexOp, AST::JoinOp, AST::LambdaLit, AST::LimitOp, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MaxOp, AST::MethodCall, AST::MinOp, AST::MoveNode, AST::NextExpr, AST::OrBreak, AST::OrExit, AST::OrPass, AST::OrRaise, AST::OrderByOp, AST::RangeLit, AST::RecoverOp, AST::ReduceOp, AST::ResolveNode, AST::SelectOp, AST::ShareNode, AST::SkipOp, AST::Slice, AST::StaticCall, AST::StringConcat, AST::StructLit, AST::SumOp, AST::TakeWhileOp, AST::TapOp, AST::UnaryOp, AST::UnionVariantLit, AST::UnnestOp, AST::WhereOp, AST::WindowOp, Hash, Lexer::Token, Symbol; kept as `T.untyped`
- src/ast/ast.rb:839 node: observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BindExpr, AST::BlockExpr, AST::BreakNode, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CollectOp, AST::ConcurrentOp, AST::ContinueNode, AST::CopyNode, AST::CountOp, AST::DistinctOp, AST::DoBlock, AST::EachOp, AST::FindOp, AST::ForEach, AST::ForRange, AST::FreezeNode, AST::FuncCall, AST::FunctionDef, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfBind, AST::IfStatement, AST::IndexOp, AST::JoinOp, AST::LambdaLit, AST::LimitOp, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MaxOp, AST::MethodCall, AST::MinOp, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::OrBreak, AST::OrExit, AST::OrPass, AST::OrRaise, AST::OrderByOp, AST::PassStmt, AST::Raise, AST::RangeLit, AST::RecoverOp, AST::ReduceOp, AST::ResolveNode, AST::ReturnNode, AST::SelectOp, AST::ShardOp, AST::ShareNode, AST::SkipOp, AST::Slice, AST::StaticCall, AST::StringConcat, AST::StructDef, AST::StructLit, AST::SumOp, AST::TakeWhileOp, AST::TapOp, AST::UnaryOp, AST::UnionVariantLit, AST::UnnestOp, AST::VarDecl, AST::WhereOp, AST::WhileBindLoop, AST::WhileLoop, AST::WindowOp, AST::WithBlock; kept as `T.untyped`
- src/semantic/effect_set.rb:44 effects: observed Array, Set; kept as `T.untyped`
- src/ast/schemas.rb:382 s: observed Schemas::EnumSchema, Schemas::ResourceSchema, Schemas::StructSchema, Schemas::UnionSchema; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:1201 node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CloneNode, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::IfStatement, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:1260 node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CloneNode, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::IfStatement, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/ast/type.rb:1429 other: observed Symbol, Type; kept as `T.untyped`
- src/ast/type.rb:3665 source_type: observed Symbol, Type; kept as `T.untyped`
- src/ast/type.rb:3665 target_type: observed Symbol, Type; kept as `T.untyped`
- src/ast/type.rb:3660 input: observed Symbol, Type; kept as `T.untyped`
- src/ast/ast.rb:1014 val: observed Symbol, Type; kept as `T.untyped`
- src/ast/type.rb:3104 node: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::CloneNode, AST::ConcurrentOp, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StringConcat, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, AST::VarDecl, Object, `T.untyped`, Type; kept as `T.untyped`
- src/ast/type.rb:3091 node: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::CloneNode, AST::ConcurrentOp, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StringConcat, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, AST::VarDecl, Object, `T.untyped`, Type; kept as `T.untyped`
- src/ast/schemas.rb:385 s: observed Schemas::EnumSchema, Schemas::ResourceSchema, Schemas::StructSchema, Schemas::UnionSchema; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:350 node: observed AST::FuncCall, AST::MethodCall; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:887 arg_node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LambdaLit, AST::LinkNode, AST::Literal, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ShareNode, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:818 node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LinkNode, AST::Literal, AST::MethodCall, AST::StructLit, AST::UnaryOp; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:831 arg_node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LambdaLit, AST::LinkNode, AST::Literal, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ShareNode, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:846 arg_node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LambdaLit, AST::LinkNode, AST::Literal, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ShareNode, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/annotator/helpers/function_analysis.rb:873 node: observed AST::FuncCall, AST::MethodCall, `T.untyped`; kept as `T.untyped`
- src/annotator/helpers/with_match_check.rb:344 arg: observed AST::BgBlock, AST::BinaryOp, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LambdaLit, AST::Literal, AST::MethodCall, AST::MoveNode, AST::ShareNode, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, Object; kept as `T.untyped`

## Return Origin Pressure
- origin: the expression or forwarded callee that currently determines a method's return type
- pressure: how many untyped returns could be improved by fixing the same origin
- cascading return fix: a return annotation that can unlock other forwarded-return annotations after it becomes typed
- blocked: 111
- weak: 45
- strong: 13

Top root return blockers:
- untyped callee fixable!; affects 14 return(s); 15 source occurrence(s)
  - src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!`
  - src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!`
  - src/annotator/helpers/fixable_helpers.rb:812 `FixableHelper#emit_return_borrowed_no_copy_error!`
  - src/annotator/helpers/fixable_helpers.rb:898 `FixableHelper#emit_with_guard_all_bindings_need_as!`
- untyped callee each_pair; affects 7 return(s); 7 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
- untyped callee each; affects 6 return(s); 9 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
- untyped callee call; affects 5 return(s); 5 source occurrence(s)
  - src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves`
  - src/ast/scope.rb:502 `ScopeHelper#with_new_scope`
  - src/mir/mir_lowering.rb:2592 `MIRLowering#with_decl_alloc`
  - src/mir/mir_lowering.rb:2614 `MIRLowering#with_sink_type`
- untyped callee parse_suffixes; affects 5 return(s); 5 source occurrence(s)
  - src/ast/parser.rb:488 `ClearParser#parse_literal`
  - src/ast/parser.rb:1957 `ClearParser#parse_var_id`
  - src/ast/parser.rb:2473 `ClearParser#parse_primary`
  - src/ast/parser.rb:2518 `ClearParser#parse_lit`
- untyped callee hoist_alloc; affects 4 return(s); 5 source occurrence(s)
  - src/mir/lowering/control_flow.rb:114 `MIRLoweringControlFlow#lower_control_condition`
  - src/mir/lowering/expressions.rb:981 `MIRLoweringExpressions#materialize_or_fallback_value`
  - src/mir/lowering/expressions.rb:981 `MIRLoweringExpressions#materialize_or_fallback_value`
  - src/mir/lowering/functions.rb:1230 `MIRLoweringFunctions#lower_call_arg_from_facts`
- untyped callee each_value; affects 4 return(s); 4 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
- untyped callee cast; affects 3 return(s); 4 source occurrence(s)
  - src/mir/lowering/expressions.rb:2105 `MIRLoweringExpressions#lower_share`
  - src/mir/lowering/expressions.rb:2105 `MIRLoweringExpressions#lower_share`
  - src/mir/lowering/functions.rb:993 `MIRLoweringFunctions#cross_boundary_arg`
  - src/mir/lowering/literals.rb:81 `MIRLoweringLiterals#lower_list_lit`
- untyped callee instance_exec; affects 3 return(s); 3 source occurrence(s)
  - src/ast/parser.rb:719 `ClearParser#parse_statement`
  - src/ast/parser.rb:2473 `ClearParser#parse_primary`
  - src/ast/parser.rb:3861 `ClearParser#parse_bg_body_stmt`
- untyped callee lower; affects 2 return(s); 7 source occurrence(s)
  - src/mir/lowering/expressions.rb:325 `MIRLoweringExpressions#lower_binary_op`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
- untyped callee loop; affects 2 return(s); 2 source occurrence(s)
  - src/ast/lexer.rb:169 `Lexer#read_interpolated_string`
  - src/lsp/server.rb:51 `LSP::Server#run`
- untyped callee []; affects 2 return(s); 2 source occurrence(s); suggestion review as nilable lookup or replace with fetch/typed accessor
  - src/ast/parser.rb:141 `ClearParser#peek_at`
  - src/mir/fsm_ops.rb:348 `FsmOps::Lowerer#lower_expr`
- untyped callee parse_primary; affects 2 return(s); 2 source occurrence(s)
  - src/ast/parser.rb:1833 `ClearParser#parse_or_rescue`
  - src/ast/parser.rb:1911 `ClearParser#parse_unary`
- untyped callee first; affects 2 return(s); 2 source occurrence(s)
  - src/lsp/hover.rb:64 `LSP::Hover#find_overlapping`
  - src/mir/lowering/variables.rb:147 `MIRLoweringVariables#lower_var_decl`
- untyped callee place_value_for_destination; affects 2 return(s); 2 source occurrence(s)
  - src/mir/lowering/control_flow.rb:937 `MIRLoweringControlFlow#heap_carry_return_value`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
- untyped callee finalize_call_result; affects 2 return(s); 2 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/mir/lowering/functions.rb:1331 `MIRLoweringFunctions#lower_func_call`
  - src/mir/lowering/functions.rb:1388 `MIRLoweringFunctions#lower_method_call`
- untyped callee check_reads_in_expr; affects 1 return(s); 6 source occurrence(s)
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads`
- nil return at src/mir/fsm_transform/liveness.rb:257; affects 1 return(s); 6 source occurrence(s)
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents`
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents`
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents`
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents`
- untyped callee try_catch_with_provenance; affects 1 return(s); 6 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue`
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue`
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue`
  - src/mir/lowering/expressions.rb:874 `MIRLoweringExpressions#lower_or_rescue`
- untyped callee compose_capability_wrap; affects 1 return(s); 5 source occurrence(s)
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
- untyped callee return_with_transfer_marks; affects 1 return(s); 4 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/mir/lowering/control_flow.rb:886 `MIRLoweringControlFlow#lower_return`
  - src/mir/lowering/control_flow.rb:886 `MIRLoweringControlFlow#lower_return`
  - src/mir/lowering/control_flow.rb:886 `MIRLoweringControlFlow#lower_return`
  - src/mir/lowering/control_flow.rb:886 `MIRLoweringControlFlow#lower_return`
- untyped callee suspend_for; affects 1 return(s); 3 source occurrence(s)
  - src/mir/fsm_transform/segments.rb:344 `FsmTransform::Segments#classify_suspend`
  - src/mir/fsm_transform/segments.rb:344 `FsmTransform::Segments#classify_suspend`
  - src/mir/fsm_transform/segments.rb:344 `FsmTransform::Segments#classify_suspend`
- nil return at src/annotator/annotator.rb:689; affects 1 return(s); 2 source occurrence(s)
  - src/annotator/annotator.rb:689 `SemanticAnnotator#visit`
  - src/annotator/annotator.rb:689 `SemanticAnnotator#visit`
- untyped callee walk_binops; affects 1 return(s); 2 source occurrence(s)
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
- nil return at src/annotator/helpers/fixable_helpers.rb:1597; affects 1 return(s); 2 source occurrence(s)
  - src/annotator/helpers/fixable_helpers.rb:1597 `FixableHelper#emit_auto_shape_resolved_finding!`
  - src/annotator/helpers/fixable_helpers.rb:1597 `FixableHelper#emit_auto_shape_resolved_finding!`
- untyped callee _expr_each_concurrent_capture; affects 1 return(s); 2 source occurrence(s)
  - src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture`
  - src/ast/ast.rb:839 `AST#_expr_each_concurrent_capture`
- untyped callee check_call_reads; affects 1 return(s); 2 source occurrence(s)
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1333 `UseAfterMoveChecker#check_stmt_reads`
- nil return at src/mir/fsm_ops.rb:487; affects 1 return(s); 2 source occurrence(s)
  - src/mir/fsm_ops.rb:487 `FsmOps#walk`
  - src/mir/fsm_ops.rb:487 `FsmOps#walk`
- untyped callee with_pending; affects 1 return(s); 2 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/mir/lowering/control_flow.rb:125 `MIRLoweringControlFlow#lower_if`
  - src/mir/lowering/control_flow.rb:125 `MIRLoweringControlFlow#lower_if`
- untyped callee lower_next_expr; affects 1 return(s); 2 source occurrence(s)
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`

Top cascading return fixes:
- nil return at src/annotator/helpers/intrinsic_registry.rb:73; may unlock 1 return(s) (1 direct, 0 cascading), 1 possible param flow(s)
  - src/annotator/helpers/intrinsic_registry.rb:72 `IntrinsicRegistry#nested_emit`
- nil return at src/ast/type.rb:2678; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/type.rb:2677 `Type#stream_capacity`
- nil return at src/mir/fsm_transform/segments.rb:365; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/mir/fsm_transform/segments.rb:361 `FsmTransform::Segments#suspend_for`
- unknown expression at src/mir/rewriters/pipeline_rewriter.rb:761; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/mir/rewriters/pipeline_rewriter.rb:756 `PipelineRewriter#patch_chain_source!`
- nil return at src/mir/test_lowering.rb:328; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/mir/test_lowering.rb:325 `TestLowering#stub_intercept_for`

Forwarded return blocker pressure:
- fixable!: callee return still untyped; affects 14 return(s), 0 possible param flow(s)
  - src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!`
  - src/annotator/helpers/fixable_helpers.rb:770 `FixableHelper#emit_match_partial_fix!`
  - src/annotator/helpers/fixable_helpers.rb:812 `FixableHelper#emit_return_borrowed_no_copy_error!`
  - src/annotator/helpers/fixable_helpers.rb:898 `FixableHelper#emit_with_guard_all_bindings_need_as!`
- each_pair: unresolved forwarded callee; affects 7 return(s), 0 possible param flow(s)
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
- each: ambiguous method name; affects 6 return(s), 0 possible param flow(s)
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
- call: ambiguous method name; affects 5 return(s), 49 possible param flow(s)
  - src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves`
  - src/ast/scope.rb:502 `ScopeHelper#with_new_scope`
  - src/mir/mir_lowering.rb:2592 `MIRLowering#with_decl_alloc`
  - src/mir/mir_lowering.rb:2614 `MIRLowering#with_sink_type`
- parse_suffixes: callee return still untyped; affects 5 return(s), 0 possible param flow(s)
  - src/ast/parser.rb:488 `ClearParser#parse_literal`
  - src/ast/parser.rb:1957 `ClearParser#parse_var_id`
  - src/ast/parser.rb:2473 `ClearParser#parse_primary`
  - src/ast/parser.rb:2518 `ClearParser#parse_lit`
- hoist_alloc: static candidate MIR::Ident; affects 4 return(s), 6 possible param flow(s)
  - src/mir/lowering/control_flow.rb:114 `MIRLoweringControlFlow#lower_control_condition`
  - src/mir/lowering/expressions.rb:981 `MIRLoweringExpressions#materialize_or_fallback_value`
  - src/mir/lowering/expressions.rb:981 `MIRLoweringExpressions#materialize_or_fallback_value`
  - src/mir/lowering/functions.rb:1230 `MIRLoweringFunctions#lower_call_arg_from_facts`
- each_value: unresolved forwarded callee; affects 4 return(s), 0 possible param flow(s)
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`
- cast: unresolved forwarded callee; affects 3 return(s), 182 possible param flow(s)
  - src/mir/lowering/expressions.rb:2105 `MIRLoweringExpressions#lower_share`
  - src/mir/lowering/expressions.rb:2105 `MIRLoweringExpressions#lower_share`
  - src/mir/lowering/functions.rb:993 `MIRLoweringFunctions#cross_boundary_arg`
  - src/mir/lowering/literals.rb:81 `MIRLoweringLiterals#lower_list_lit`
- instance_exec: unresolved forwarded callee; affects 3 return(s), 0 possible param flow(s)
  - src/ast/parser.rb:719 `ClearParser#parse_statement`
  - src/ast/parser.rb:2473 `ClearParser#parse_primary`
  - src/ast/parser.rb:3861 `ClearParser#parse_bg_body_stmt`
- []: ambiguous method name; affects 2 return(s), 3135 possible param flow(s)
  - src/ast/parser.rb:141 `ClearParser#peek_at`
  - src/mir/fsm_ops.rb:348 `FsmOps::Lowerer#lower_expr`
- lower: ambiguous method name; affects 2 return(s), 51 possible param flow(s)
  - src/mir/lowering/expressions.rb:325 `MIRLoweringExpressions#lower_binary_op`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
- first: unresolved forwarded callee; affects 2 return(s), 31 possible param flow(s)
  - src/lsp/hover.rb:64 `LSP::Hover#find_overlapping`
  - src/mir/lowering/variables.rb:147 `MIRLoweringVariables#lower_var_decl`
- finalize_call_result: callee return still untyped; affects 2 return(s), 0 possible param flow(s)
  - src/mir/lowering/functions.rb:1331 `MIRLoweringFunctions#lower_func_call`
  - src/mir/lowering/functions.rb:1388 `MIRLoweringFunctions#lower_method_call`
- loop: unresolved forwarded callee; affects 2 return(s), 0 possible param flow(s)
  - src/ast/lexer.rb:169 `Lexer#read_interpolated_string`
  - src/lsp/server.rb:51 `LSP::Server#run`
- parse_primary: static candidate `T.noreturn`; affects 2 return(s), 0 possible param flow(s)
  - src/ast/parser.rb:1833 `ClearParser#parse_or_rescue`
  - src/ast/parser.rb:1911 `ClearParser#parse_unary`
- place_value_for_destination: typed signature MIR::Node; affects 2 return(s), 0 possible param flow(s)
  - src/mir/lowering/control_flow.rb:937 `MIRLoweringControlFlow#heap_carry_return_value`
  - src/mir/lowering/variables.rb:558 `MIRLoweringVariables#lower_var_decl_init`
- token: ambiguous method name; affects 1 return(s), 102 possible param flow(s)
  - src/ast/source_error.rb:168 `ErrorHelper#diagnostic_token`
- dup: typed signature FunctionSignature; affects 1 return(s), 90 possible param flow(s)
  - src/ast/parser.rb:3967 `ClearParser#deep_clone_node`
- map: unresolved forwarded callee; affects 1 return(s), 64 possible param flow(s)
  - src/annotator/helpers/intrinsic_registry.rb:170 `IntrinsicRegistry#params_from_arg_spec`
- compact: unresolved forwarded callee; affects 1 return(s), 12 possible param flow(s)
  - src/lsp/diagnostics.rb:42 `LSP::Diagnostics#from_finding`

High-impact root return actions:
- untyped callee each_pair: review as receiver-returning iterator; callers probably want explicit return value; may unblock 7 return(s)
- untyped callee each: review as receiver-returning iterator; callers probably want explicit return value; may unblock 6 return(s)
- untyped callee each_value: review as receiver-returning iterator; callers probably want explicit return value; may unblock 4 return(s)
- untyped callee []: review as nilable lookup or replace with fetch/typed accessor; may unblock 2 return(s)
- untyped callee finalize_call_result: void candidate: return is only forwarded into other returns, never used as a value; may unblock 2 return(s)
- untyped callee try_catch_with_provenance: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee return_with_transfer_marks: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee with_pending: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee finalize_program_semantics!: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee finalize_program_semantics! at src/annotator/annotator.rb:741: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee each at src/annotator/helpers/auto_inference.rb:750: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator/helpers/auto_inference.rb:752: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_pair at src/annotator/helpers/auto_inference.rb:755: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator/helpers/auto_inference.rb:768: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator/helpers/auto_inference.rb:775: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator/helpers/auto_inference.rb:777: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_pair at src/annotator/helpers/auto_inference.rb:780: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator/helpers/auto_inference.rb:905: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator/helpers/auto_inference.rb:907: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_pair at src/annotator/helpers/auto_inference.rb:910: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)

Blocked return examples:
- src/annotator/annotator.rb:689 `SemanticAnnotator#visit`: untyped callee register_type_declaration at src/annotator/annotator.rb:694
- src/annotator/annotator.rb:714 `SemanticAnnotator#visit_Program`: untyped callee finalize_program_semantics! at src/annotator/annotator.rb:741
- src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls`: untyped callee walk_for_shape_decls at src/annotator/helpers/auto_inference.rb:746
- src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk`: untyped callee each at src/annotator/helpers/auto_inference.rb:768
- src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls`: untyped callee walk_for_local_decls at src/annotator/helpers/auto_inference.rb:901
- src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops`: untyped callee walk_binops at src/annotator/helpers/auto_inference.rb:925
- src/annotator/helpers/capabilities.rb:1234 `CapabilityHelper#without_capture_moves`: untyped callee call at src/annotator/helpers/capabilities.rb:1237
- src/annotator/helpers/fixable_helpers.rb:1571 `FixableHelper#emit_auto_resolved_finding!`: untyped callee fixable! at src/annotator/helpers/fixable_helpers.rb:1579
- src/annotator/helpers/fixable_helpers.rb:1597 `FixableHelper#emit_auto_shape_resolved_finding!`: untyped callee fixable! at src/annotator/helpers/fixable_helpers.rb:1604
- src/annotator/helpers/fixable_helpers.rb:1641 `FixableHelper#emit_auto_ambiguity_finding!`: untyped callee fixable! at src/annotator/helpers/fixable_helpers.rb:1661
- src/annotator/helpers/fixable_helpers.rb:1674 `FixableHelper#emit_auto_unresolved_finding!`: untyped callee fixable! at src/annotator/helpers/fixable_helpers.rb:1696
- src/annotator/helpers/intrinsic_registry.rb:117 `IntrinsicRegistry#to_return_def`: no blocker recorded

## Input Param Origin Backflow
- origin: the caller-side expression passed into a parameter slot
- backflow: tracing weak or untyped parameter pressure backward from the callee slot to the caller expression that supplied it
- return-to-param flow: a method return value that is later passed into another method's parameter
- Origins indexed: 81860
- static: 31457
- local: 18342
- unknown: 13502
- untyped_return: 10934
- typed_return: 7625

Return-to-param flows:
- []: 3149 flow(s); src/annotator/annotator.rb:114 -> const(1); src/annotator/annotator.rb:118 -> const(1); src/annotator/annotator.rb:124 -> prop(1); src/annotator/annotator.rb:125 -> prop(1)
- nilable: 2123 flow(s); src/annotator/annotator.rb:102 -> const(1); src/annotator/annotator.rb:131 -> prop(1); src/annotator/annotator.rb:146 -> prop(1); src/annotator/annotator.rb:147 -> prop(1)
- new: 1975 flow(s); src/annotator/annotator.rb:287 -> <<(0); src/annotator/annotator.rb:502 -> <<(0); src/annotator/annotator.rb:544 -> let(0); src/annotator/annotator.rb:545 -> let(0)
- untyped: 1317 flow(s); src/annotator/annotator.rb:688 -> returns(0); src/annotator/annotator.rb:713 -> returns(0); src/annotator/annotator.rb:792 -> let(1); src/annotator/annotator.rb:806 -> let(1)
- name: 509 flow(s); src/annotator/domains/control_flow.rb:180 -> declare(0); src/annotator/domains/control_flow.rb:181 -> local_entry!(0); src/annotator/domains/control_flow.rb:228 -> key?(0); src/annotator/domains/control_flow.rb:232 -> emit_typo_suggestion!(1)
- to_s: 392 flow(s); src/annotator/domains/control_flow.rb:193 -> og_declare(0); src/annotator/domains/control_flow.rb:725 -> record_capture_local!(0); src/annotator/domains/control_flow.rb:771 -> record_capture_local!(0); src/annotator/domains/control_flow.rb:870 -> record_capture_local!(0)
- value: 353 flow(s); src/annotator/domains/control_flow.rb:457 -> visit(0); src/annotator/domains/control_flow.rb:477 -> visit(0); src/annotator/domains/control_flow.rb:522 -> match_variant_name(0); src/annotator/domains/control_flow.rb:574 -> match_variant_name(0)
- any: 263 flow(s); src/annotator/annotator.rb:121 -> [](1); src/annotator/domains/control_flow.rb:327 -> params(schema); src/annotator/domains/control_flow.rb:894 -> params(node); src/annotator/domains/control_flow.rb:894 -> params(body)
- must: 226 flow(s); src/annotator/annotator.rb:507 -> held_locks=(0); src/annotator/annotator.rb:508 -> held_lock_types=(0); src/annotator/domains/control_flow.rb:580 -> declare_match_destructure_fields!(2); src/annotator/domains/control_flow.rb:727 -> classify_ownership!(0)
- body: 215 flow(s); src/annotator/domains/control_flow.rb:427 -> visit_stmts(0); src/annotator/domains/control_flow.rb:703 -> expr_result_type(0); src/annotator/domains/control_flow.rb:728 -> visit_stmts(0); src/annotator/domains/control_flow.rb:736 -> validate_tight_body!(0)
- returns: 199 flow(s); src/annotator/annotator.rb:301 -> params(blk); src/annotator/annotator.rb:322 -> params(blk); src/annotator/annotator.rb:344 -> [](0); src/annotator/annotator.rb:355 -> params(blk)
- cast: 182 flow(s); src/annotator/annotator.rb:276 -> full_type=(0); src/annotator/domains/errors.rb:255 -> <<(0); src/annotator/domains/errors.rb:496 -> new(storage); src/annotator/domains/errors.rb:496 -> new(type)
- length: 177 flow(s); src/annotator/domains/control_flow.rb:337 -> !=(0); src/annotator/domains/control_flow.rb:338 -> error!(expected); src/annotator/domains/control_flow.rb:338 -> error!(got); src/annotator/domains/member_access.rb:286 -> error!(got)
- freeze: 157 flow(s); src/annotator/annotator.rb:792 -> let(0); src/annotator/annotator.rb:806 -> let(0); src/annotator/annotator.rb:812 -> let(0); src/annotator/helpers/capabilities.rb:22 -> let(0)
- resolved: 126 flow(s); src/annotator/annotator.rb:655 -> stamp_map_pairs!(0); src/annotator/annotator.rb:656 -> apply_auto_resolution_stamps!(1); src/annotator/annotator.rb:663 -> emit_auto_shape_resolved_findings!(0); src/annotator/domains/control_flow.rb:392 -> []=(1)
- +: 122 flow(s); src/annotator/domains/member_access.rb:480 -> error!(index); src/annotator/helpers/fixable_helpers.rb:71 -> let(0); src/annotator/helpers/fixable_helpers.rb:92 -> [](0); src/annotator/helpers/fixable_helpers.rb:201 -> anchor_at(1)
- no_ownership: 118 flow(s); src/mir/fiber_ctx_builder.rb:160 -> new(4); src/mir/fiber_ctx_builder.rb:284 -> new(4); src/mir/fiber_ctx_builder.rb:297 -> new(4); src/mir/fiber_ctx_builder.rb:328 -> new(4)
- expr: 115 flow(s); src/annotator/domains/control_flow.rb:158 -> visit(0); src/annotator/domains/control_flow.rb:161 -> error!(0); src/annotator/domains/control_flow.rb:188 -> root_identifier(0); src/annotator/domains/control_flow.rb:190 -> find_container_source(0)
- full_type!: 114 flow(s); src/annotator/domains/control_flow.rb:118 -> stamp_type!(1); src/annotator/domains/control_flow.rb:270 -> stamp_type!(1); src/annotator/domains/control_flow.rb:573 -> stamp_type!(1); src/annotator/domains/execution_boundaries.rb:709 -> stamp_type!(1)
- left: 111 flow(s); src/annotator/domains/errors.rb:573 -> visit(0); src/annotator/domains/expressions.rb:150 -> visit(0); src/annotator/domains/expressions.rb:199 -> visit(0); src/annotator/helpers/auto_inference.rb:924 -> walk_binops(0)

## Foreign Scalar Inputs Into Object-Typed Params
This ranks caller origins where `String`/`Symbol` values flow into params that also receive object instances. It skips `src/tools` origins unless `NIL_KILL_FOREIGN_INCLUDE_TOOLS=1`.
- src/annotator/helpers/auto_inference.rb:215 `def walk(node, current_fn:)`; 639773 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/auto_inference.rb:215 `AutoConstraintCollector#walk` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (639773); trace src/annotator/helpers/auto_inference.rb:215
- src/mir/hoist.rb:230 `def self.each_call_like(node, matches, &blk)`; 443095 foreign scalar call(s), affects 1 slot(s)
  - src/mir/hoist.rb:230 `Hoist#each_call_like` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (443095); trace src/mir/hoist.rb:230
- src/mir/hoist.rb:245 `def self.each_call_like_child(child, matches, &blk)`; 443027 foreign scalar call(s), affects 1 slot(s)
  - src/mir/hoist.rb:245 `Hoist#each_call_like_child` child: String, Symbol into AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock (443027); trace src/mir/hoist.rb:245
- src/mir/hoist.rb:599 `def each_mir_expr_in_value(value, &blk)`; 335686 foreign scalar call(s), affects 1 slot(s)
  - src/mir/hoist.rb:599 `MIRHoistLowering#each_mir_expr_in_value` value: String, Symbol into AST::BinaryOp, Array, FunctionSignature, Hash, MIR::AddressOf (335686); trace src/mir/hoist.rb:599
- src/mir/hoist.rb:611 `def mir_expr_child?(value)`; 335686 foreign scalar call(s), affects 1 slot(s)
  - src/mir/hoist.rb:611 `MIRHoistLowering#mir_expr_child?` value: String, Symbol into AST::BinaryOp, Array, FunctionSignature, Hash, MIR::AddressOf (335686); trace src/mir/hoist.rb:611
- src/mir/pre_mir_type_check.rb:70 `def self.walk(node, violations, seen)`; 290465 foreign scalar call(s), affects 1 slot(s)
  - src/mir/pre_mir_type_check.rb:70 `PreMirTypeCheck#walk` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (290465); trace src/mir/pre_mir_type_check.rb:70
- src/annotator/helpers/intrinsic_arg_spec.rb:20 `def self.from_registry(raw)`; 122098 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:20 `IntrinsicArgSpec#from_registry` raw: Symbol into Hash (122098); trace src/annotator/helpers/intrinsic_arg_spec.rb:20
- src/ast/type.rb:1429 `def ==(other)`; 79340 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:1429 Type#== other: Symbol into Type (79340); trace src/ast/type.rb:1429
- src/annotator/helpers/intrinsic_registry.rb:117 `def self.to_return_def(v)`; 55373 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_registry.rb:117 `IntrinsicRegistry#to_return_def` v: String, Symbol into Hash, Proc, Type (55373); trace src/annotator/helpers/intrinsic_registry.rb:117
- src/ast/type.rb:3665 `def is_safe_autocast?(source_type, target_type)`; 13969 foreign scalar call(s), affects 2 slot(s)
  - src/ast/type.rb:3665 `TypeHelper#is_safe_autocast?` source_type: Symbol into Type (8487); trace src/ast/type.rb:3665
  - src/ast/type.rb:3665 `TypeHelper#is_safe_autocast?` target_type: Symbol into Type (5482); trace src/ast/type.rb:3665
- src/ast/type.rb:3660 `def to_type(input)`; 13969 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:3660 `TypeHelper#to_type` input: Symbol into Type (13969); trace src/ast/type.rb:3660
- src/ast/type.rb:3673 `def check_prefixed_int_range!(node, effective_type)`; 13422 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:3673 `TypeHelper#check_prefixed_int_range!` effective_type: Symbol into FunctionSignature, Type (13422); trace src/ast/type.rb:3673
- src/mir/alloc.rb:29 `def finalize_decl_storage!(node, final_type)`; 10884 foreign scalar call(s), affects 1 slot(s)
  - src/mir/alloc.rb:29 `AllocHelper#finalize_decl_storage!` final_type: Symbol into Type (10884); trace src/mir/alloc.rb:29
- src/backends/zig_type_mapper.rb:39 `def transpile_type(type, is_param: false, is_field: false)`; 3180 foreign scalar call(s), affects 1 slot(s)
  - src/backends/zig_type_mapper.rb:39 `ZigTypeMapper#transpile_type` type: String, Symbol into Type (3180); trace src/backends/zig_type_mapper.rb:39
- src/annotator/helpers/intrinsic_registry.rb:162 `def self.normalize_lifetime(value)`; 3004 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_registry.rb:162 `IntrinsicRegistry#normalize_lifetime` value: String, Symbol into Array (3004); trace src/annotator/helpers/intrinsic_registry.rb:162
- src/annotator/helpers/function_signature.rb:315 `def self.intrinsic_contract(return_type: Type.new(:Void), allocates: false, borrows: nil,`; 2299 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/function_signature.rb:315 `FunctionSignature#intrinsic_contract` borrows: Symbol into Array (2299); trace src/annotator/helpers/function_signature.rb:315
- src/mir/fsm_transform/liveness.rb:257 `def self.walk_idents(node, &block)`; 2061 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_transform/liveness.rb:257 `FsmTransform::Liveness#walk_idents` node: String, Symbol into AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr (2061); trace src/mir/fsm_transform/liveness.rb:257
- src/annotator/helpers/intrinsic_arg_spec.rb:37 `def self.list_from_registry(raw)`; 2000 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_arg_spec.rb:37 `IntrinsicArgSpec#list_from_registry` raw: Symbol into Array (2000); trace src/annotator/helpers/intrinsic_arg_spec.rb:37
- src/ast/type.rb:3706 `def integer_range_target_type(effective_type)`; 1500 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:3706 `TypeHelper#integer_range_target_type` effective_type: Symbol into Type (1500); trace src/ast/type.rb:3706
- src/annotator/helpers/function_signature.rb:377 `def initialize(params:, return_type: nil, return_lifetime: nil, visibility: nil,`; 1000 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/function_signature.rb:377 `FunctionSignature#initialize` arg_spec: Symbol into Array (1000); trace src/annotator/helpers/function_signature.rb:377
- src/annotator/helpers/intrinsic_registry.rb:170 `def self.params_from_arg_spec(spec, h)`; 1000 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_registry.rb:170 `IntrinsicRegistry#params_from_arg_spec` spec: Symbol into Array (1000); trace src/annotator/helpers/intrinsic_registry.rb:170
- src/ast/ast.rb:745 `def self._expr_each_bg_block_recursive(expr, &block)`; 673 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:745 `AST#_expr_each_bg_block_recursive` expr: Symbol into AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock (673); trace src/ast/ast.rb:745
- src/annotator/helpers/auto_inference.rb:741 `def walk_for_shape_decls(node, &block)`; 584 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/auto_inference.rb:741 `ShapeEvidenceCollector#walk_for_shape_decls` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (584); trace src/annotator/helpers/auto_inference.rb:741
- src/annotator/helpers/auto_inference.rb:896 `def walk_for_local_decls(node, &block)`; 532 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/auto_inference.rb:896 `OperatorEvidenceCollector#walk_for_local_decls` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (532); trace src/annotator/helpers/auto_inference.rb:896
- src/ast/symbol_entry.rb:471 `def initialize(reg:, type:, mutable:, storage:, sync: nil, layout: nil, rebindable: false,`; 481 foreign scalar call(s), affects 1 slot(s)
  - src/ast/symbol_entry.rb:471 `SymbolEntry#initialize` reg: String, Symbol into AST::BindExpr, AST::Identifier, AST::LetBinding, AST::StubDecl, AST::VarDecl (481); trace src/ast/symbol_entry.rb:471
- src/annotator/helpers/auto_inference.rb:919 `def walk_binops(node, name_to_slot, fn)`; 480 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/auto_inference.rb:919 `OperatorEvidenceCollector#walk_binops` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (480); trace src/annotator/helpers/auto_inference.rb:919
- src/ast/ast.rb:1014 `def coerced_type=(val)`; 334 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:1014 `AST::Locatable#coerced_type=` val: Symbol into Type (334); trace src/ast/ast.rb:1014
- src/mir/test_lowering.rb:299 `def collect_identifier_refs(node, name_set, out)`; 292 foreign scalar call(s), affects 1 slot(s)
  - src/mir/test_lowering.rb:299 `TestLowering#collect_identifier_refs` node: String, Symbol into AST::Assert, AST::BinaryOp, AST::Identifier, AST::Literal, Array (292); trace src/mir/test_lowering.rb:299
- src/annotator/helpers/auto_inference.rb:762 `def walk(node, name_map)`; 291 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/auto_inference.rb:762 `ShapeEvidenceCollector#walk` node: String, Symbol into AST::Assignment, AST::BindExpr, AST::HashLit, AST::Identifier, AST::ListLit (291); trace src/annotator/helpers/auto_inference.rb:762
- src/ast/ast.rb:792 `def self._expr_each_bg_block_shallow(expr, &block)`; 218 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:792 `AST#_expr_each_bg_block_shallow` expr: Symbol into AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock (218); trace src/ast/ast.rb:792
- src/mir/lowering/capabilities.rb:773 `def ast_contains_return?(node)`; 190 foreign scalar call(s), affects 1 slot(s)
  - src/mir/lowering/capabilities.rb:773 `MIRLoweringCapabilities#ast_contains_return?` node: String, Symbol into AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::Capability, AST::FunctionDef (190); trace src/mir/lowering/capabilities.rb:773
- src/annotator/helpers/function_analysis.rb:89 `def analyze_routine(node, body, declared_return, is_implicit)`; 67 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/function_analysis.rb:89 `FunctionAnalysis#analyze_routine` declared_return: Symbol into Type (67); trace src/annotator/helpers/function_analysis.rb:89
- src/mir/fsm_ops.rb:487 `def self.walk(node, &block)`; 35 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_ops.rb:487 `FsmOps#walk` node: String, Symbol into Array, FsmOps::AddrOf, FsmOps::AllocExpr, FsmOps::ArgRef, FsmOps::AssignField (35); trace src/mir/fsm_ops.rb:487
- src/semantic/escape_analysis.rb:579 `private_class_method def self.unwrap_value(node)`; 5 foreign scalar call(s), affects 1 slot(s)
  - src/semantic/escape_analysis.rb:579 `EscapeAnalysis#unwrap_value` node: String into AST::Assignment, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BindExpr (5); trace src/semantic/escape_analysis.rb:579
- src/annotator/helpers/fixable_helpers.rb:1228 `def build_cast_wrap_fix(value, target_type)`; 5 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/fixable_helpers.rb:1228 `FixableHelper#build_cast_wrap_fix` target_type: Symbol into Type (5); trace src/annotator/helpers/fixable_helpers.rb:1228
- src/mir/fsm_transform/segments.rb:125 `def initialize(with_node, cap, prior_caps, post_acquire_idx, next_index, lock_index = nil, prior_lock_indices = [])`; 3 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_transform/segments.rb:125 `FsmTransform::Segments#initialize` cap: Symbol into CapabilityPlan::CapabilityTransition, Hash (3); trace src/mir/fsm_transform/segments.rb:125
- src/annotator/helpers/fixable_helpers.rb:1174 `def emit_type_mismatch_assign_error!(node, target_type, value_type)`; 2 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/fixable_helpers.rb:1174 `FixableHelper#emit_type_mismatch_assign_error!` target_type: Symbol into Type (2); trace src/annotator/helpers/fixable_helpers.rb:1174
- src/mir/lowering/expressions.rb:2221 `def generic_type_arg_zig(type)`; 2 foreign scalar call(s), affects 1 slot(s)
  - src/mir/lowering/expressions.rb:2221 `MIRLoweringExpressions#generic_type_arg_zig` type: Symbol into Type (2); trace src/mir/lowering/expressions.rb:2221
- src/lsp/document_store.rb:30 `def cached_findings=(value);  @cached_findings = value; end`; 2 foreign scalar call(s), affects 1 slot(s)
  - src/lsp/document_store.rb:30 `LSP::DocumentStore#cached_findings=` value: String, Symbol into LSP::AnalysisResult (2); trace src/lsp/document_store.rb:30
- src/annotator/helpers/capabilities.rb:41 `def self.validate!(node, type, &error_handler)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/capabilities.rb:41 `Capabilities#validate!` node: Symbol into AST::BindExpr, AST::VarDecl (1); trace src/annotator/helpers/capabilities.rb:41
- src/annotator/helpers/function_signature.rb:280 `def self.unwrap(x)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/function_signature.rb:280 `FunctionSignature#unwrap` x: Symbol into Array, FunctionSignature, Type (1); trace src/annotator/helpers/function_signature.rb:280
- src/annotator/helpers/intrinsic_registry.rb:45 `def self.build_emit(h, registries)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_registry.rb:45 `IntrinsicRegistry#build_emit` h: Symbol into Hash (1); trace src/annotator/helpers/intrinsic_registry.rb:45
- src/annotator/helpers/intrinsic_registry.rb:221 `def self.fs(x, name = "_inline")`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/annotator/helpers/intrinsic_registry.rb:221 `IntrinsicRegistry#fs` x: Symbol into FunctionSignature, Hash (1); trace src/annotator/helpers/intrinsic_registry.rb:221
- src/backends/mir_emitter.rb:55 `def emit(node)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/backends/mir_emitter.rb:55 `MIREmitter#emit` node: String into MIR::AddressOf, MIR::AllocMark, MIR::AllocSlice, MIR::AllocatorRef, MIR::ArrayDefaultInit (1); trace src/backends/mir_emitter.rb:55
- src/mir/lowering/concurrency.rb:978 `def fsm_bg_block_from_transform!(node, transform_result, captured, analysis)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/mir/lowering/concurrency.rb:978 `MIRLoweringConcurrency#fsm_bg_block_from_transform!` transform_result: String into MIR::FsmLoweringResult (1); trace src/mir/lowering/concurrency.rb:978
- src/backends/fsm_wrapper_emitter.rb:45 `def self.render(body)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/backends/fsm_wrapper_emitter.rb:45 `FsmWrapperEmitter#render` body: String into MIR::FsmB1Body, MIR::FsmGenericBody, MIR::FsmIoBody (1); trace src/backends/fsm_wrapper_emitter.rb:45
- src/mir/fsm_transform/segments.rb:219 `def self.split_while_loop_next(body)`; 1 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_transform/segments.rb:219 `FsmTransform::Segments#split_while_loop_next` body: String into Array (1); trace src/mir/fsm_transform/segments.rb:219

## Type Normalizer Sites
- Sites matching `is_a?(Type)` plus `Type.new(...)`: 127
- src/ast/type.rb: 12
  - line 346 `TypeShape#resolved`: item.is_a?(Type)
  - line 460 `Type#indirect_type?`: value.is_a?(Type)
  - line 467 `Type#surface_name`: type.is_a?(Type)
  - line 585 `Type#coerce_error`: target_type.is_a?(Type)
  - line 789 `Type#initialize`: raw_input.is_a?(Type)
  - ... 7 more
- src/annotator/domains/lifetimes.rb: 10
  - line 69 `Annotator::Domains::Lifetimes#ensure_owned_value!`: vti.is_a?(Type)
  - line 76 `Annotator::Domains::Lifetimes#ensure_owned_value!`: expected_type.is_a?(Type)
  - line 80 `Annotator::Domains::Lifetimes#ensure_owned_value!`: expected_type.is_a?(Type)
  - line 122 `Annotator::Domains::Lifetimes#visit_CopyNode`: inner_type.is_a?(Type)
  - line 129 `Annotator::Domains::Lifetimes#visit_CopyNode`: ti.is_a?(Type)
  - ... 5 more
- src/annotator/helpers/auto_inference.rb: 9
  - line 580 `AutoUnifier#collect_observed_types`: t.is_a?(Type)
  - line 590 `AutoUnifier#widen_byte_array_to_string`: t.is_a?(Type)
  - line 601 `AutoUnifier#types_equal?`: a.is_a?(Type)
  - line 601 `AutoUnifier#types_equal?`: b.is_a?(Type)
  - line 602 `AutoUnifier#types_equal?`: a.is_a?(Type)
  - ... 4 more
- src/mir/lowering/functions.rb: 8
  - line 294 `MIRLoweringFunctions#lower_function_def`: ret_type.is_a?(Type)
  - line 1234 `MIRLoweringFunctions#lower_call_arg_from_facts`: facts.callee_param_type.is_a?(Type)
  - line 1317 `MIRLoweringFunctions#wants_ptr?`: ti.is_a?(Type)
  - line 1461 `MIRLoweringFunctions#call_owned_return?`: raw_ti.is_a?(Type)
  - line 1938 `MIRLoweringFunctions#build_extern_trampoline_call`: pt.is_a?(Type)
  - ... 3 more
- src/annotator/domains/control_flow.rb: 7
  - line 258 `Annotator::Domains::ControlFlow#annotate_struct_pattern!`: ft.is_a?(Type)
  - line 295 `Annotator::Domains::ControlFlow#normalized_match_payload`: payload.is_a?(Type)
  - line 551 `Annotator::Domains::ControlFlow#match_payload_binding_type`: raw_payload.is_a?(Type)
  - line 594 `Annotator::Domains::ControlFlow#match_payload_struct_schema`: raw_payload.is_a?(Type)
  - line 753 `Annotator::Domains::ControlFlow#visit_ForEach`: coll_type.is_a?(Type)
  - ... 2 more
- src/annotator/helpers/pipe_analysis.rb: 6
  - line 773 `PipeAnalysis#analyze_pipe_to_identifier`: sig.is_a?(Type)
  - line 819 `PipeAnalysis#analyze_pipe_to_named_function`: result_type.is_a?(Type)
  - line 1159 `PipeAnalysis#emit_multi_map_warning`: sc.is_a?(Type)
  - line 1234 `PipeAnalysis#auto_detect_sharded_access`: map_type.is_a?(Type)
  - line 1300 `PipeAnalysis#sharded_unsynced_entry?`: type.is_a?(Type)
  - ... 1 more
- src/mir/lowering/expressions.rb: 6
  - line 1505 `MIRLoweringExpressions#lower_struct_lit`: field_type_input.is_a?(Type)
  - line 1594 `MIRLoweringExpressions#lower_union_variant_lit`: ft.is_a?(Type)
  - line 1994 `MIRLoweringExpressions#lower_copy`: sink_type.is_a?(Type)
  - line 2039 `MIRLoweringExpressions#copy_source_type_info`: sym_type.is_a?(Type)
  - line 2108 `MIRLoweringExpressions#lower_share`: source_ti.is_a?(Type)
  - ... 1 more
- src/mir/fiber_ctx_builder.rb: 5
  - line 323 `FiberCtxBuilder#build`: _type_obj.is_a?(Type)
  - line 352 `FiberCtxBuilder#build`: _type_obj.is_a?(Type)
  - line 418 `FiberCtxBuilder#needs_move_capture_cleanup?`: type_obj.is_a?(Type)
  - line 427 `FiberCtxBuilder#needs_fresh_heap_capture_cleanup?`: type_obj.is_a?(Type)
  - line 438 `FiberCtxBuilder#needs_capture_value_cleanup?`: type_obj.is_a?(Type)
- src/annotator/helpers/capabilities.rb: 4
  - line 207 `CapabilityHelper#validate_capability_transition!`: var_type.is_a?(Type)
  - line 219 `CapabilityHelper#validate_capability_transition!`: var_type.is_a?(Type)
  - line 839 `CapabilityHelper#acquire_capability!`: base_t.is_a?(Type)
  - line 1357 `CapabilityAudit#record_capability_binding`: final_type.is_a?(Type)
- src/annotator/helpers/function_analysis.rb: 4
  - line 852 `FunctionAnalysis#atomic_cell_to_atomic_param?`: ptype.is_a?(Type)
  - line 986 `FunctionAnalysis#verify_lifetime_source!`: param_type.is_a?(Type)
  - line 1301 `FunctionAnalysis#reject_arg_type_matches?`: type.is_a?(Type)
  - line 1342 `FunctionAnalysis#any_array_intrinsic_arg?`: type.is_a?(Type)
- src/annotator/helpers/generic_analysis.rb: 4
  - line 371 `GenericAnalysis#apply_type_subst`: type_obj.is_a?(Type)
  - line 435 `GenericAnalysis#same_generic_binding?`: left.is_a?(Type)
  - line 436 `GenericAnalysis#same_generic_binding?`: right.is_a?(Type)
  - line 524 `GenericAnalysis#propagate_declared_type_to_value!`: final_type.is_a?(Type)
- src/mir/mir_lowering.rb: 4
  - line 594 `MIRLowering#destination_type`: ti.is_a?(Type)
  - line 2730 `MIRLowering#mir_cast`: from_type.is_a?(Type)
  - line 2731 `MIRLowering#mir_cast`: to_type.is_a?(Type)
  - line 3643 `MIRLowering#owned_sink_plan`: sink_type.is_a?(Type)
- src/semantic/escape_analysis.rb: 4
  - line 354 `EscapeAnalysis#param_sync_was_declared?`: t.is_a?(Type)
  - line 360 `EscapeAnalysis#param_accepts_caller_sync?`: t.is_a?(Type)
  - line 445 `EscapeAnalysis#mark_param_receiver_allocations_heap!`: ti.is_a?(Type)
  - line 520 `EscapeAnalysis#mark_receiver_allocations_in_loop!`: ti.is_a?(Type)
- src/annotator/domains/errors.rb: 3
  - line 440 `Annotator::Domains::Errors#visit_ReturnNode`: vti.is_a?(Type)
  - line 585 `Annotator::Domains::Errors#visit_OrRescue`: eu.is_a?(Type)
  - line 687 `Annotator::Domains::Errors#coerce_empty_collection_fallback!`: expected.is_a?(Type)
- src/annotator/domains/variables.rb: 3
  - line 140 `Annotator::Domains::Variables#finalize_decl_node!`: final_type.is_a?(Type)
  - line 433 `Annotator::Domains::Variables#visit_Identifier`: raw_type.is_a?(Type)
  - line 505 `Annotator::Domains::Variables#track_union_alias`: ret_type.is_a?(Type)
- src/annotator/helpers/effects.rb: 3
  - line 434 `EffectTracker#function_needs_runtime_directly?`: ret_type.is_a?(Type)
  - line 520 `EffectTracker#compute_can_fail!`: rt.is_a?(Type)
  - line 1043 `EffectTracker#assign_base_stack_tiers!`: return_t.is_a?(Type)
- src/ast/ast.rb: 3
  - line 989 `AST::Locatable#full_type=`: val.is_a?(Type)
  - line 1018 `AST::Locatable#coerced_type=`: val.is_a?(Type)
  - line 1075 `AST::Locatable#finalize_storage!`: final_type.is_a?(Type)
- src/mir/lowering/control_flow.rb: 3
  - line 321 `MIRLoweringControlFlow#for_each_plan`: coll_type.is_a?(Type)
  - line 707 `MIRLoweringControlFlow#match_lowering_facts`: expr_type.is_a?(Type)
  - line 710 `MIRLoweringControlFlow#match_lowering_facts`: expr_type.is_a?(Type)
- src/annotator/domains/expressions.rb: 2
  - line 27 `Annotator::Domains::Expressions#collect_implicit_type_params`: type.is_a?(Type)
  - line 176 `Annotator::Domains::Expressions#visit_BinaryOp`: ti.is_a?(Type)
- src/annotator/helpers/fixable_helpers.rb: 2
  - line 312 `FixableHelper#emit_use_of_moved_error!`: pt.is_a?(Type)
  - line 1729 `FixableHelper#auto_type_source_form`: type.is_a?(Type)

## Fallibility Pressure (422)
- pressure: direct failure roots ranked by static raises, runtime raises, unhandled caller fan-out, and rescue/fallback handler participation
- handler participation is shared attribution: a root participates in a rescue if a protected project call can reach it; shared handlers may have other causes too
- display threshold: score >= 10, or any handler/runtime raise pressure; hidden low-tail roots: 3
- :0 (top-level)#: score 23129; direct sources 0; runtime raises 23129/13879869 (0.2%; raised ArgumentError, CircularDependencyError, ClearBuildSupport::FileMissingError, ClearBuildSupport::PackageMissingError); handlers 0 (exclusive 0, shared 0); unhandled callers 0
- src/ast/type.rb:217 `TypeShape.from_core`: score 4003; direct sources 5; runtime raises 0/0 (0.0%); handlers 41 (exclusive 12, shared 29); unhandled callers 1917
  - source: src/ast/type.rb:222 raise `raise "Invalid type '#{core_str}': double tense (~~) is not allowed — ~T is already a promise"`
  - source: src/ast/type.rb:235 raise `raise "Invalid type '#{core_str}': double error union (!!) is not allowed"`
  - source: src/ast/type.rb:236 raise `raise "Invalid type '#{core_str}': !~T (error union of tense) is not allowed — use ~!T instead"`
  - ... 2 more source(s)
  - handler: src/annotator/domains/lifetimes.rb:353 `Annotator::Domains::Lifetimes#reject_scoped_assignment_move!` exclusive; protected `Type#requires_move?`; roots `TypeShape.from_core`
  - handler: src/annotator/helpers/effects.rb:596 `EffectTracker#compute_can_fail!` exclusive; protected `FunctionSignature#return_type` | `Type#collection?` | `Type#needs_escape_promotion?` | `Type#string?`; roots `TypeShape.from_core`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 38 more handler(s)
  - unhandled callers: `AST#annotation_return_type` | `AST#coerce!` | `AST#full_type` | `AST#initialize` | `AST#lowering_return_type` | ...
- src/ast/ast.rb:1000 `AST::Locatable#full_type!`: score 1723; direct sources 1; runtime raises 0/0 (0.0%); handlers 18 (exclusive 0, shared 18); unhandled callers 825
  - source: src/ast/ast.rb:1002 raise `raise "#{context}: unresolved type info for #{self.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/control_flow.rb:1256 `OwnershipDataflow#owning_field_move?` shared; protected `AST::Locatable#full_type!` | `Type.indirect_type?`; roots `AST::Locatable#full_type!` | `TypeShape.from_core`
  - ... 15 more handler(s)
  - unhandled callers: `AST._bg_visit_recursive` | `AST._expr_each_bg_block_recursive` | `AST.copy_pipeline_rewrite_metadata!` | `AST.each_bg_block` | `AST.each_capture_analysis` | ...
- src/ast/type.rb:3104 `Type.from_node!`: score 1348; direct sources 2; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 647
  - source: src/ast/type.rb:3106 raise `raise "#{context}: missing type info for #{node.class}"`
  - source: src/ast/type.rb:3107 raise `raise "#{context}: unresolved type info for #{node.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/lowering/control_flow.rb:1078 `MIRLoweringControlFlow#return_value_already_payload_pointer?` shared; protected `MIRLowering#current_function_return_payload_zig` | `Type#zig_type` | `Type.from_node!`; roots `Type#observable_wrapper_zig` | `Type.from_node!` | `TypeShape.from_core`
  - ... 10 more handler(s)
  - unhandled callers: `AST._bg_visit_recursive` | `AST._expr_each_bg_block_recursive` | `AST.each_bg_block` | `AST.each_capture_analysis` | `AST.each_child_node` | ...
- src/mir/mir.rb:1543 `MIR.validate_defer_body!`: score 1285; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 616
  - source: src/mir/mir.rb:1551 raise `raise TypeError, "#{label} body must be structural MIR, got #{body.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST._bg_visit_recursive` | `AST._expr_each_bg_block_recursive` | `AST.each_bg_block` | `AST.each_capture_analysis` | `AST.each_locatable` | ...
- src/ast/type.rb:2506 `Type#observable_wrapper_zig`: score 1248; direct sources 2; runtime raises 0/0 (0.0%); handlers 20 (exclusive 0, shared 20); unhandled callers 583
  - source: src/ast/type.rb:2515 raise `raise CompilerError.new(`
  - source: src/ast/type.rb:2528 raise `raise CompilerError.new(`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/cleanup_classifier.rb:582 `CleanupClassifier.takes_param_base_entry` shared; protected `Type#zig_type`; roots `Type#observable_wrapper_zig` | `TypeShape.from_core`
  - ... 17 more handler(s)
  - unhandled callers: `AST._bg_visit_recursive` | `AST._expr_each_bg_block_recursive` | `AST._expr_each_concurrent_capture` | `AST.each_bg_block` | `AST.each_capture_analysis` | ...
- src/ast/source_error.rb:31 `ErrorHelper#error!`: score 1070; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 510
  - source: src/ast/source_error.rb:39 raise `raise "Internal Compiler Error: Unknown error code :#{code_or_message}"`
  - source: src/ast/source_error.rb:53 raise `raise err_class.new(token, message, T.cast(T.unsafe(self).instance_variable_get(:@source_code), T.nilable(String)))`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/ast/diagnostic_registry.rb:3001 `DiagnosticRegistry.fix_description_from_hash`: score 869; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 410
  - source: src/ast/diagnostic_registry.rb:3003 raise `Kernel.raise "Internal Compiler Error: Unknown fix description code :#{code}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/ast/fixable_error.rb:74 `Fix#initialize`: score 868; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 409
  - source: src/ast/fixable_error.rb:76 raise `raise ArgumentError, "Fix.confidence must be one of #{CONFIDENCES}, got #{confidence.inspect}"`
  - source: src/ast/fixable_error.rb:81 raise `raise ArgumentError, "Fix needs at least one edit"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/ast/fixable_error.rb:99 `FixableFinding#initialize`: score 844; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 397
  - source: src/ast/fixable_error.rb:100 raise `raise ArgumentError, "bad level #{level.inspect}"`
  - source: src/ast/fixable_error.rb:101 raise `raise ArgumentError, "bad category #{category.inspect}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/mir/mir_checker.rb:2786 `MIRChecker#error`: score 837; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 394
  - source: src/mir/mir_checker.rb:2788 raise `raise "Internal Compiler Error: unregistered MIR diagnostic code :#{kind}. " \`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/source_error.rb:76 `ErrorHelper#diagnostic_message`: score 827; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 389
  - source: src/ast/source_error.rb:78 raise `Kernel.raise "Internal Compiler Error: Unknown error code :#{code}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/ast/source_error.rb:141 `ErrorHelper#fixable!`: score 826; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 388
  - source: src/ast/source_error.rb:154 raise `raise err_class.new(token, rendered_message, T.cast(T.unsafe(self).instance_variable_get(:@source_code), T.nilable(String)))`
  - source: src/ast/source_error.rb:164 raise `raise err_class.new(token, rendered_message, T.cast(T.unsafe(self).instance_variable_get(:@source_code), T.nilable(String)))`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/ast/symbol_entry.rb:520 `SymbolEntry#normalize_lifetime`: score 797; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 374
  - source: src/ast/symbol_entry.rb:531 raise `raise TypeError, "SymbolEntry#lifetime sources must be SymbolEntry instances"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `AST::Locatable#matched_stdlib_def=` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | ...
- src/semantic/capability_plan.rb:362 `CapabilityPlan.require_for`: score 773; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 360
  - source: src/semantic/capability_plan.rb:364 raise `raise "Internal: WITH block reached consumer without a CapabilityPlan"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/mir/hoist.rb:646 `MIRHoistLowering#mir_alloc_mark_type_info`: score 770; direct sources 8; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 357
  - source: src/mir/hoist.rb:677 raise `raise "#{context}: allocating #{mir.class} has no callable return type"`
  - source: src/mir/hoist.rb:679 raise `raise "#{context}: allocating #{mir.class} has no typed stdlib return"`
  - source: src/mir/hoist.rb:681 raise `raise "#{context}: allocating MIR::BgBlock has no result type"`
  - ... 5 more source(s)
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/hoist.rb:1264 `MIRHoistLowering#cleanup_entry_for_ownership_effect`: score 743; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 347
  - source: src/mir/hoist.rb:1291 raise `raise "uniform owned MIR #{mir.class} has no typed cleanup result"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/hoist.rb:1174 `MIRHoistLowering#hoist_cleanup_entry`: score 742; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 346
  - source: src/mir/hoist.rb:1190 raise `raise "hoist_cleanup_entry: unexpected DeepCopy strategy :#{mir.strategy}"`
  - source: src/mir/hoist.rb:1214 raise `raise "hoist_cleanup_entry: unhandled allocating MIR node #{mir.class} -- " \`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/annotator/helpers/intrinsic_registry.rb:45 `IntrinsicRegistry.build_emit`: score 675; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 313
  - source: src/annotator/helpers/intrinsic_registry.rb:63 raise `Kernel.raise "IntrinsicRegistry: unmapped registry key #{k.inspect}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `AST::Locatable#matched_stdlib_def=` | `Annotator::Domains::Expressions#visit_Placeholder` | ...
- src/annotator/helpers/intrinsic_registry.rb:90 `IntrinsicRegistry.to_return_type`: score 675; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 313
  - source: src/annotator/helpers/intrinsic_registry.rb:93 raise `Kernel.raise "IntrinsicRegistry: fixed return descriptor missing Type"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `AST::Locatable#matched_stdlib_def=` | `Annotator::Domains::Expressions#visit_Placeholder` | ...
- src/annotator/helpers/intrinsic_registry.rb:117 `IntrinsicRegistry.to_return_def`: score 675; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 313
  - source: src/annotator/helpers/intrinsic_registry.rb:127 raise `Kernel.raise "IntrinsicRegistry: Proc return descriptor is not allowed; " \`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `AST::Locatable#matched_stdlib_def=` | `Annotator::Domains::Expressions#visit_Placeholder` | ...
- src/ast/ast.rb:57 `AST.stamp_synthetic_type!`: score 603; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 277
  - source: src/ast/ast.rb:60 raise `raise "#{context}: synthetic type stamp produced :Untyped for #{node.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/annotator/helpers/fixable_helpers.rb:149 `FixableHelper#emit_typo_suggestion!`: score 558; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 254
  - source: src/annotator/helpers/fixable_helpers.rb:165 error! `error!(token, :TYPO_SUGGESTION_REJECTED, detail: message)`
  - source: src/annotator/helpers/fixable_helpers.rb:167 fixable_error `fixable!(token, code: :TYPO_SUGGESTION_REJECTED, detail: message,`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | ...
- src/mir/mir_lowering.rb:3395 `MIRLowering#emit_builtin`: score 557; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 254
  - source: src/mir/mir_lowering.rb:3397 raise `raise "emit_builtin: unknown builtin :#{name}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:633 `ClearParser#emit_syntax_insert_end_of_line!`: score 517; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 234
  - source: src/ast/parser.rb:647 fixable_error `fixable!(next_tok,`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:661 `ClearParser#emit_syntax_insert_before_token!`: score 517; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 234
  - source: src/ast/parser.rb:670 fixable_error `fixable!(token,`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:614 `ClearParser#emit_consume_error_with_fix`: score 515; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 233
  - source: src/ast/parser.rb:626 error! `error!(token, :PARSER_EXPECTED, expected: expected_value || expected_type, got: token.value, type: token.type, line: token.line)`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/mir_lowering.rb:106 `MIRLowering::DestinationPlacementPlan#place`: score 501; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 226
  - source: src/mir/mir_lowering.rb:129 raise `raise "unknown destination placement action #{action.inspect}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/annotator/annotator.rb:271 `SemanticAnnotator#stamp_type!`: score 448; direct sources 2; runtime raises 0/0 (0.0%); handlers 11 (exclusive 0, shared 11); unhandled callers 201
  - source: src/annotator/annotator.rb:274 raise `raise "annotation stamp missing type for #{node.class}"`
  - source: src/annotator/annotator.rb:278 raise `raise "annotation stamp produced :Untyped for #{node.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 8 more handler(s)
  - unhandled callers: `AST.each_locatable` | `Annotator::Domains::ControlFlow#analyze_control_flow_branch` | `Annotator::Domains::ControlFlow#analyze_control_flow_branches` | `Annotator::Domains::ControlFlow#analyze_match_case!` | `Annotator::Domains::ControlFlow#analyze_value_match_case!` | ...
- src/ast/parser.rb:569 `ClearParser#consume_number`: score 423; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 187
  - source: src/ast/parser.rb:575 error! `error!(current, :EXPECTED_NUMBER, value: current.value, type: current.type)`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:487 `FsmTransform::RecursiveSplitter.emit_with_fragment`: score 408; direct sources 4; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 176
  - source: src/mir/fsm_transform/recursive_splitter.rb:490 raise `raise UnsupportedShape, "WITH with no capabilities"`
  - source: src/mir/fsm_transform/recursive_splitter.rb:493 raise `raise UnsupportedShape, "WITH split without ctx"`
  - source: src/mir/fsm_transform/recursive_splitter.rb:498 raise `raise UnsupportedShape, "WITH split without runtime"`
  - ... 1 more source(s)
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_ops.rb:128 `FsmOps::FunctionPath#render`: score 407; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 179
  - source: src/mir/fsm_ops.rb:135 raise `raise ArgumentError, "unknown FSM function path root #{root.inspect}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1368 `PipelineConcurrentLowerer#callback_expression`: score 407; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 179
  - source: src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1374 raise `raise "concurrent callback expression expected expression op, got #{op.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:3134 `ClearParser#apply_capability!`: score 406; direct sources 8; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 175
  - source: src/ast/parser.rb:3137 error! `error!(token, :DUPLICATE_OWNERSHIP_CAP)`
  - source: src/ast/parser.rb:3144 error! `error!(token, :DUPLICATE_SYNC_CAP)`
  - source: src/ast/parser.rb:3151 error! `error!(token, :DUPLICATE_COLLECTION_CAP)`
  - ... 5 more source(s)
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:421 `FsmTransform::RecursiveSplitter.emit_suspend`: score 405; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 176
  - source: src/mir/fsm_transform/recursive_splitter.rb:424 raise `raise UnsupportedShape, "Unhandled suspend kind #{susp_tail.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:432 `FsmTransform::RecursiveSplitter.emit_while_fragment`: score 405; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 176
  - source: src/mir/fsm_transform/recursive_splitter.rb:435 raise `raise UnsupportedShape, "WhileLoop recursive FSM lowering requires structural MIR conditions"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:439 `FsmTransform::RecursiveSplitter.emit_for_range_fragment`: score 405; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 176
  - source: src/mir/fsm_transform/recursive_splitter.rb:442 raise `raise UnsupportedShape, "ForRange recursive FSM lowering requires structural MIR loop state"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:446 `FsmTransform::RecursiveSplitter.emit_for_each_fragment`: score 405; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 176
  - source: src/mir/fsm_transform/recursive_splitter.rb:449 raise `raise UnsupportedShape, "ForEach recursive FSM lowering requires structural MIR iterator state"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:454 `FsmTransform::RecursiveSplitter.emit_if_fragment`: score 405; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 176
  - source: src/mir/fsm_transform/recursive_splitter.rb:457 raise `raise UnsupportedShape, "IfStatement recursive FSM lowering requires structural MIR conditions"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1340 `PipelineConcurrentLowerer#callback_body`: score 405; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 178
  - source: src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1363 raise `raise "unknown bounded concurrent callback kind #{body_kind}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_ops.rb:348 `FsmOps::Lowerer#lower_expr`: score 404; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 177
  - source: src/mir/fsm_ops.rb:353 raise `raise ArgumentError, "FsmOps arg index #{idx} out of range (#{@arg_mirs.length} args)"`
  - source: src/mir/fsm_ops.rb:395 raise `raise ArgumentError, "FsmOps::Lowerer unknown expression op #{expr.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:279 `FsmTransform::RecursiveSplitter.emit_suspend_with_pre`: score 403; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 175
  - source: src/mir/fsm_transform/recursive_splitter.rb:282 raise `raise UnsupportedShape, "Unhandled suspend kind #{susp_tail.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:396 `FsmTransform::RecursiveSplitter.emit_pivot`: score 403; direct sources 1; runtime raises 0/0 (0.0%); handlers 13 (exclusive 0, shared 13); unhandled callers 175
  - source: src/mir/fsm_transform/recursive_splitter.rb:413 raise `raise UnsupportedShape, "Unhandled pivot kind #{stmt.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/mir/fsm_transform/recursive_splitter.rb:201 `FsmTransform::RecursiveSplitter.split` shared; protected `FsmTransform::RecursiveSplitter.emit_stmts`; roots `CapabilityPlan.require_for` | `FsmTransform::RecursiveSplitter.emit_for_each_fragment` | `FsmTransform::RecursiveSplitter.emit_for_range_fragment` | `FsmTransform::RecursiveSplitter.emit_if_fragment`
  - ... 10 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_ops.rb:300 `FsmOps::Lowerer#lower_stmt`: score 402; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 176
  - source: src/mir/fsm_ops.rb:321 raise `raise ArgumentError, "FsmOps::IoSubmit unknown verb #{op.verb.inspect}"`
  - source: src/mir/fsm_ops.rb:343 raise `raise ArgumentError, "FsmOps::Lowerer unknown statement op #{op.class}"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:3066 `ClearParser#parse_capability_chain!`: score 398; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 174
  - source: src/ast/parser.rb:3069 error! `error!(current, :EXPECTED_CAP_AFTER_COLON)`
  - source: src/ast/parser.rb:3074 error! `error!(tok, :CAP_BAD_MODIFIER, cap: cap_tok&.value || "capability", modifier: tok.value)`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/suspend_resolvers.rb:54 `FsmTransform::SuspendResolvers.resolve_io`: score 398; direct sources 2; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 174
  - source: src/mir/fsm_transform/suspend_resolvers.rb:57 raise `raise ArgumentError, "IoSuspend missing stdlib_def"`
  - source: src/mir/fsm_transform/suspend_resolvers.rb:88 raise `raise ArgumentError, "FSM IO result #{result_var} missing Zig type"`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/recursive_splitter.rb:175 `FsmTransform::RecursiveSplitter::Builder#finalize`: score 397; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 174
  - source: src/mir/fsm_transform/recursive_splitter.rb:179 raise `raise "RecursiveSplitter: unfilled segments at indices " \`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/mir/fsm_transform/suspend_resolvers.rb:28 `FsmTransform::SuspendResolvers.resolve`: score 395; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 173
  - source: src/mir/fsm_transform/suspend_resolvers.rb:35 raise `raise ArgumentError,`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:2695 `ClearParser#parse_fn_type_annotation`: score 393; direct sources 1; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 172
  - source: src/ast/parser.rb:2712 error! `error!(current, :PARSER_EXPECTED, expected: "supported function type annotation", got: current.value, type: current.type, line: current.line)`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- src/ast/parser.rb:2723 `ClearParser#parse_type_annotation`: score 393; direct sources 3; runtime raises 0/0 (0.0%); handlers 12 (exclusive 0, shared 12); unhandled callers 171
  - source: src/ast/parser.rb:2767 error! `error!(current, :AUTO_PREFIX_NOT_SUPPORTED, prefix: prefix_chars, prefix2: prefix_chars, prefix3: prefix_chars, prefix4: prefix_chars)`
  - source: src/ast/parser.rb:2824 error! `error!(current, :ARRAY_TYPE_BAD)`
  - source: src/ast/parser.rb:2837 error! `error!(current, :ARRAY_TYPE_EXPECTED_SIZE)`
  - handler: src/lsp/analyzer.rb:35 `LSP::Analyzer.run` shared; protected `ClearParser#parse` | `SemanticAnnotator#annotate!`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/lsp/rpc.rb:34 `LSP::RPC.read_message` shared; protected `ClearParser#parse` | `LSP::RPC.read_headers` | `LSP::RPC.read_message` | `MIR::InlineAllocMetadata#inspect`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - handler: src/semantic/escape_analysis.rb:886 `EscapeAnalysis.expr_has_owned_inline_value?` shared; protected `AST.each_locatable` | `AST::Locatable#full_type!` | `EscapeAnalysis.unwrap_value` | `Type#heap_ptr?`; roots `AST.stamp_synthetic_type!` | `AST::Locatable#full_type!` | `Annotator::Domains::ControlFlow#analyze_when_match_case!` | `Annotator::Domains::ControlFlow#annotate_struct_pattern!`
  - ... 9 more handler(s)
  - unhandled callers: `AST.each_capture_analysis` | `AST.each_locatable` | `AST.walk_body` | `Annotator::Domains::Expressions#visit_Placeholder` | `Annotator::Domains::Lifetimes#handle_assign_borrow` | ...
- ... 372 more fallibility root(s)

## Struct Shape Report
- Struct declarations: 335
- Runtime-observed struct field slots: 660
- Static constructor field observations: 7151

### Struct Field Slot Breakdown
- missing field type with candidate: 120
  - `AST::Param.name` -> String (runtime 100314)
  - `AST::Param.takes` -> T.any(FalseClass, Lexer::Token, TrueClass) (runtime 89155)
  - `AST::Capture.name` -> String (runtime 33)
  - `AST::Capture.mutable` -> T.any(FalseClass, Lexer::Token) (runtime 32)
  - `AST::Capture.takes` -> T::Boolean (runtime 32)
  - `AST::Capture.comptime` -> T::Boolean (runtime 32)
  - `AST::Capture.name_token` -> Lexer::Token (runtime 32)
  - `AST::MatchCase.kind` -> Symbol (runtime 2827)
  - ... 112 more
- missing field type with no candidate: 78
  - `AST::Param.type`
  - `AST::Param.default`
  - `AST::Param.mutable`
  - `AST::Param.comptime`
  - `AST::Param.name_token`
  - `AST::Param.required`
  - `AST::Param.sync`
  - `AST::Param.symbol`
  - ... 70 more
- untyped with runtime candidate: 210
  - `AST::CallSiteOverride.inner` current `T.untyped` -> AST::FuncCall (runtime 5)
  - `AST::StructLit.fields` current `T.untyped` -> T.any(Array, Hash, T::Hash[`T.untyped`, `T.untyped`]) (runtime 9683)
  - `AST::DieNode.status` current `T.untyped` -> T.any(AST::Literal, Integer) (runtime 5)
  - `AST::Slice.target` current `T.untyped` -> T.any(AST::GetIndex, AST::Identifier) (runtime 67)
  - `AST::ReduceOp.initial_value` current `T.untyped` -> T.any(AST::Identifier, AST::Literal) (runtime 269)
  - `AST::ReduceOp.expression` current `T.untyped` -> T.any(AST::BinaryOp, AST::Identifier) (runtime 269)
  - `AST::OrderByOp.expression` current `T.untyped` -> T.any(AST::GetField, AST::Identifier) (runtime 32)
  - `AST::LimitOp.count` current `T.untyped` -> AST::Literal (runtime 247)
  - ... 202 more
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
- untyped with no candidate: 269
  - `AST::RequireNode.path` current `T.untyped`
  - `AST::RequireNode.namespace` current `T.untyped`
  - `AST::FunctionDef.name` current `T.untyped`
  - `AST::FunctionDef.return_lifetime` current `T.untyped`
  - `AST::FunctionDef.catch_clauses` current `T.untyped`
  - `AST::FunctionDef.default_catch` current `T.untyped`
  - `AST::FunctionDef.deferred_drops` current `T.untyped`
  - `AST::FunctionDef.uses_frame` current `T.untyped`
  - ... 261 more
- weak collection or union type: 46
  - `Capabilities::Conflict.set_a` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 1135)
  - `Capabilities::Conflict.set_b` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 1135)
  - `AST::Program.statements` current T::Array[`T.untyped`]
  - `AST::FunctionDef.params` current T::Array[`T.untyped`]
  - `AST::FunctionDef.captures` current T.nilable(T::Array[`T.untyped`])
  - `AST::FunctionDef.body` current T::Array[`T.untyped`]
  - `AST::StructDef.type_params` current T::Array[`T.untyped`] -> T::Array[String] (static)
  - `AST::ListLit.items` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 4480)
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
  - `AST::Program.token` current Lexer::Token -> T.any(Lexer::Token, T::Array[`T.untyped`]) (runtime 10176)
  - `AST::RequireNode.token` current Token
  - `AST::RequireNode.kind` current Symbol -> Symbol (static)
  - `AST::FunctionDef.token` current Token
  - `AST::FunctionDef.visibility` current Symbol
  - ... 284 more

### Struct Field Type Candidates
- `AST::Param.name`; String; runtime; 100314 call(s)
- `AST::Param.takes`; T.any(FalseClass, Lexer::Token, TrueClass); runtime; 89155 call(s)
- `AST::FuncCall.args`; T.any(Array, T::Array[AST::Node], T::Array[`T.untyped`]); runtime; 23213 call(s)
- `BinaryOpResult.type`; Type; runtime; 18282 call(s)
- `AST::MethodCall.args`; T.any(Array, T::Array[AST::Node], T::Array[`T.untyped`]); runtime; 17237 call(s)
- `AST::Program.token`; T.any(Lexer::Token, T::Array[`T.untyped`]); runtime; 10176 call(s)
- `AST::StructLit.fields`; T.any(Array, Hash, T::Hash[`T.untyped`, `T.untyped`]); runtime; 9683 call(s)
- `MIR::Call.callee`; String; runtime; 9244 call(s)
- `MIR::Call.owned_return`; T.any(FalseClass, T::Boolean, TrueClass); runtime; 9032 call(s)
- `MIR::TransferMark.target`; Symbol; runtime; 7841 call(s)
- `AST::StructField.borrowed`; T::Boolean; runtime; 7465 call(s)
- `MIR::MethodCall.args`; T.any(Array, T::Array[MIR::Node], T::Array[`T.untyped`]); runtime; 6412 call(s)
- `MIR::MethodCall.try_wrap`; T.any(FalseClass, T::Boolean, TrueClass); runtime; 6412 call(s)
- `MIR::FnDef.params`; T.any(Array, T::Array[MIR::Param], T::Array[`T.untyped`]); runtime; 4611 call(s)
- `AST::ListLit.items`; T.any(Array, T::Array[`T.untyped`]); runtime; 4480 call(s)
- `AST::Capability.capability`; Symbol; runtime; 4197 call(s)
- `AST::Capability.alias_mutable`; T::Boolean; runtime; 4090 call(s)
- `AST::BgBlock.body`; T.any(Array, T::Array[`T.untyped`]); runtime; 3986 call(s)
- `FsmTransform::Segments::Segment.stmts`; T.any(Array, T::Array[SegmentStmt], T::Array[`T.untyped`]); runtime; 3036 call(s)
- `MIR::FieldDef.zig_type`; String; runtime; 2893 call(s)
- `MIR::IfStmt.then_body`; T.any(Array, T::Array[MIR::IfStmt], T::Array[`T.untyped`]); runtime; 2849 call(s)
- `AST::MatchCase.kind`; Symbol; runtime; 2827 call(s)
- `MIR::AssertStmt.message`; String; runtime; 2316 call(s)
- `FsmOps::IoSubmit.waiter`; FsmOps::StateField; runtime; 2278 call(s)
- `CompilerFrontend::Result.ast`; AST::Program; runtime; 2165 call(s)
- `CompilerFrontend::Result.fn_nodes`; T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]); runtime; 2165 call(s)
- `CompilerFrontend::Result.fn_sigs`; T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]); runtime; 2165 call(s)
- `CompilerFrontend::Result.moved_guard_info`; T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]); runtime; 2165 call(s)
- `Formatter::Emitter::FnSig.arrow_idx`; Integer; runtime; 2140 call(s)
- `Formatter::Emitter::FnSig.start`; Integer; runtime; 2140 call(s)
- `Formatter::Emitter::FnSig.toks`; T::Array[Formatter::FormatLexer::Token]; runtime; 2140 call(s)
- `MIR::ErrCleanup.cleanup_entry`; CleanupEntry; runtime; 2078 call(s)
- `MIR::ErrCleanup.name`; String; runtime; 2078 call(s)
- `MIR::OwnedStore.alloc`; Symbol; runtime; 2031 call(s)
- `MIR::OwnedStore.target`; String; runtime; 2031 call(s)
- `MIR::FsmStateArm.index`; Integer; runtime; 1993 call(s)
- `AST::RangeLit.start`; T.any(AST::BinaryOp, AST::Identifier, AST::Literal); runtime; 1816 call(s)
- `AST::RangeLit.token`; Lexer::Token; runtime; 1816 call(s)
- `BinaryOpResult.storage`; Symbol; runtime; 1573 call(s)
- `MIR::WhileStmt.body`; T.any(Array, T::Array[MIR::Emittable], T::Array[`T.untyped`]); runtime; 1451 call(s)
- `MIR::FsmMemberFn.bg_rt`; String; runtime; 1341 call(s)
- `MIR::FsmMemberFn.body_stmts`; T.any(Array, T::Array[FsmBodyEmission]); runtime; 1341 call(s)
- `MIR::FsmMemberFn.ctx_id`; Integer; runtime; 1341 call(s)
- `MIR::FsmMemberFn.extra_prologue_stmts`; T::Array[MIR::Comment]; runtime; 1341 call(s)
- `MIR::FsmMemberFn.fn_name`; String; runtime; 1341 call(s)
- `MIR::FsmMemberFn.suppress_runtime_ref`; T::Boolean; runtime; 1341 call(s)
- `MIR::StructDef.fields`; T.any(Array, T::Array[MIR::FieldDef], T::Array[`T.untyped`]); runtime; 1306 call(s)
- `MIR::ContainerInit.strategy`; Symbol; runtime; 1302 call(s)
- `MIR::ContainerInit.zig_type`; String; runtime; 1302 call(s)
- `MIR::ArrayInit.items`; T.any(Array, T::Array[MIR::Ident], T::Array[`T.untyped`]); runtime; 1234 call(s)

## Collection Type Report
- Array signature slots: 1224 total, 928 strong, 296 weak, 0 nilable
- Hash signature slots: 255 total, 180 strong, 75 weak, 5 nilable

### Hash Record Struct Candidates (Shapes + Pressure)
- literal shape: a statically observed hash literal instantiation site in this candidate cluster
- similar keyset: a distinct hash key set grouped into the same likely record, e.g. `{name, id}` with `{name, id, type}`
- AddrsRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 18
  - common keys: addrs, allocs, bytes, free_bytes, frees
  - read keys: addrs(2), allocs(2), bytes(2), free_bytes(1), frees(1)
  - accounts for: return 0, param 10, ivar 0, collection 8
  - related pressure records: local hash record s at src/tools/doctor.rb (61); local hash record v at src/tools/doctor.rb (8); local hash record vals at src/tools/doctor.rb (4); local hash record s at src/tools/pprof_converter.rb (3)
  - src/tools/pprof_converter.rb:143 s[:addrs]; receiver s
  - src/tools/pprof_converter.rb:147 s[:allocs]; receiver s
  - src/tools/pprof_converter.rb:148 s[:bytes]; receiver s
  - src/tools/pprof_converter.rb:149 s[:allocs]; receiver s
  - suggested struct:
    class AddrsRecord < T::Struct
      const :addrs, `T.untyped`
      const :allocs, Integer
      const :bytes, Integer
      const :free_bytes, Integer
      const :frees, Integer
    end
- AllocsRecord: 8 literal shape(s), 3 similar keyset(s), total pressure 14
  - common keys: allocs, bytes
  - optional keys: addr, free_bytes, frees, inuse_allocs, inuse_bytes, live, trace
  - read keys: bytes(6), allocs(5)
  - accounts for: return 0, param 3, ivar 0, collection 11
  - related pressure records: local hash record s at src/tools/doctor.rb (61); local hash record v at src/tools/doctor.rb (8); local hash record vals at src/tools/doctor.rb (4)
  - src/tools/doctor.rb:1338 self_total[:bytes]; receiver self_total
  - src/tools/doctor.rb:1346 self_total[:bytes]; receiver self_total
  - src/tools/doctor.rb:1346 self_total[:allocs]; receiver self_total
  - src/tools/doctor.rb:1472 b[:bytes]; receiver b
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
  - related pressure records: local hash record l at src/tools/pprof_converter.rb (26); local hash record l at src/tools/doctor.rb (20); local hash record r at src/tools/doctor.rb (20)
  - src/tools/doctor.rb:1544 b[:contended]; receiver b
  - src/tools/doctor.rb:1544 b[:read_contended]; receiver b
  - src/tools/doctor.rb:1545 a[:contended]; receiver a
  - src/tools/doctor.rb:1545 a[:read_contended]; receiver a
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
- CommitsRecord: 4 literal shape(s), 2 similar keyset(s), total pressure 8
  - common keys: commits, reads, retries
  - optional keys: addr, caller_trace, struct_size
  - read keys: retries(4), commits(2)
  - accounts for: return 0, param 2, ivar 0, collection 6
  - related pressure records: local hash record c at src/tools/pprof_converter.rb (34); hash record return first at src/tools/doctor.rb:934 (1)
  - src/tools/doctor.rb:1613 a[:commits]; receiver a
  - src/tools/doctor.rb:1613 b[:commits]; receiver b
  - src/tools/doctor.rb:1614 a[:retries]; receiver a
  - src/tools/doctor.rb:1614 b[:retries]; receiver b
  - suggested struct:
    class CommitsRecord < T::Struct
      prop :addr, `T.untyped`
      prop :caller_trace, T.nilable(T::Array[`T.untyped`])
      const :commits, Integer
      const :reads, Integer
      const :retries, Integer
      prop :struct_size, T.nilable(Integer)
    end
- ExpectedRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 8
  - common keys: expected, got
  - read keys: name(2), actual(1), got(1)
  - accounts for: return 0, param 4, ivar 0, collection 4
  - src/annotator/helpers/fixable_helpers.rb:1355 kw[:got]; receiver kw
  - src/annotator/helpers/fixable_helpers.rb:1364 kw[:name]; receiver kw
  - src/annotator/helpers/fixable_helpers.rb:1365 kw[:actual]; receiver kw
  - src/annotator/helpers/fixable_helpers.rb:1374 kw[:name]; receiver kw
  - suggested struct:
    class ExpectedRecord < T::Struct
      const :expected, `T.untyped`
      const :got, Symbol
    end
- NameRecord: 3 literal shape(s), 2 similar keyset(s), total pressure 7
  - common keys: name, stack_bytes
  - optional keys: zig_name
  - read keys: line(3), usage_pct(1)
  - accounts for: return 0, param 3, ivar 0, collection 4
  - related pressure records: hash record param field at src/mir/mir.rb:663 (2); hash record return candidate_decl_info at src/tools/migration_suggester_helpers.rb:64 (2); hash record return [] at src/annotator/helpers/fixable_helpers.rb:1808 (1); hash record return first at src/mir/lowering/variables.rb:98 (1)
  - src/tools/stack_verifier.rb:126 entry[:line]; receiver entry
  - src/tools/stack_verifier.rb:134 entry[:line]; receiver entry
  - src/tools/stack_verifier.rb:142 entry[:line]; receiver entry
  - src/tools/stack_verifier.rb:145 entry[:usage_pct]; receiver entry
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
  - related pressure records: hash record hash literal at src/tools/stack_verifier.rb:291 (3); hash record hash literal at src/tools/stack_verifier.rb:86 (3)
  - src/tools/stack_verifier.rb:87 pending_mov[:reg]; receiver pending_mov
  - src/tools/stack_verifier.rb:89 pending_mov[:bytes]; receiver pending_mov
  - src/tools/stack_verifier.rb:292 pending_mov[:reg]; receiver pending_mov
  - src/tools/stack_verifier.rb:293 pending_mov[:bytes]; receiver pending_mov
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
  - related pressure records: hash record param v at src/annotator/helpers/intrinsic_registry.rb:117 (6)
  - src/ast/parser.rb:3622 dims[:ownership]; receiver dims
  - src/ast/parser.rb:3622 dims[:sync]; receiver dims
  - src/ast/parser.rb:3622 dims[:layout]; receiver dims
  - src/ast/parser.rb:3622 dims[:lock_rank]; receiver dims
  - suggested struct:
    class OwnershipRecord < T::Struct
      prop :layout, NilClass
      prop :lock_rank, NilClass
      const :ownership, NilClass
      const :sync, NilClass
    end
- DescriptionCodeRecord: 4 literal shape(s), 1 similar keyset(s), total pressure 6
  - common keys: description_code, description_params, sigil
  - read keys: description_code(1), description_params(1), sigil(1)
  - accounts for: return 0, param 3, ivar 0, collection 3
  - src/annotator/helpers/fixable_helpers.rb:1033 c[:sigil]; receiver c
  - src/annotator/helpers/fixable_helpers.rb:1034 c[:description_code]; receiver c
  - src/annotator/helpers/fixable_helpers.rb:1035 c[:description_params]; receiver c
  - suggested struct:
    class DescriptionParamsRecord < T::Struct
      const :reader, String
      const :suffix, String
    end

    class DescriptionCodeRecord < T::Struct
      const :description_code, Symbol
      const :description_params, DescriptionParamsRecord
      const :sigil, String
    end
- CaptureRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 6
  - common keys: capture, expr
  - read keys: expr(4), capture(2)
  - accounts for: return 0, param 0, ivar 0, collection 6
  - related pressure records: hash record return [] at src/backends/mir_emitter.rb:1694 (7); local hash record binding at src/mir/mir_checker.rb (3); local hash record binding at src/mir/hoist.rb (2); local hash record binding at src/mir/mir_lowering.rb (2); local hash record entry at src/annotator/helpers/capabilities.rb (2)
  - src/mir/hoist.rb:846 binding[:expr]; receiver binding
  - src/mir/hoist.rb:847 binding[:capture]; receiver binding
  - src/mir/mir.rb:1095 binding[:expr]; receiver binding
  - src/mir/mir_checker.rb:652 binding[:expr]; receiver binding
  - suggested struct:
    class CaptureRecord < T::Struct
      const :capture, `T.untyped`
      const :expr, `T.untyped`
    end
- DispatchRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 5
  - common keys: dispatch, exits, form, id, max_lifetime_ns, runs, scheds, spawns, total_lifetime_ns
  - read keys: runs(3), dispatch(1), scheds(1)
  - accounts for: return 0, param 1, ivar 0, collection 4
  - related pressure records: local hash record site at src/tools/doctor.rb (10); hash record hash literal at src/tools/pprof.rb:141 (4); hash record return [] at src/tools/pprof.rb:139 (4); hash record hash literal at src/tools/pprof.rb:119 (3)
  - src/tools/doctor.rb:528 site[:runs]; receiver site
  - src/tools/doctor.rb:528 site[:runs]; receiver site
  - src/tools/doctor.rb:531 site[:dispatch]; receiver site
  - src/tools/doctor.rb:582 site[:scheds]; receiver site
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
  - related pressure records: hash record hash literal at src/tools/stack_verifier.rb:102 (5)
  - src/tools/stack_verifier.rb:127 report[:warnings]; receiver report
  - src/tools/stack_verifier.rb:135 report[:warnings]; receiver report
  - src/tools/stack_verifier.rb:143 report[:warnings]; receiver report
  - src/tools/stack_verifier.rb:153 report[:functions]; receiver report
  - suggested struct:
    class FunctionsRecord < T::Struct
      const :functions, T::Array[`T.untyped`]
      const :source_file, T.nilable(String)
      const :warnings, T::Array[`T.untyped`]
    end
- NameRecord: 3 literal shape(s), 2 similar keyset(s), total pressure 4
  - common keys: name, value
  - optional keys: alloc
  - read keys: value(1)
  - accounts for: return 0, param 3, ivar 0, collection 1
  - related pressure records: local hash record field at src/mir/lowering/expressions.rb (8); hash record param field at src/mir/mir.rb:671 (4); hash record param field at src/mir/mir.rb:663 (2); hash record param field at src/mir/mir.rb:679 (2); hash record return candidate_decl_info at src/tools/migration_suggester_helpers.rb:64 (2)
  - src/mir/mir.rb:673 field[:value]; receiver field
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
  - related pressure records: hash record hash literal at src/tools/pprof.rb:141 (4); hash record return [] at src/tools/pprof.rb:139 (4); hash record hash literal at src/tools/pprof.rb:119 (3)
  - src/tools/pprof.rb:150 f[:id]; receiver f
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
  - related pressure records: hash record return must at src/mir/lowering/variables.rb:1047 (2)
  - src/tools/doctor.rb:507 r[:runs]; receiver r
  - src/tools/doctor.rb:509 r[:runs]; receiver r
  - src/tools/doctor.rb:511 r[:idx]; receiver r
  - src/tools/doctor.rb:511 r[:runs]; receiver r
  - suggested struct:
    class IdxRecord < T::Struct
      const :idx, Integer
      const :runs, Integer
    end
- BgEntriesRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 3
  - common keys: bg_entries, call_graph, fn_addrs, fn_names, frame_sizes
  - read keys: call_graph(1), fn_names(1), frame_sizes(1)
  - accounts for: return 0, param 0, ivar 0, collection 3
  - related pressure records: hash record param graph_data at src/tools/stack_verifier.rb:340 (3); hash record return extract_full_call_graph at src/tools/stack_verifier.rb:405 (2); hash record return extract_full_call_graph at src/tools/stack_verifier.rb:391 (1)
  - src/tools/stack_verifier.rb:341 graph_data[:frame_sizes]; receiver graph_data
  - src/tools/stack_verifier.rb:342 graph_data[:call_graph]; receiver graph_data
  - src/tools/stack_verifier.rb:343 graph_data[:fn_names]; receiver graph_data
  - suggested struct:
    class BgEntriesRecord < T::Struct
      const :bg_entries, `T.untyped`
      const :call_graph, Object
      const :fn_addrs, Object
      const :fn_names, Object
      const :frame_sizes, Object
    end
- BuildIdIdxRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 3
  - common keys: build_id_idx, filename_idx, has_filenames, has_functions, has_line_numbers, id
  - read keys: id(2)
  - accounts for: return 1, param 0, ivar 0, collection 2
  - related pressure records: hash record param m at src/tools/pprof.rb:274 (9); hash record hash literal at src/tools/pprof.rb:141 (4); hash record return [] at src/tools/pprof.rb:139 (4); hash record hash literal at src/tools/pprof.rb:119 (3)
  - src/tools/pprof.rb:129 mapping[:id]; receiver mapping
  - src/tools/pprof.rb:130 mapping[:id]; receiver mapping
  - suggested struct:
    class BuildIdIdxRecord < T::Struct
      const :build_id_idx, Integer
      const :filename_idx, Integer
      const :has_filenames, T::Boolean
      const :has_functions, T::Boolean
      const :has_line_numbers, T::Boolean
      const :id, Integer
    end
- ExprRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 1
  - common keys: expr, source
  - read keys: expr(1)
  - accounts for: return 0, param 0, ivar 0, collection 1
  - related pressure records: local hash record entry at src/annotator/helpers/capabilities.rb (2); local hash record entry at src/mir/lowering/capabilities.rb (2); local hash record entry at src/mir/lowering/functions.rb (2); hash record return collect_chain at src/mir/rewriters/pipeline_rewriter.rb:255 (1); local hash record binding at src/mir/mir.rb (1)
  - src/annotator/helpers/capabilities.rb:600 entry[:expr]; receiver entry
  - suggested struct:
    class ExprRecord < T::Struct
      const :expr, `T.untyped`
      const :source, String
    end
- EndRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 1
  - common keys: end, start
  - read keys: end(1)
  - accounts for: return 0, param 0, ivar 0, collection 1
  - related pressure records: local hash record seg at src/tools/formatter.rb (4); hash record param range at src/lsp/position.rb:63 (2)
  - src/tools/formatter.rb:1821 segments.last[:end]; receiver segments.last
  - suggested struct:
    class EndRecord < T::Struct
      const :end, AST::StructField
      const :start, AST::StructField
    end
- CategoryRecord: 461 literal shape(s), 4 similar keyset(s), total pressure 0
  - common keys: category, severity, summary, template
  - optional keys: cause, fix_hint, pending
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: local hash record entry at src/ast/diagnostic_registry.rb (6); hash record param entry at src/lsp/hover.rb:92 (5); hash record param entry at src/lsp/hover.rb:133 (2); hash record return [] at src/ast/diagnostic_registry.rb:2979 (1); hash record return [] at src/ast/diagnostic_registry.rb:2988 (1)
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
  - related pressure records: hash record param h at src/annotator/helpers/intrinsic_registry.rb:170 (4)
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
  - related pressure records: hash record hash literal at src/tools/pprof.rb:141 (4); hash record return [] at src/tools/pprof.rb:139 (4); hash record hash literal at src/tools/pprof.rb:119 (3); hash record param entry at src/lsp/hover.rb:133 (2)
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
  - related pressure records: hash record param field at src/mir/mir.rb:679 (2)
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
  - related pressure records: hash record param h at src/annotator/helpers/intrinsic_registry.rb:170 (4); hash record param field at src/mir/mir.rb:679 (2)
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
  - related pressure records: hash record return [] at src/annotator/helpers/fixable_helpers.rb:1489 (5); hash record return [] at src/annotator/helpers/fixable_helpers.rb:1497 (1)
  - suggested struct:
    class AltsRecord < T::Struct
      const :alts, T::Array[`T.untyped`]
      const :default, Symbol
      prop :notes, T.nilable(Object)
    end
- FirstSiteRecord: 11 literal shape(s), 1 similar keyset(s), total pressure 0
  - common keys: first_site, id, kind, zig_name
  - accounts for: return 0, param 0, ivar 0, collection 0
  - related pressure records: hash record hash literal at src/tools/pprof.rb:141 (4); hash record return [] at src/tools/pprof.rb:139 (4); hash record hash literal at src/tools/pprof.rb:119 (3); hash record return [] at src/ast/error_registry.rb:127 (3); local hash record meta at src/ast/error_registry.rb (2)
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
  - related pressure records: hash record param v at src/annotator/helpers/intrinsic_registry.rb:117 (6); hash record return [] at src/annotator/helpers/generic_analysis.rb:310 (2); hash record return [] at src/annotator/helpers/union.rb:75 (2)
  - suggested struct:
    class SyncRecord < T::Struct
      const :sync, Symbol
      const :type, Symbol
    end

### Weak Collection Slots With Runtime Candidates
- src/annotator/helpers/fixable_helpers.rb:110 `FixableHelper#emit_registry_mismatch!` param candidates: T::Array[`T.untyped`] -> T::Array[Symbol] (12 call(s))
- src/annotator/helpers/fixable_helpers.rb:387 `FixableHelper#emit_use_of_moved_path_error!` param path: T::Array[`T.untyped`] -> T::Array[Symbol] (4 call(s))
- src/annotator/helpers/fixable_helpers.rb:1482 `FixableHelper#auto_rank_candidates` return return: T::Array[T::Array[`T.untyped`]] -> T::Array[T::Array[T.nilable(T.any(String, Symbol))]] (22 call(s))
- src/annotator/helpers/fixable_helpers.rb:1540 `FixableHelper#build_auto_op_evidence_block` param candidates: T::Array[`T.untyped`] -> T::Array[T::Array[T.nilable(T.any(String, Symbol))]] (4 call(s))
- src/annotator/helpers/fixable_helpers.rb:1619 `FixableHelper#build_auto_replace_fixes` return return: T::Array[`T.untyped`] -> T::Array[Fix] (20 call(s))
- src/annotator/helpers/fixable_helpers.rb:1786 `FixableHelper#build_auto_ambiguity_message` param observed_strs: T::Array[`T.untyped`] -> T::Array[String] (5 call(s))
- src/annotator/helpers/generic_analysis.rb:286 `GenericAnalysis#infer_generic_type_args!` return return: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, Type] (65 call(s))
- src/annotator/helpers/generic_analysis.rb:337 `GenericAnalysis#extract_type_bindings!` param subst: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, Type] (104 call(s))
- src/annotator/helpers/reentrance.rb:667 `ReentranceBridge#compute_reachable` param graph: T::Hash[String, T::Set[`T.untyped`]] -> T::Hash[String, T::Set[String]] (96 call(s))
- src/annotator/helpers/with_match_check.rb:206 `WithMatchCheck#enforce_polymorphic_iff_rule!` param requires_map: T::Hash[String, `T.untyped`] -> T::Hash[String, T::Set[Symbol]] (994 call(s))
- src/ast/ast.rb:2573 `AST#child_bodies` return return: T::Array[`T.untyped`] -> T::Array[Array] (6258 call(s))
- src/ast/ast.rb:2616 `AST#child_bodies` return return: T::Array[`T.untyped`] -> T::Array[Array] (1 call(s))
- src/ast/diagnostic_buckets.rb:537 `DiagnosticBuckets#status_of` param examples: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, T.nilable(String)]] (10 call(s))
- src/ast/diagnostic_examples.rb:76 `DiagnosticExamples#load!` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, `T.untyped`]] (7 call(s))
- src/ast/error_registry.rb:126 `AST#register_type!` return return: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (253 call(s))
- src/ast/error_registry.rb:164 `AST#enum_entries` return return: T::Array[`T.untyped`] -> T::Array[T::Array[T.any(Integer, Symbol)]] (1485 call(s))
- src/ast/parser.rb:54 `ClearParser#stmt` param pattern: T::Array[`T.untyped`] -> T::Array[T::Hash[String, Symbol]] (39725 call(s))
- src/ast/parser.rb:496 `ClearParser#process_pattern` param pattern: T::Array[`T.untyped`] -> T::Array[T::Hash[String, Symbol]] (27134 call(s))
- src/ast/parser.rb:1647 `ClearParser#parse_effects_decl` return return: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (16674 call(s))
- src/ast/parser.rb:3081 `ClearParser#parse_element_capability` return return: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T.nilable(Symbol)] (48594 call(s))
- src/ast/parser.rb:3105 `ClearParser#apply_element_capability!` param result: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T.nilable(Symbol)] (23 call(s))
- src/ast/parser.rb:3444 `ClearParser#parse_with_match_arms` return return: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (88 call(s))
- src/ast/source_error.rb:59 `ErrorHelper#format_diagnostic_template` param kwargs: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T::Array[Symbol]] (2188 call(s))
- src/compiler/module_importer.rb:36 `ModuleImporter#initialize` param pkg_paths: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, String] (2497 call(s))
- src/lsp/code_actions.rb:35 `LSP::CodeActions#for_range` return return: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (20 call(s))
- src/lsp/code_actions.rb:59 `LSP::CodeActions#build_action` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, T.any(T::Array[T::Hash[Symbol, `T.untyped`]], T::Hash[Symbol, T::Array[T::Hash[Symbol, `T.untyped`]]])] (14 call(s))
- src/lsp/code_actions.rb:83 `LSP::CodeActions#build_text_edit` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, T::Hash[Symbol, Integer]]] (15 call(s))
- src/lsp/document_store.rb:83 `LSP::DocumentStore#each` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, LSP::DocumentStore::Document] (1 call(s))
- src/lsp/position.rb:27 `LSP::Position#range_for` return return: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, Integer]] (83 call(s))
- src/lsp/position.rb:46 `LSP::Position#range_for_span` return return: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, Integer]] (19 call(s))
- src/lsp/position.rb:63 `LSP::Position#position_in_range?` param range: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, Integer]] (25 call(s))
- src/lsp/rpc.rb:55 `LSP::RPC#write_message` param msg: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, `T.untyped`] (53 call(s))
- src/lsp/server.rb:75 `LSP::Server#flush_pending!` return return: T::Array[`T.untyped`] -> T::Array[Thread] (4 call(s))
- src/lsp/server.rb:89 `LSP::Server#dispatch` param msg: T::Hash[String, `T.untyped`] -> T::Hash[String, T::Hash[String, `T.untyped`]] (68 call(s))
- src/lsp/server.rb:142 `LSP::Server#handle_initialize` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, T::Hash[Symbol, `T.untyped`]] (11 call(s))
- src/lsp/server.rb:188 `LSP::Server#handle_did_open` param params: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[String, `T.untyped`]] (17 call(s))
- src/lsp/server.rb:203 `LSP::Server#handle_did_change` param params: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, `T.untyped`] (8 call(s))
- src/lsp/server.rb:218 `LSP::Server#handle_did_save` param params: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[String, String]] (2 call(s))
- src/lsp/server.rb:228 `LSP::Server#handle_did_close` param params: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[String, String]] (2 call(s))
- src/lsp/server.rb:240 `LSP::Server#handle_code_action` param params: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[String, `T.untyped`]] (4 call(s))
- src/lsp/server.rb:240 `LSP::Server#handle_code_action` return return: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (4 call(s))
- src/lsp/server.rb:254 `LSP::Server#handle_hover` param params: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[String, `T.untyped`]] (3 call(s))
- src/lsp/server.rb:282 `LSP::Server#publish_diagnostics` param diagnostics: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (22 call(s))
- src/mir/control_flow.rb:1322 `UseAfterMoveChecker#check` return return: T::Array[`T.untyped`] -> T::Array[String] (15 call(s))
- src/mir/fsm_transform/recursive_splitter.rb:569 `FsmTransform::RecursiveSplitter#renumber_with_entry` return return: T::Array[`T.untyped`] -> T::Array[T.any(T::Array[FsmTransform::Segments::Segment], T::Hash[Integer, Integer])] (553 call(s))
- src/mir/hoist.rb:115 `Hoist#child_bodies` return return: T::Array[`T.untyped`] -> T::Array[Array] (20409 call(s))
- src/mir/hoist.rb:256 `Hoist#non_body_exprs` return return: T::Array[`T.untyped`] -> T::Array[T::Array[String]] (301246 call(s))
- src/mir/lowering/expressions.rb:1916 `MIRLoweringExpressions#pick_equality_helper` return return: T::Array[`T.untyped`] -> T::Array[T::Array[String]] (226 call(s))
- src/mir/mir_checker.rb:484 `MIRChecker#verify_structural_ownership_contracts!` param allocs: T::Hash[String, T::Array[`T.untyped`]] -> T::Hash[String, Array] (3258 call(s))
- src/mir/mir_checker.rb:1087 `MIRChecker#verify_err_cleanup_transfers!` param err_cleanups: T::Hash[String, T::Array[`T.untyped`]] -> T::Hash[String, Array] (3256 call(s))

### Weak Collection Slots Without Candidate
- src/annotator/domains/errors.rb:350 `Annotator::Domains::Errors#emit_error_type_conflict!` param conflict: T::Hash[Symbol, `T.untyped`]; key observations Symbol; value observations FalseClass, Lexer::Token, NilClass, Symbol
- src/annotator/helpers/auto_inference.rb:808 `ShapeEvidenceCollector#record_map_pair_evidence` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Literal
- src/annotator/helpers/auto_inference.rb:872 `OperatorEvidenceCollector#collect_in_function` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BindExpr, AST::MethodCall, AST::ReturnNode, AST::VarDecl
- src/annotator/helpers/auto_inference.rb:946 `OperatorEvidenceCollector#record_binop` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::Identifier, AST::Literal
- src/annotator/helpers/effects.rb:250 `EffectTracker#compute_effects!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator/helpers/effects.rb:499 `EffectTracker#compute_can_fail!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator/helpers/effects.rb:801 `EffectTracker#compute_fsm_eligibility!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator/helpers/effects.rb:834 `EffectTracker#enumerate_fsm_suspend_points!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator/helpers/function_analysis.rb:350 `FunctionAnalysis#resolve_call` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex
- src/annotator/helpers/function_analysis.rb:873 `FunctionAnalysis#warn_multi_atomic_bare_value_call!` param atomic_args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Identifier
- src/annotator/helpers/function_analysis.rb:953 `FunctionAnalysis#verify_no_mixed_atomic_returned_lifetime!` param sources: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::GetField, AST::Identifier
- src/annotator/helpers/function_analysis.rb:1306 `FunctionAnalysis#find_matching_intrinsic` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField
- src/annotator/helpers/function_return.rb:94 `FunctionReturn#resolve` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField
- src/annotator/helpers/generic_analysis.rb:286 `GenericAnalysis#infer_generic_type_args!` param actual_args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::Identifier, AST::Literal
- src/annotator/helpers/generic_analysis.rb:306 `GenericAnalysis#enforce_shared_family_call_sync!` param actual_args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::Identifier, AST::Literal
- src/annotator/helpers/generic_analysis.rb:368 `GenericAnalysis#apply_type_subst` param subst: T::Hash[Symbol, `T.untyped`]; key observations Symbol; value observations Symbol, Type
- src/annotator/helpers/intrinsic_registry.rb:194 `IntrinsicRegistry#sigs` return return: T::Hash[`T.untyped`, LookupResult]; key observations String, Symbol; value observations Array, FunctionSignature, NilClass
- src/annotator/helpers/method_analysis.rb:34 `MethodAnalysis#narrow_collection_type!` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField
- src/annotator/helpers/method_analysis.rb:60 `MethodAnalysis#resolve_typed_method` param registry: T::Hash[String, T::Hash[Symbol, `T.untyped`]]; key observations String; value observations Hash
- src/annotator/helpers/reentrance.rb:391 `ReentranceBridge#validate_max_depth_mutual_cycle!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/ast/ast.rb:22 `AST::BodySlot#initialize` param body: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode
- src/ast/ast.rb:28 `AST::BodySlot#replace` param body: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode
- src/ast/ast.rb:663 `AST#wrapped_children` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex
- src/ast/ast.rb:680 `AST#expression_children` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, AST::BgStreamBlock
- src/ast/ast.rb:870 `AST::HasBodies#child_bodies` return return: T::Array[`T.untyped`]; no element observations
- src/ast/ast.rb:1332 `AST#child_bodies` return return: T::Array[T::Array[`T.untyped`]]; method not observed at runtime
- src/ast/ast.rb:1375 `AST#params=` param val: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Param
- src/ast/ast.rb:1792 `AST#child_bodies` return return: T::Array[`T.untyped`]; method not observed at runtime
- src/ast/ast.rb:1822 `AST#child_bodies` return return: T::Array[`T.untyped`]; method not observed at runtime
- src/ast/ast.rb:1832 `AST#child_bodies` return return: T::Array[`T.untyped`]; method not observed at runtime
- ... 283 more

### Collection Blocker Pressure
- method_return expression_children array at src/ast/ast.rb:680; element observations are heterogeneous or AST/MIR-specific: AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, AST::BgStreamBlock: 1 slot(s), 314492 observation(s)
  - src/ast/ast.rb:680 `AST#expression_children` return return: T::Array[`T.untyped`]
- src/tools/formatter.rb:1782 `Formatter::Emitter#method_chain_start?` param out; no element observations: 1 slot(s), 218228 observation(s)
  - src/tools/formatter.rb:1782 `Formatter::Emitter#method_chain_start?` param out: Array
- src/tools/formatter.rb:1782 `Formatter::Emitter#method_chain_start?` param toks; no element observations: 1 slot(s), 218228 observation(s)
  - src/tools/formatter.rb:1782 `Formatter::Emitter#method_chain_start?` param toks: Array
- src/tools/formatter.rb:1907 `Formatter::Emitter#call_opener_kind` param toks; no element observations: 1 slot(s), 210436 observation(s)
  - src/tools/formatter.rb:1907 `Formatter::Emitter#call_opener_kind` param toks: Array
- src/tools/formatter.rb:2803 `Formatter::Emitter#needs_space?` param line; no element observations: 1 slot(s), 190092 observation(s)
  - src/tools/formatter.rb:2803 `Formatter::Emitter#needs_space?` param line: Array
- src/tools/formatter.rb:2598 `Formatter::Emitter#first_code` param line; no element observations: 1 slot(s), 76403 observation(s)
  - src/tools/formatter.rb:2598 `Formatter::Emitter#first_code` param line: Array
- method_param pattern array at src/ast/parser.rb:70; element observations are heterogeneous or AST/MIR-specific: String, Symbol: 1 slot(s), 70370 observation(s)
  - src/ast/parser.rb:70 `ClearParser#primary` param pattern: T::Array[`T.untyped`]
- src/tools/formatter.rb:2632 `Formatter::Emitter#format_line_body` param line; no element observations: 1 slot(s), 54187 observation(s)
  - src/tools/formatter.rb:2632 `Formatter::Emitter#format_line_body` param line: Array
- src/tools/formatter.rb:2672 `Formatter::Emitter#compute_generic_bracket_indices` param line; no element observations: 1 slot(s), 54187 observation(s)
  - src/tools/formatter.rb:2672 `Formatter::Emitter#compute_generic_bracket_indices` param line: Array
- src/tools/formatter.rb:2743 `Formatter::Emitter#compute_struct_lit_brace_indices` param line; no element observations: 1 slot(s), 54187 observation(s)
  - src/tools/formatter.rb:2743 `Formatter::Emitter#compute_struct_lit_brace_indices` param line: Array
- method_param body array at src/mir/hoist.rb:811; element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush, MIR::BinOp, MIR::BlockExpr: 1 slot(s), 45892 observation(s)
  - src/mir/hoist.rb:811 `MIRHoistLowering#normalize_allocating_mir_body` param body: T::Array[`T.untyped`]
- method_return normalize_allocating_mir_body array at src/mir/hoist.rb:811; element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush, MIR::BinOp, MIR::BlockExpr: 1 slot(s), 45892 observation(s)
  - src/mir/hoist.rb:811 `MIRHoistLowering#normalize_allocating_mir_body` return return: T::Array[`T.untyped`]
- src/tools/formatter.rb:2559 `Formatter::Emitter#split_indent_markers` param line; no element observations: 1 slot(s), 40985 observation(s)
  - src/tools/formatter.rb:2559 `Formatter::Emitter#split_indent_markers` param line: Array
- src/tools/formatter.rb:2559 `Formatter::Emitter#split_indent_markers` return return; no element observations: 1 slot(s), 40985 observation(s)
  - src/tools/formatter.rb:2559 `Formatter::Emitter#split_indent_markers` return return: Array
- src/tools/formatter.rb:2603 `Formatter::Emitter#last_code` param line; no element observations: 1 slot(s), 35444 observation(s)
  - src/tools/formatter.rb:2603 `Formatter::Emitter#last_code` param line: Array
- method_return sigs hash at src/annotator/helpers/intrinsic_registry.rb:194; key observations String, Symbol; value observations Array, FunctionSignature, NilClass: 1 slot(s), 30235 observation(s)
  - src/annotator/helpers/intrinsic_registry.rb:194 `IntrinsicRegistry#sigs` return return: T::Hash[`T.untyped`, LookupResult]
- src/tools/formatter.rb:301 `Formatter::Emitter#out_ends_with_nl?` param out; no element observations: 1 slot(s), 30145 observation(s)
  - src/tools/formatter.rb:301 `Formatter::Emitter#out_ends_with_nl?` param out: Array
- method_return process_pattern array at src/ast/parser.rb:496; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit: 1 slot(s), 27133 observation(s)
  - src/ast/parser.rb:496 `ClearParser#process_pattern` return return: T::Array[`T.untyped`]
- src/tools/formatter.rb:2470 `Formatter::Emitter#insert_nl` param out; no element observations: 1 slot(s), 22955 observation(s)
  - src/tools/formatter.rb:2470 `Formatter::Emitter#insert_nl` param out: Array
- method_return wrapped_children array at src/ast/ast.rb:663; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex: 1 slot(s), 19083 observation(s)
  - src/ast/ast.rb:663 `AST#wrapped_children` return return: T::Array[`T.untyped`]
- method_return parse_argument_list array at src/ast/parser.rb:870; element observations are heterogeneous or AST/MIR-specific: AST::Capture, AST::Param: 1 slot(s), 17008 observation(s)
  - src/ast/parser.rb:870 `ClearParser#parse_argument_list` return return: T::Array[`T.untyped`]
- method_return parse_effects_decl array at src/ast/parser.rb:1647; candidate still contains `T.untyped`: T::Array[T::Hash[Symbol, `T.untyped`]]: 1 slot(s), 16665 observation(s)
  - src/ast/parser.rb:1647 `ClearParser#parse_effects_decl` return return: T::Array[`T.untyped`]
- method_param stmts array at src/backends/mir_emitter.rb:2841; element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::AssertStmt, MIR::BatchWindowFlush, MIR::BatchWindowPush, MIR::BinOp, MIR::BlockExpr: 1 slot(s), 13748 observation(s)
  - src/backends/mir_emitter.rb:2841 `MIREmitter#emit_body` param stmts: T::Array[`T.untyped`]
- method_param atomic_args array at src/annotator/helpers/function_analysis.rb:873; element observations are heterogeneous or AST/MIR-specific: AST::Identifier: 1 slot(s), 12195 observation(s)
  - src/annotator/helpers/function_analysis.rb:873 `FunctionAnalysis#warn_multi_atomic_bare_value_call!` param atomic_args: T::Array[`T.untyped`]
- src/tools/formatter.rb:2482 `Formatter::Emitter#emit_stmt_terminator` param out; no element observations: 1 slot(s), 11719 observation(s)
  - src/tools/formatter.rb:2482 `Formatter::Emitter#emit_stmt_terminator` param out: Array
- src/tools/formatter.rb:2482 `Formatter::Emitter#emit_stmt_terminator` param toks; no element observations: 1 slot(s), 11719 observation(s)
  - src/tools/formatter.rb:2482 `Formatter::Emitter#emit_stmt_terminator` param toks: Array
- method_param args array at src/annotator/helpers/function_return.rb:94; element observations are heterogeneous or AST/MIR-specific: AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField: 1 slot(s), 11466 observation(s)
  - mutation sites: src/mir/hoist.rb:234 (266), src/mir/rewriters/pipeline_rewriter.rb:268 (1)
  - src/annotator/helpers/function_return.rb:94 `FunctionReturn#resolve` param args: T::Array[`T.untyped`]
- method_param subst hash at src/annotator/helpers/generic_analysis.rb:368; key observations Symbol; value observations Symbol, Type: 1 slot(s), 10513 observation(s)
  - src/annotator/helpers/generic_analysis.rb:368 `GenericAnalysis#apply_type_subst` param subst: T::Hash[Symbol, `T.untyped`]
- src/tools/formatter.rb:2931 `Formatter::Emitter#capability_chain_colon?` param line; no element observations: 1 slot(s), 10412 observation(s)
  - src/tools/formatter.rb:2931 `Formatter::Emitter#capability_chain_colon?` param line: Array
- src/tools/formatter.rb:1873 `Formatter::Emitter#process_call_arg_range` param toks; no element observations: 1 slot(s), 9888 observation(s)
  - src/tools/formatter.rb:1873 `Formatter::Emitter#process_call_arg_range` param toks: Array

### Runtime Collection Mutation Observations
- ivar: 95084 slot(s)
- method_param: 68402 slot(s)
- method_return: 47825 slot(s)
- struct_field: 23025 slot(s)
  - src/ast/lexer.rb:48 ivar @tokens; array; T::Array[Lexer::Token]; 678182 observation(s)
  - src/tools/lint_fix_rewriter.rb:67 method_param set; set; T::Set[String]; 574760 observation(s)
  - src/tools/lint_fix_rewriter.rb:88 method_param set; set; T::Set[String]; 574497 observation(s)
  - src/tools/lint_fix_rewriter.rb:198 method_param edits; array; T::Array[Hash]; 573862 observation(s)
  - src/tools/predicate_rewriter.rb:114 method_param edits; array; T::Array[PredicateRewriter::Edit]; 573056 observation(s)
  - src/tools/method_rewriter.rb:141 method_param edits; array; T::Array[Hash]; 572427 observation(s)
  - src/tools/method_rewriter.rb:141 method_param methods; set; T::Set[String]; 572272 observation(s)
  - src/tools/method_rewriter.rb:65 method_param fns; set; T::Set[String]; 527434 observation(s)
  - src/tools/method_rewriter.rb:65 method_param methods; set; T::Set[`T.untyped`]; 525432 observation(s)
  - src/tools/formatter.rb:213 ivar @out; array; T::Array[Formatter::FormatLexer::Token]; 309233 observation(s)
  - src/ast/scope.rb:28 method_return initialize; hash; T::Hash[String, SymbolEntry]; 196931 observation(s)
  - src/ast/scope.rb:35 ivar @entries; hash; T::Hash[String, SymbolEntry]; 196931 observation(s)
  - src/ast/scope.rb:274 ivar @owned_names; set; T::Set[String]; 190285 observation(s)
  - src/ast/symbol_entry.rb:1173 ivar @capabilities; set; T::Set[`T.untyped`]; 185659 observation(s)
  - src/ast/symbol_entry.rb:1174 ivar @lifetime; array; T::Array[`T.untyped`]; 185659 observation(s)
  - src/ast/scope.rb:28 method_return initialize; hash; T::Hash[String, SymbolEntry]; 121360 observation(s)
  - src/ast/scope.rb:35 ivar @entries; hash; T::Hash[String, SymbolEntry]; 121360 observation(s)
  - src/ast/scope.rb:274 ivar @owned_names; set; T::Set[String]; 118487 observation(s)
  - src/ast/symbol_entry.rb:1173 ivar @capabilities; set; T::Set[`T.untyped`]; 115910 observation(s)
  - src/ast/symbol_entry.rb:1174 ivar @lifetime; array; T::Array[`T.untyped`]; 115910 observation(s)
  - src/mir/pre_mir_type_check.rb:70 method_param seen; hash; T::Hash[Integer, TrueClass]; 105582 observation(s)
  - src/ast/scope.rb:28 method_return initialize; hash; T::Hash[String, SymbolEntry]; 99147 observation(s)
  - src/ast/scope.rb:35 ivar @entries; hash; T::Hash[String, SymbolEntry]; 99147 observation(s)
  - src/ast/scope.rb:274 ivar @owned_names; set; T::Set[String]; 98419 observation(s)
  - src/ast/lexer.rb:48 ivar @tokens; array; T::Array[Lexer::Token]; 97200 observation(s)
  - src/ast/symbol_entry.rb:1173 ivar @capabilities; set; T::Set[Symbol]; 96117 observation(s)
  - src/ast/symbol_entry.rb:1174 ivar @lifetime; array; T::Array[`T.untyped`]; 96117 observation(s)
  - src/ast/scope.rb:28 method_return initialize; hash; T::Hash[String, SymbolEntry]; 94547 observation(s)
  - src/ast/scope.rb:35 ivar @entries; hash; T::Hash[String, SymbolEntry]; 94547 observation(s)
  - src/ast/scope.rb:274 ivar @owned_names; set; T::Set[String]; 94212 observation(s)
  - src/ast/symbol_entry.rb:1173 ivar @capabilities; set; T::Set[`T.untyped`]; 91807 observation(s)
  - src/ast/symbol_entry.rb:1174 ivar @lifetime; array; T::Array[`T.untyped`]; 91807 observation(s)
  - src/ast/scope.rb:28 method_return initialize; hash; T::Hash[String, SymbolEntry]; 90657 observation(s)
  - src/ast/scope.rb:35 ivar @entries; hash; T::Hash[String, SymbolEntry]; 90657 observation(s)
  - src/ast/scope.rb:28 method_return initialize; hash; T::Hash[String, SymbolEntry]; 90192 observation(s)
  - src/ast/scope.rb:35 ivar @entries; hash; T::Hash[String, SymbolEntry]; 90192 observation(s)
  - src/ast/scope.rb:274 ivar @owned_names; set; T::Set[String]; 89986 observation(s)
  - src/ast/scope.rb:274 ivar @owned_names; set; T::Set[String]; 89518 observation(s)
  - src/ast/symbol_entry.rb:1173 ivar @capabilities; set; T::Set[Symbol]; 87896 observation(s)
  - src/ast/symbol_entry.rb:1174 ivar @lifetime; array; T::Array[`T.untyped`]; 87896 observation(s)

### Collection Index Lookup Provenance
- provenance: the inferred origin of the collection receiver being indexed with `[]`, `fetch`, or similar lookup syntax
- receiver origin: the parameter, literal, forwarded return, instance variable, or local record that produced the indexed receiver
- weak index lookup: an index lookup where the receiver is unknown, `T.untyped`, or a weak collection type
- unknown receiver type: 1208
- weak collection receiver: 305
- typed collection receiver: 228
- typed lookup: 221
- non-collection or unresolved receiver: 196

### Unknown Or Weak Index Lookups By Receiver Origin
- local hash record self at src/ast/ast.rb: 86
  - src/ast/ast.rb:120 self[:type]; receiver self; index :type; receiver type unknown
  - src/ast/ast.rb:131 self[:type]; receiver self; index :type; receiver type unknown
  - src/ast/ast.rb:149 self[:mutable]; receiver self; index :mutable; receiver type unknown
  - src/ast/ast.rb:150 self[:takes]; receiver self; index :takes; receiver type unknown
  - src/ast/ast.rb:151 self[:comptime]; receiver self; index :comptime; receiver type unknown
- local hash record c at src/tools/doctor.rb: 74
  - src/tools/doctor.rb:393 c[:pushes]; receiver c; index :pushes; receiver type unknown
  - src/tools/doctor.rb:393 c[:pops]; receiver c; index :pops; receiver type unknown
  - src/tools/doctor.rb:402 c[:capacity]; receiver c; index :capacity; receiver type unknown
  - src/tools/doctor.rb:403 c[:max_depth]; receiver c; index :max_depth; receiver type unknown
  - src/tools/doctor.rb:404 c[:pushes]; receiver c; index :pushes; receiver type unknown
- local hash record s at src/tools/doctor.rb: 57
  - src/tools/doctor.rb:164 s[:trace]; receiver s; index :trace; receiver type unknown
  - src/tools/doctor.rb:209 s[:trace]; receiver s; index :trace; receiver type unknown
  - src/tools/doctor.rb:213 s[:bytes]; receiver s; index :bytes; receiver type unknown
  - src/tools/doctor.rb:214 s[:allocs]; receiver s; index :allocs; receiver type unknown
  - src/tools/doctor.rb:225 s[:trace]; receiver s; index :trace; receiver type unknown
- local hash record d at src/tools/doctor.rb: 44
  - src/tools/doctor.rb:1477 d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - src/tools/doctor.rb:1477 d[:delta_allocs]; receiver d; index :delta_allocs; receiver type unknown
  - src/tools/doctor.rb:1478 d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - src/tools/doctor.rb:1486 d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - src/tools/doctor.rb:1488 d[:func]; receiver d; index :func; receiver type unknown
- hash record return cast at src/mir/fsm_transform.rb:135: 24
  - src/mir/fsm_transform.rb:137 raw_ctx.fetch(:id); receiver raw_ctx; index :id; receiver type unknown
  - src/mir/fsm_transform.rb:138 raw_ctx.fetch(:bg_rt); receiver raw_ctx; index :bg_rt; receiver type unknown
  - src/mir/fsm_transform.rb:139 raw_ctx.fetch(:blk_label); receiver raw_ctx; index :blk_label; receiver type unknown
  - src/mir/fsm_transform.rb:140 raw_ctx.fetch(:ctx_type); receiver raw_ctx; index :ctx_type; receiver type unknown
  - src/mir/fsm_transform.rb:141 raw_ctx.fetch(:promise_zig); receiver raw_ctx; index :promise_zig; receiver type unknown
- local hash record r at src/tools/doctor.rb: 24
  - src/tools/doctor.rb:506 r[:runs]; receiver r; index :runs; receiver type unknown
  - src/tools/doctor.rb:507 r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:509 r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:511 r[:idx]; receiver r; index :idx; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:511 r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record f at src/tools/stack_verifier.rb: 21
  - src/tools/stack_verifier.rb:105 f[:name]; receiver f; index :name; receiver type unknown
  - src/tools/stack_verifier.rb:105 f[:stack_bytes]; receiver f; index :stack_bytes; receiver type unknown
  - src/tools/stack_verifier.rb:107 f[:name]; receiver f; index :name; receiver type unknown
  - src/tools/stack_verifier.rb:123 f[:stack_bytes]; receiver f; index :stack_bytes; receiver type unknown
  - src/tools/stack_verifier.rb:129 f[:name]; receiver f; index :name; receiver type unknown
- local variable f: 20
  - src/tools/pprof_converter.rb:114 f[0]; receiver f; index 0; receiver type unknown
  - src/tools/pprof_converter.rb:117 f[1]; receiver f; index 1; receiver type unknown
  - src/tools/pprof_converter.rb:118 f[2]; receiver f; index 2; receiver type unknown
  - src/tools/pprof_converter.rb:119 f[3]; receiver f; index 3; receiver type unknown
  - src/tools/pprof_converter.rb:120 f[4]; receiver f; index 4; receiver type unknown
- hash record return options at src/annotator/helpers/pipe_analysis.rb:429: 16
  - src/annotator/helpers/pipe_analysis.rb:442 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator/helpers/pipe_analysis.rb:443 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator/helpers/pipe_analysis.rb:444 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator/helpers/pipe_analysis.rb:446 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator/helpers/pipe_analysis.rb:448 opts["size"]; receiver opts; index "size"; receiver type unknown
- local hash record c at src/tools/pprof_converter.rb: 16
  - src/tools/pprof_converter.rb:67 c[:pushes]; receiver c; index :pushes; receiver type unknown
  - src/tools/pprof_converter.rb:67 c[:pops]; receiver c; index :pops; receiver type unknown
  - src/tools/pprof_converter.rb:268 c[:reads]; receiver c; index :reads; receiver type unknown
  - src/tools/pprof_converter.rb:268 c[:commits]; receiver c; index :commits; receiver type unknown
  - src/tools/pprof_converter.rb:271 c[:addr]; receiver c; index :addr; receiver type unknown
- local hash record l at src/tools/pprof_converter.rb: 16
  - src/tools/pprof_converter.rb:209 l[:acquires]; receiver l; index :acquires; receiver type unknown
  - src/tools/pprof_converter.rb:209 l[:read_acquires]; receiver l; index :read_acquires; receiver type unknown
  - src/tools/pprof_converter.rb:215 l[:addr]; receiver l; index :addr; receiver type unknown
  - src/tools/pprof_converter.rb:215 l[:caller_trace]; receiver l; index :caller_trace; receiver type unknown
  - src/tools/pprof_converter.rb:230 l[:addr]; receiver l; index :addr; receiver type unknown
- hash record return let at src/tools/doctor.rb:1392: 15
  - src/tools/doctor.rb:73 @opts[:ignore]; receiver @opts; index :ignore; receiver type unknown
  - src/tools/doctor.rb:73 @opts[:ignore]; receiver @opts; index :ignore; receiver type unknown
  - src/tools/doctor.rb:74 @opts[:focus]; receiver @opts; index :focus; receiver type unknown
  - src/tools/doctor.rb:75 @opts[:focus]; receiver @opts; index :focus; receiver type unknown
  - src/tools/doctor.rb:80 @opts[:cumulative]; receiver @opts; index :cumulative; receiver type unknown
- local hash record r at src/tools/pprof_converter.rb: 15
  - src/tools/pprof_converter.rb:81 r[:id]; receiver r; index :id; receiver type unknown
  - src/tools/pprof_converter.rb:83 r[:id]; receiver r; index :id; receiver type unknown
  - src/tools/pprof_converter.rb:86 r[:pushes]; receiver r; index :pushes; receiver type unknown
  - src/tools/pprof_converter.rb:86 r[:pops]; receiver r; index :pops; receiver type unknown
  - src/tools/pprof_converter.rb:86 r[:push_blocked]; receiver r; index :push_blocked; receiver type unknown
- local variable args: 15
  - src/annotator/domains/lifetimes.rb:480 args[idx]; receiver args; index idx; receiver type T::Array[`T.untyped`]
  - src/annotator/domains/lifetimes.rb:480 args[idx]; receiver args; index idx; receiver type T::Array[`T.untyped`]
  - src/annotator/domains/lifetimes.rb:510 args[param_index]; receiver args; index param_index; receiver type T::Array[`T.untyped`]
  - src/annotator/helpers/auto_inference.rb:798 args[0]; receiver args; index 0; receiver type T::Array[`T.untyped`]
  - src/ast/std_lib.rb:1031 args[0]; receiver args; index 0; receiver type unknown
- local hash record self at src/mir/cleanup_entry.rb: 13
  - src/mir/cleanup_entry.rb:77 self[:kind]; receiver self; index :kind; receiver type unknown
  - src/mir/cleanup_entry.rb:80 self[:alloc]; receiver self; index :alloc; receiver type unknown
  - src/mir/cleanup_entry.rb:83 self[:scope]; receiver self; index :scope; receiver type unknown
  - src/mir/cleanup_entry.rb:95 self[:needs_cleanup]; receiver self; index :needs_cleanup; receiver type unknown
  - src/mir/cleanup_entry.rb:98 self[:has_moved_guard]; receiver self; index :has_moved_guard; receiver type unknown
- forwarded return split at src/tools/doctor.rb:672: 12
  - src/tools/doctor.rb:674 f[11]; receiver f; index 11; receiver type T::Array[String]
  - src/tools/doctor.rb:677 f[0]; receiver f; index 0; receiver type T::Array[String]
  - src/tools/doctor.rb:677 f[1]; receiver f; index 1; receiver type T::Array[String]
  - src/tools/doctor.rb:677 f[2]; receiver f; index 2; receiver type T::Array[String]
  - src/tools/doctor.rb:678 f[3]; receiver f; index 3; receiver type T::Array[String]
- local hash record e at src/tools/method_rewriter.rb: 12
  - src/tools/method_rewriter.rb:391 e[:start]; receiver e; index :start; receiver type unknown
  - src/tools/method_rewriter.rb:391 e[:len]; receiver e; index :len; receiver type unknown
  - src/tools/method_rewriter.rb:407 e[:start]; receiver e; index :start; receiver type unknown
  - src/tools/method_rewriter.rb:407 e[:start]; receiver e; index :start; receiver type unknown
  - src/tools/method_rewriter.rb:407 e[:len]; receiver e; index :len; receiver type unknown
- local hash record site at src/tools/doctor.rb: 12
  - src/tools/doctor.rb:528 site[:runs]; receiver site; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:528 site[:runs]; receiver site; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:531 site[:dispatch]; receiver site; index :dispatch; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:547 site[:runs]; receiver site; index :runs; receiver type unknown
  - src/tools/doctor.rb:548 site[:id]; receiver site; index :id; receiver type unknown
- local hash record a at src/tools/doctor.rb: 11
  - src/tools/doctor.rb:1472 a[:bytes]; receiver a; index :bytes; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1473 a[:bytes]; receiver a; index :bytes; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1474 a[:allocs]; receiver a; index :allocs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1475 a[:allocs]; receiver a; index :allocs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1545 a[:contended]; receiver a; index :contended; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record b at src/tools/doctor.rb: 11
  - src/tools/doctor.rb:1472 b[:bytes]; receiver b; index :bytes; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1473 b[:bytes]; receiver b; index :bytes; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1474 b[:allocs]; receiver b; index :allocs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1475 b[:allocs]; receiver b; index :allocs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1544 b[:contended]; receiver b; index :contended; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record l at src/tools/doctor.rb: 11
  - src/tools/doctor.rb:721 l[:acquires]; receiver l; index :acquires; receiver type unknown
  - src/tools/doctor.rb:722 l[:read_acquires]; receiver l; index :read_acquires; receiver type unknown
  - src/tools/doctor.rb:726 l[:contended]; receiver l; index :contended; receiver type unknown
  - src/tools/doctor.rb:726 l[:read_contended]; receiver l; index :read_contended; receiver type unknown
  - src/tools/doctor.rb:728 l[:total_hold_ns]; receiver l; index :total_hold_ns; receiver type unknown
- method parameter @tokens (T::Array[Lexer::Token]) at src/ast/parser.rb:90: 11
  - src/ast/parser.rb:137 @tokens[@pos + 1]; receiver @tokens; index @pos + 1; receiver type unknown
  - src/ast/parser.rb:142 @tokens[@pos + n]; receiver @tokens; index @pos + n; receiver type unknown
  - src/ast/parser.rb:559 @tokens[@pos]; receiver @tokens; index @pos; receiver type unknown
  - src/ast/parser.rb:564 @tokens[@pos-1]; receiver @tokens; index @pos-1; receiver type unknown
  - src/ast/parser.rb:615 @tokens[@pos - 1]; receiver @tokens; index @pos - 1; receiver type unknown
- forwarded return let at src/ast/lexer.rb:39: 10
  - src/ast/lexer.rb:113 @s[1]; receiver @s; index 1; receiver type unknown
  - src/ast/lexer.rb:114 @s[1]; receiver @s; index 1; receiver type unknown
  - src/ast/lexer.rb:120 @s[1]; receiver @s; index 1; receiver type unknown
  - src/ast/lexer.rb:121 @s[1]; receiver @s; index 1; receiver type unknown
  - src/ast/lexer.rb:127 @s[1]; receiver @s; index 1; receiver type unknown
- forwarded return split at src/tools/doctor.rb:452: 10
  - src/tools/doctor.rb:453 f[0]; receiver f; index 0; receiver type T::Array[String]
  - src/tools/doctor.rb:455 f[8]; receiver f; index 8; receiver type T::Array[String]
  - src/tools/doctor.rb:460 f[0]; receiver f; index 0; receiver type T::Array[String]
  - src/tools/doctor.rb:461 f[1]; receiver f; index 1; receiver type T::Array[String]
  - src/tools/doctor.rb:462 f[2]; receiver f; index 2; receiver type T::Array[String]
- hash record param h at src/annotator/helpers/intrinsic_registry.rb:141: 10
  - src/annotator/helpers/intrinsic_registry.rb:142 h[:return_type]; receiver h; index :return_type; receiver type unknown
  - src/annotator/helpers/intrinsic_registry.rb:142 h[:return]; receiver h; index :return; receiver type unknown
  - src/annotator/helpers/intrinsic_registry.rb:144 h[:args]; receiver h; index :args; receiver type unknown
  - src/annotator/helpers/intrinsic_registry.rb:148 h[:lifetime]; receiver h; index :lifetime; receiver type unknown
  - src/annotator/helpers/intrinsic_registry.rb:151 h[:validate]; receiver h; index :validate; receiver type unknown
- method parameter source (String) at src/tools/lint_fix_rewriter.rb:285: 10
  - src/tools/lint_fix_rewriter.rb:295 source[cursor]; receiver source; index cursor; receiver type String
  - src/tools/lint_fix_rewriter.rb:295 source[cursor]; receiver source; index cursor; receiver type String
  - src/tools/lint_fix_rewriter.rb:298 source[cursor]; receiver source; index cursor; receiver type String
  - src/tools/lint_fix_rewriter.rb:308 source[i]; receiver source; index i; receiver type String
  - src/tools/lint_fix_rewriter.rb:311 source[i + 1]; receiver source; index i + 1; receiver type String
- local hash record s at src/tools/pprof_converter.rb: 9
  - src/tools/pprof_converter.rb:125 s[:addrs]; receiver s; index :addrs; receiver type unknown
  - src/tools/pprof_converter.rb:143 s[:addrs]; receiver s; index :addrs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/pprof_converter.rb:147 s[:allocs]; receiver s; index :allocs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/pprof_converter.rb:148 s[:bytes]; receiver s; index :bytes; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/pprof_converter.rb:149 s[:allocs]; receiver s; index :allocs; receiver type T::Hash[`T.untyped`, `T.untyped`]
- method parameter @slots (AutoConstraintCollector::SlotMap) at src/annotator/helpers/auto_inference.rb:857: 9
  - src/annotator/helpers/auto_inference.rb:263 @slots[AutoSlotId.param(callee.name, i)]; receiver @slots; index AutoSlotId.param(callee.name, i); receiver type unknown
  - src/annotator/helpers/auto_inference.rb:275 @slots[AutoSlotId.return(current_fn.name)]; receiver @slots; index AutoSlotId.return(current_fn.name); receiver type unknown
  - src/annotator/helpers/auto_inference.rb:314 @slots[slot_id]; receiver @slots; index slot_id; receiver type unknown
  - src/annotator/helpers/auto_inference.rb:343 @slots[entry.key]; receiver @slots; index entry.key; receiver type unknown
  - src/annotator/helpers/auto_inference.rb:344 @slots[entry.value]; receiver @slots; index entry.value; receiver type unknown
- forwarded return split at src/tools/doctor.rb:1521: 8
  - src/tools/doctor.rb:1523 f[0]; receiver f; index 0; receiver type T::Array[String]
  - src/tools/doctor.rb:1524 f[1]; receiver f; index 1; receiver type T::Array[String]
  - src/tools/doctor.rb:1525 f[2]; receiver f; index 2; receiver type T::Array[String]
  - src/tools/doctor.rb:1526 f[3]; receiver f; index 3; receiver type T::Array[String]
  - src/tools/doctor.rb:1527 f[5]; receiver f; index 5; receiver type T::Array[String]
- forwarded return split at src/tools/doctor.rb:916: 8
  - src/tools/doctor.rb:918 f[7]; receiver f; index 7; receiver type T::Array[String]
  - src/tools/doctor.rb:921 f[0]; receiver f; index 0; receiver type T::Array[String]
  - src/tools/doctor.rb:921 f[1]; receiver f; index 1; receiver type T::Array[String]
  - src/tools/doctor.rb:921 f[2]; receiver f; index 2; receiver type T::Array[String]
  - src/tools/doctor.rb:922 f[3]; receiver f; index 3; receiver type T::Array[String]
- hash record hash literal at src/tools/doctor.rb:1165: 8
  - src/tools/doctor.rb:1177 hw['cycles']; receiver hw; index 'cycles'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1178 hw['instructions']; receiver hw; index 'instructions'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1179 hw['branches']; receiver hw; index 'branches'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1180 hw['branch-misses']; receiver hw; index 'branch-misses'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:1183 hw['LLC-loads']; receiver hw; index 'LLC-loads'; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record arm at src/annotator/domains/execution_boundaries.rb: 8
  - src/annotator/domains/execution_boundaries.rb:96 arm[:family]; receiver arm; index :family; receiver type unknown
  - src/annotator/domains/execution_boundaries.rb:99 arm[:body]; receiver arm; index :body; receiver type unknown
  - src/annotator/domains/execution_boundaries.rb:182 arm[:family]; receiver arm; index :family; receiver type unknown
  - src/annotator/domains/execution_boundaries.rb:224 arm[:family]; receiver arm; index :family; receiver type unknown
  - src/annotator/domains/execution_boundaries.rb:480 arm[:family]; receiver arm; index :family; receiver type unknown
- method parameter source (String) at src/ast/syntax_typo_scanner.rb:40: 8
  - src/ast/syntax_typo_scanner.rb:53 source[i, 3]; receiver source; index i; receiver type String
  - src/ast/syntax_typo_scanner.rb:65 source[i]; receiver source; index i; receiver type String
  - src/ast/syntax_typo_scanner.rb:71 source[i]; receiver source; index i; receiver type String
  - src/ast/syntax_typo_scanner.rb:75 source[i]; receiver source; index i; receiver type String
  - src/ast/syntax_typo_scanner.rb:85 source[i]; receiver source; index i; receiver type String
- forwarded return first at src/tools/pprof_converter.rb:60: 7
  - src/tools/pprof_converter.rb:62 f[0]; receiver f; index 0; receiver type unknown
  - src/tools/pprof_converter.rb:63 f[1]; receiver f; index 1; receiver type unknown
  - src/tools/pprof_converter.rb:63 f[2]; receiver f; index 2; receiver type unknown
  - src/tools/pprof_converter.rb:64 f[3]; receiver f; index 3; receiver type unknown
  - src/tools/pprof_converter.rb:64 f[4]; receiver f; index 4; receiver type unknown
- forwarded return split at src/tools/doctor.rb:386: 7
  - src/tools/doctor.rb:389 f[0]; receiver f; index 0; receiver type unknown
  - src/tools/doctor.rb:389 f[1]; receiver f; index 1; receiver type unknown
  - src/tools/doctor.rb:389 f[2]; receiver f; index 2; receiver type unknown
  - src/tools/doctor.rb:390 f[3]; receiver f; index 3; receiver type unknown
  - src/tools/doctor.rb:390 f[4]; receiver f; index 4; receiver type unknown
- hash record hash literal at src/tools/doctor.rb:432: 7
  - src/tools/doctor.rb:477 totals['total_fibers']; receiver totals; index 'total_fibers'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:477 totals['total_fibers']; receiver totals; index 'total_fibers'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:478 totals['total_fibers']; receiver totals; index 'total_fibers'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:479 totals['short_fibers_under_1ms']; receiver totals; index 'short_fibers_under_1ms'; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:480 totals['vshort_fibers_under_10us']; receiver totals; index 'vshort_fibers_under_10us'; receiver type T::Hash[`T.untyped`, `T.untyped`]
- hash record param example at src/lsp/hover.rb:92: 7
  - src/lsp/hover.rb:109 example[:bad]; receiver example; index :bad; receiver type unknown
  - src/lsp/hover.rb:113 example[:bad]; receiver example; index :bad; receiver type unknown
  - src/lsp/hover.rb:116 example[:fix]; receiver example; index :fix; receiver type unknown
  - src/lsp/hover.rb:116 example[:fix]; receiver example; index :fix; receiver type unknown
  - src/lsp/hover.rb:118 example[:fix]; receiver example; index :fix; receiver type unknown
- hash record param m at src/tools/pprof.rb:274: 7
  - src/tools/pprof.rb:275 m[:id]; receiver m; index :id; receiver type unknown
  - src/tools/pprof.rb:276 m[:filename_idx]; receiver m; index :filename_idx; receiver type unknown
  - src/tools/pprof.rb:277 m[:build_id_idx]; receiver m; index :build_id_idx; receiver type unknown
  - src/tools/pprof.rb:277 m[:build_id_idx]; receiver m; index :build_id_idx; receiver type unknown
  - src/tools/pprof.rb:278 m[:has_functions]; receiver m; index :has_functions; receiver type unknown
- hash record param rule at src/ast/syntax_typo_scanner.rb:125: 7
  - src/ast/syntax_typo_scanner.rb:129 rule[:match]; receiver rule; index :match; receiver type unknown
  - src/ast/syntax_typo_scanner.rb:130 rule[:replace]; receiver rule; index :replace; receiver type unknown
  - src/ast/syntax_typo_scanner.rb:131 rule[:label]; receiver rule; index :label; receiver type unknown
  - src/ast/syntax_typo_scanner.rb:135 rule[:match]; receiver rule; index :match; receiver type unknown
  - src/ast/syntax_typo_scanner.rb:136 rule[:replace]; receiver rule; index :replace; receiver type unknown
- hash record return [] at src/mir/test_lowering.rb:327: 7
  - src/mir/test_lowering.rb:337 stub_info[:kind]; receiver stub_info; index :kind; receiver type unknown
  - src/mir/test_lowering.rb:339 stub_info[:var]; receiver stub_info; index :var; receiver type unknown
  - src/mir/test_lowering.rb:342 stub_info[:var]; receiver stub_info; index :var; receiver type unknown
  - src/mir/test_lowering.rb:345 stub_info[:var]; receiver stub_info; index :var; receiver type unknown
  - src/mir/test_lowering.rb:352 stub_info[:var]; receiver stub_info; index :var; receiver type unknown

## Tuple-Like Array Report
- tuple-like array: an array literal whose position-specific element types look meaningful enough to model as a tuple/record
- confidence: `high` means the static shape is regular enough for a likely-safe tuple type; `review` means the shape is useful but needs human inspection
- Tuple-like array literals: 270
- Runtime-observed tuple-like array slots: 315

### Runtime Tuple-Like Array Slots
- src/ast/parser.rb:3928 return parse_comma_seq; [Lexer::Token, Array]; 42912 call(s); complete, mixed, size 2
- src/ast/parser.rb:496 param pattern; [String, Symbol, Hash, String]; 15945 call(s); complete, mixed, size 4
- src/tools/lint_fix_rewriter.rb:198 param edits; [Hash, Hash]; 15094 call(s); complete, size 2
- src/ast/parser.rb:496 return process_pattern; [AST::BinaryOp, String]; 13237 call(s); complete, mixed, size 2
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 10236 call(s); complete, mixed, size 4
- src/tools/lint_fix_rewriter.rb:198 param edits; [Hash, Hash, Hash]; 10059 call(s); complete, size 3
- src/ast/parser.rb:1647 return parse_effects_decl; [NilClass, NilClass]; 7894 call(s); complete, size 2
- src/mir/hoist.rb:990 return normalize_allocating_used_expr; [Array, MIR::Lit]; 7185 call(s); complete, mixed, size 2
- src/tools/lint_fix_rewriter.rb:198 param edits; [Hash, Hash, Hash, Hash]; 6700 call(s); complete, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 6516 call(s); complete, mixed, size 4
- src/ast/parser.rb:3928 return parse_comma_seq; [Lexer::Token, Array]; 6219 call(s); complete, mixed, size 2
- src/mir/hoist.rb:990 return normalize_allocating_used_expr; [Array, MIR::Ident]; 5067 call(s); complete, mixed, size 2
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 5038 call(s); complete, mixed, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 4642 call(s); complete, mixed, size 4
- src/tools/lint_fix_rewriter.rb:198 param edits; [Hash, Hash, Hash, Hash, Hash]; 4345 call(s); complete, size 5
- src/ast/parser.rb:3928 return parse_comma_seq; [Lexer::Token, Array]; 4340 call(s); complete, mixed, size 2
- src/ast/parser.rb:496 param pattern; [String, Symbol]; 4297 call(s); complete, mixed, size 2
- src/ast/ast.rb:680 return expression_children; [AST::Literal, AST::Literal, AST::Literal]; 3864 call(s); complete, size 3
- src/mir/hoist.rb:990 return normalize_allocating_used_expr; [Array, MIR::Ident]; 3819 call(s); complete, mixed, size 2
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 3800 call(s); complete, mixed, size 4
- src/tools/method_rewriter.rb:141 param edits; [Hash, Hash]; 3718 call(s); complete, size 2
- src/tools/lint_fix_rewriter.rb:198 param edits; [Hash, Hash, Hash, Hash, Hash, Hash]; 3525 call(s); complete, size 6
- src/mir/hoist.rb:990 return normalize_allocating_used_expr; [Array, MIR::Ident]; 3485 call(s); complete, mixed, size 2
- src/mir/hoist.rb:990 return normalize_allocating_used_expr; [Array, MIR::Ident]; 3242 call(s); complete, mixed, size 2
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, Float, Integer, Integer]; 3188 call(s); complete, mixed, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Lexer::Token, Symbol, Float, Symbol]; 3156 call(s); complete, mixed, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 3052 call(s); complete, mixed, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 2920 call(s); complete, mixed, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 2910 call(s); complete, mixed, size 4
- src/mir/hoist.rb:256 return non_body_exprs; [Symbol, String, Integer, Integer]; 2900 call(s); complete, mixed, size 4
- [String, Symbol] appears 27 time(s), confidence high; first site src/ast/parser.rb:230
- [MIR::Let, MIR::ForStmt, MIR::BreakStmt] appears 13 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:503
- [T::Boolean, OwnershipEffect] appears 11 time(s), confidence review; first site src/mir/mir.rb:527
- [MIR::Let, MIR::IfStmt] appears 10 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:228
- [MIR::Set, MIR::BreakStmt] appears 9 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:249
- [Symbol, Integer] appears 7 time(s), confidence high; first site src/tools/predicate_rewriter.rb:236
- [Symbol, T::Hash[`T.untyped`, `T.untyped`]] appears 7 time(s), confidence review; first site src/ast/parser.rb:1662
- [MIR::AllocatorRef, MIR::Ident] appears 7 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_batch_window_lowerer.rb:337
- [Symbol, T.nilable(String)] appears 6 time(s), confidence high; first site src/ast/parser.rb:73
- [MIR::FieldGet, MIR::Lit] appears 6 time(s), confidence review; first site src/annotator/helpers/auto_inference.rb:947
- [MIR::ExprStmt, MIR::ReturnStmt] appears 6 time(s), confidence review; first site src/mir/lowering/capabilities.rb:854
- [T::Boolean, NilClass] appears 5 time(s), confidence review; first site src/ast/error_registry.rb:137
- [MIR::Let, MIR::WhileStmt] appears 5 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_list_lowerer.rb:311
- [MIR::Let, MIR::DeferStmt, MIR::ForStmt, MIR::Let] appears 5 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_materializer.rb:452
- [MIR::Let, MIR::ExprStmt] appears 5 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_set_index_lowerer.rb:70
- [String, Integer] appears 4 time(s), confidence high; first site src/mir/lower/pipeline/pipeline_batch_window_lowerer.rb:48
- [MIR::Set, MIR::Set, MIR::BreakStmt] appears 4 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb:270
- [Symbol, String] appears 3 time(s), confidence high; first site src/ast/parser.rb:57
- [MIR::Let, MIR::Let, MIR::ForStmt, MIR::BreakStmt] appears 3 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_list_lowerer.rb:434
- [MIR::Let, MIR::Suppress] appears 3 time(s), confidence review; first site src/mir/lowering/capabilities.rb:303
- [MIR::EnumTag, MIR::EnumOrdinal, MIR::Lit, MIR::Lit] appears 3 time(s), confidence review; first site src/mir/lowering/capabilities.rb:801
- [String, T::Array[`T.untyped`]] appears 3 time(s), confidence review; first site src/mir/lowering/expressions.rb:1922
- [AST::Assignment, AST::BreakNode] appears 3 time(s), confidence review; first site src/mir/rewriters/pipeline_rewriter.rb:618
- [CoerceTypeInput, NilClass] appears 2 time(s), confidence high; first site src/ast/ast.rb:1049
- [T::Array[`T.untyped`], T.nilable(Lexer::Token)] appears 2 time(s), confidence high; first site src/ast/parser.rb:2551
- [T.class_of(Symbol), T.class_of(String), T.class_of(Numeric), T.class_of(TrueClass), T.class_of(FalseClass), T.class_of(NilClass)] appears 2 time(s), confidence high; first site src/mir/pre_mir_type_check.rb:28
- [NilClass, Integer] appears 2 time(s), confidence high; first site src/tools/doctor.rb:553
- [String, String, T.nilable(String), NilClass, String] appears 2 time(s), confidence review; first site src/backends/fsm_wrapper_emitter.rb:113
- [MIR::ExprStmt, MIR::Set] appears 2 time(s), confidence review; first site src/mir/fsm_lowering.rb:524
- [MIR::Set, MIR::ExprStmt] appears 2 time(s), confidence review; first site src/mir/fsm_transform/emit.rb:459
- [T::Array[`T.untyped`], T::Hash[`T.untyped`, `T.untyped`]] appears 2 time(s), confidence review; first site src/mir/fsm_transform/recursive_splitter.rb:583
- [MIR::Let, MIR::DeferStmt] appears 2 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1263
- [MIR::Let, MIR::Let, MIR::ForStmt] appears 2 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_each_lowerer.rb:219
- [MIR::Ident, MIR::ListLength] appears 2 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_list_lowerer.rb:178
- [MIR::TypeOf, MIR::AllocatorRef, MIR::AddressOf] appears 2 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_range_lowerer.rb:884
- [MIR::IfStmt, MIR::Let, MIR::ForStmt, MIR::BreakStmt] appears 2 time(s), confidence review; first site src/mir/lower/pipeline/pipeline_scalar_lowerer.rb:115
- [AST::Assignment, AST::IfStatement] appears 2 time(s), confidence review; first site src/mir/rewriters/pipeline_rewriter.rb:553
- [String, String, T.nilable(String), String] appears 2 time(s), confidence review; first site src/tools/doctor.rb:165
- [T.nilable(Type), NilClass] appears 1 time(s), confidence high; first site src/ast/ast.rb:1041
- [NilClass, String] appears 1 time(s), confidence high; first site src/ast/ast.rb:1753
- [T.nilable(String), T.nilable(Type)] appears 1 time(s), confidence high; first site src/ast/parser.rb:1236
- [Symbol, NilClass] appears 1 time(s), confidence high; first site src/ast/parser.rb:2475
- [T.nilable(String), NilClass] appears 1 time(s), confidence high; first site src/backends/mir_emitter.rb:1736
- [T::Array[`T.untyped`], MIR::Ident] appears 1 time(s), confidence high; first site src/mir/hoist.rb:756
- [T::Array[MIR::Node], MIR::Ident] appears 1 time(s), confidence high; first site src/mir/hoist.rb:801
- [T::Array[T.any(`T.untyped`, `T.untyped`)], T.nilable(T::Array[`T.untyped`])] appears 1 time(s), confidence high; first site src/mir/hoist.rb:914
- [T.class_of(InlineBc), T.class_of(ShardedMapPut), T.class_of(ShardedMapGet)] appears 1 time(s), confidence high; first site src/mir/mir.rb:4794
- [MIR::ScopeBlock, T::Boolean] appears 1 time(s), confidence high; first site src/mir/mir_lowering.rb:1354
- [T::Array[AST::Node], AST::ReturnNode, CleanupClassifier::FrozenCleanupFacts, T.nilable(AST::FunctionDef)] appears 1 time(s), confidence high; first site src/mir/mir_pass.rb:824
- [AllocMarkPlan, CleanupPlan] appears 1 time(s), confidence high; first site src/semantic/capture_strategy.rb:100
