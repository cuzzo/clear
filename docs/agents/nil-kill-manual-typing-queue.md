# Nil-Kill Manual Typing Queue

Status: active

This queue ranks manual compiler annotations by the number of currently
unresolved FactMine DFG facts that the annotation would make resolvable. The
counts are a conservative lower bound, not a claim that every ranked root has
one sound concrete type. Every annotation still requires source review,
Sorbet, compiler tests, and a fresh Nil-Kill collect/infer cycle.

## Scope and baseline

Before the first batch, the compiler inventory (excluding
`compiler/ruby/tools`) contained 16,471 signature/field/collection slots:

- 15,769 strong
- 274 weak
- 428 untyped
- 91 unresolved parameter-origin DFG roots collectively blocked 203 distinct
  downstream facts
- a greedy set-cover over those facts required 51 annotations to cover 163
  facts (80% of 203)

The 203 facts are only the portion of the DFG whose missing type is both
connected to one of these roots and definitely unlockable. They are not all
428 untyped slots.

## Batch 1 — completed

- [x] `GenericAnalysis#find_container_source(expr)`
- [x] `LSP::Hover.build_markdown(entry)`
- [x] `LSP::Hover.build_markdown(example)`
- [x] `DiagnosticExamples` example-record fields
- [x] `UnionAnalysis#validate_union_schema!(schema)`
- [x] `DiagnosticRegistry.format_template(kwargs)`
- [x] `MIRHoistLowering#replace_mir_expr_in_value!(new_child)`
- [x] `MIRLowering#materialize_statement_discard(stmt)`
- [x] `MethodAnalysis#narrow_collection_type!(args)`
- [x] `PipeAnalysis#emit_multi_map_warning(sharded_names)`
- [x] `ConcurrencyChecks.collect_held_params(with_block, fn)`

Fresh collection results after this batch:

- 15,784 strong (+15)
- 274 weak (unchanged)
- 413 untyped (-15)
- 78 unresolved parameter-origin roots (-13)
- 147 collectively unlockable facts (-56)
- 49 further annotations cover 118 facts (80% of the remaining 147)
- Auto-Type has no additional safe action to apply automatically

All 6,414 compiler unit examples, 303 fuzz cells, examples, build checks,
module integration, and FFI integration passed.

## Remaining 80% queue

Order is greedy marginal coverage. A high rank means “review this first,” not
“blindly replace `T.untyped`.” In particular, registry adapters and recursive
value walkers may intentionally accept a real union of shapes.

- [ ] 1. `compiler/ruby/annotator/helpers/function_signature.rb:703` — `FunctionSignature#sync_from_function_def!(fn)`; 22 facts
- [ ] 2. `compiler/ruby/mir/fsm_transform.rb:66` — `FsmTransform.transform(ctx)`; 6 facts
- [ ] 3. `compiler/ruby/mir/hoist.rb:1134` — `MIRHoistLowering#replace_mir_expr_in_value!(value)`; 6 facts
- [ ] 4. `compiler/ruby/annotator/helpers/intrinsic_registry.rb:503` — `IntrinsicRegistry.fs(x)`; 5 facts
- [ ] 5. `compiler/ruby/annotator/domains/errors.rb:351` — `emit_error_type_conflict!(conflict)`; 4 facts
- [ ] 6. `compiler/ruby/mir/fsm_transform.rb:66` — `FsmTransform.transform(bg_block)`; 4 facts
- [ ] 7. `compiler/ruby/mir/mir_lowering.rb:1598` — `materialize_statement_discard(mir)`; 4 facts
- [ ] 8. `compiler/ruby/mir/thunk_transform/emit.rb:104` — `build_trampoline(lowering)`; 4 facts
- [ ] 9. `compiler/ruby/annotator/helpers/fixable_helpers.rb:1369` — `build_decl_cap_insert_fix(name)`; 3 facts
- [ ] 10. `compiler/ruby/annotator/helpers/fixable_helpers.rb:1369` — `build_decl_cap_insert_fix(sigil)`; 3 facts
- [ ] 11. `compiler/ruby/annotator/helpers/method_analysis.rb:72` — `resolve_typed_method(registry)`; 3 facts
- [ ] 12. `compiler/ruby/ast/diagnostic_registry.rb:3238` — `format_template(args)`; 3 facts
- [ ] 13. `compiler/ruby/mir/lowering/concurrency.rb:1018` — `fsm_bg_block_from_transform!(transform_result)`; 3 facts
- [ ] 14. `compiler/ruby/annotator/domains/control_flow.rb:394` — `with_comptime_is_a_then_refinement(blk)`; 2 facts
- [ ] 15. `compiler/ruby/annotator/helpers/auto_inference.rb:841` — `record_map_pair_evidence(args)`; 2 facts
- [ ] 16. `compiler/ruby/annotator/helpers/with_match_check.rb:344` — `family_of_arg_set(arg)`; 2 facts
- [ ] 17. `compiler/ruby/ast/diagnostic_examples.rb:147` — `find_block_end(lines)`; 2 facts
- [ ] 18. `compiler/ruby/ast/syntax_typo_scanner.rb:125` — `emit_typo_finding!(rule)`; 2 facts
- [ ] 19. `compiler/ruby/lsp/hover.rb:151` — `header_line(entry)`; 2 facts
- [ ] 20. `compiler/ruby/mir/fsm_transform.rb:66` — `FsmTransform.transform(lowering)`; 2 facts
- [ ] 21. `compiler/ruby/mir/fsm_transform/suspend_resolvers.rb:54` — `resolve_io(lowering)`; 2 facts
- [ ] 22. `compiler/ruby/mir/fsm_transform/suspend_resolvers.rb:153` — `resolve_next(lowering)`; 2 facts
- [ ] 23. `compiler/ruby/mir/mir_lowering.rb:1315` — `stack_fixed_array_coercion?(node)`; 2 facts
- [ ] 24. `compiler/ruby/mir/thunk_transform/emit.rb:353` — `build_mutual_arm(lowering)`; 2 facts
- [ ] 25. `compiler/ruby/mir/thunk_transform/emit.rb:316` — `build_mutual_trampoline(lowering)`; 2 facts
- [ ] 26. `compiler/ruby/annotator/annotator.rb:271` — `with_comptime_type_param_refinement(blk)`; 1 fact
- [ ] 27. `compiler/ruby/annotator/helpers/capabilities.rb:43` — `Capabilities.validate!(error_handler)`; 1 fact
- [ ] 28. `compiler/ruby/annotator/helpers/capabilities.rb:1110` — `with_fiber_capture_analysis(blk)`; 1 fact
- [ ] 29. `compiler/ruby/annotator/helpers/capabilities.rb:1247` — `without_capture_moves(blk)`; 1 fact
- [ ] 30. `compiler/ruby/annotator/helpers/fixable_helpers.rb:1369` — `build_decl_cap_insert_fix(confidence)`; 1 fact
- [ ] 31. `compiler/ruby/annotator/helpers/fixable_helpers.rb:1369` — `build_decl_cap_insert_fix(description_code)`; 1 fact
- [ ] 32. `compiler/ruby/annotator/helpers/fixable_helpers.rb:1369` — `build_decl_cap_insert_fix(description_params)`; 1 fact
- [ ] 33. `compiler/ruby/annotator/helpers/function_signature.rb:375` — `sync_signature_from_function_def!(fn)`; 1 fact
- [ ] 34. `compiler/ruby/annotator/helpers/intrinsic_registry.rb:113` — `assign_emit_value(value)`; 1 fact
- [ ] 35. `compiler/ruby/annotator/helpers/pipe_analysis.rb:147` — `lift_to_observable_if_terminal!(type_kwargs)`; 1 fact
- [ ] 36. `compiler/ruby/annotator/helpers/pipe_analysis.rb:166` — `mark_observable_terminal!(type_kwargs)`; 1 fact
- [ ] 37. `compiler/ruby/annotator/helpers/with_match_check.rb:304` — `family_of_arg(arg)`; 1 fact
- [ ] 38. `compiler/ruby/ast/ast.rb:882` — `AST.each_capture_analysis(block)`; 1 fact
- [ ] 39. `compiler/ruby/ast/ast.rb:897` — `AST.expr_each_concurrent_capture(block)`; 1 fact
- [ ] 40. `compiler/ruby/ast/diagnostic_examples.rb:171` — `extract_first_heredoc_in_it(block_lines)`; 1 fact
- [ ] 41. `compiler/ruby/ast/diagnostic_registry.rb:3225` — `format(args)`; 1 fact
- [ ] 42. `compiler/ruby/ast/diagnostic_registry.rb:3225` — `format(kwargs)`; 1 fact
- [ ] 43. `compiler/ruby/ast/diagnostic_registry.rb:3230` — `format_from_hash(args)`; 1 fact
- [ ] 44. `compiler/ruby/ast/diagnostic_registry.rb:3230` — `format_from_hash(kwargs)`; 1 fact
- [ ] 45. `compiler/ruby/ast/diagnostic_registry.rb:3317` — `missing_named_template_key(kwargs)`; 1 fact
- [ ] 46. `compiler/ruby/ast/diagnostic_registry.rb:3251` — `named_template_args_complete?(kwargs)`; 1 fact
- [ ] 47. `compiler/ruby/ast/diagnostic_registry.rb:3280` — `positional_template_args_complete?(args)`; 1 fact
- [ ] 48. `compiler/ruby/ast/parser_rules.rb:33` — `ClearParser.rule(inject)`; 1 fact
- [ ] 49. `compiler/ruby/ast/scope.rb:503` — `with_new_scope(blk)`; 1 fact

Refresh this order after each batch; earlier annotations can make later roots
disappear or expose a more valuable transitive path.

## Xit migration — completed

The 82 historical `xit` examples were audited against the current public
FactMine/Rust inference pipeline:

- one fallibility-pressure regression described a still-supported public
  invariant; it was reactivated and the missing orchestration restored;
- 81 examples asserted private methods from the deleted Ruby inference engine
  and were removed rather than reviving a second inference path;
- their supported behavior is covered through Rust action matrices and Ruby
  public-pipeline regressions for runtime contradictions, protocol backflow,
  forwarded returns, generic collection shapes, hash-record reporting, and
  focus output;
- the skipped uninstrumented-collect negative control was reactivated. The
  report now validates every executed trace-plan-selected method before an
  inferred action can hide its missing runtime record.

There are no `xit` declarations in the Nil-Kill suite.
