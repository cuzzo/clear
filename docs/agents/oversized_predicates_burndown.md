# Oversized Predicates Burndown

## Metric Scope

Decomplex now reports boolean predicates with more than three condition atoms only when they appear in control-flow predicates (`if`, `while`, `until`). Predicate helper implementations whose method name ends in `?` are intentionally skipped so the report points at callers that have not reified a rule.

## Snapshot

- Initial detector run before helper suppression: 118 findings.
- Current detector run after burndown: 11 findings.
- Reduction: 107 findings, 90.7%.

## Groups Addressed

### AST Shape Families

Repeated `is_a?` chains were moved behind AST helpers:

- `AST.type_declaration?`
- `AST.top_level_declaration?`
- `AST.statement_result_void?`
- `AST.ownership_transfer_stmt?`
- `AST.ownership_wrapper?`
- `AST.call_like_boundary?`
- `AST.collection_method_call?`
- `AST.any_set_insert_call?`
- `AST.empty_auto_collection_literal_decl?`
- `AST.negative_integer_literal?`
- `AST.declaration_with_identifier_value?`
- `AST.declaration_with_heap_symbol?`

These replaced repeated membership predicates in annotator, MIR lowering, escape analysis, hoisting, method analysis, parser, and MIR pass code.

### Type Shape Families

Repeated Type predicate clusters were consolidated into named Type predicates:

- `runtime_stream?`
- `bounded_pipeline_stream_source?`
- `single_future?`
- `scalar_slot?`
- `heap_cleanup_allocator?`
- `heap_return_storage?`
- `shared_or_multiowned?`
- `rc_map?`
- `plain_numeric_map?`
- `list_requires_array_shape?`
- `observable_array_without_set?`
- `soa_requires_fixed_array?`
- `soa_list_materialization?`
- `dynamic_field_array?`
- `borrowed_array_argument?`
- `string_comparable_with?`
- `sync_requires_heap_provenance?`
- `atomic_pointer_wrapped?`
- `plain_indirect_value?`

These replaced stream-family checks, promise cleanup checks, collection-shape validation, RC map deref checks, numeric map variant selection, cleanup allocator predicates, and Zig type wrapper predicates.

### Symbol And Ownership Facts

Repeated SymbolEntry and ownership graph state checks were reified as:

- `SymbolEntry#boxed_capture_storage?`
- `SymbolEntry#affine_locked_capture?`
- `SymbolEntry#with_match_capability_family?`
- `SymbolEntry#plain_local_family?`
- `SymbolEntry#capture_move_required?`
- `OwnershipGraph::Node#specific_move_action?`
- `OwnedSinkSourceFact#satisfies_rc_sink?`

These were used in bounded concurrent capture lowering, with-match checking, universal-poly borrow checks, capture move recording, and ownership sink planning.

### MIR Local Contracts

One-off MIR invariants that were still real named rules were extracted:

- `MIR.const_u8_literal_cast?`
- `MIR.expr_wrapper?`
- `runtime_frame_save_required?`
- `owned_slice_argument_required?`
- `borrowed_array_argument_required?`
- `atomic_capture_load?`
- `recursive_field_copy_required?`
- `visible_owned_operand_value?`
- `zig_statement_semicolon_required?`
- `i64_range_capture_cast_required?`
- `semicolon_required?`
- `stdlib_owned_fixed_return?`
- `ast_node_needs_runtime?`

### Procedural Cleanup

Some oversized predicates were not missing abstractions. They were procedural flow with too much work in one `if`; those were split into guard clauses or nested checks. Notable example: return type validation now computes one `return_checkable` gate instead of repeating four exclusion checks.

## Remaining Offenders

The remaining 11 are all scanner-style predicates in `src/tools`:

- `src/tools/formatter.rb`: token boundary checks in match arm and block expansion scanners.
- `src/tools/lint_fix_rewriter.rb`: assignment span boundary detection.
- `src/tools/method_rewriter.rb`: call rewrite eligibility.
- `src/tools/predicate_rewriter.rb`: parenthesis and expression-end scanning.
- `src/tools/stack_verifier.rb`: assembly frame-size extraction and depth metadata checks.

These are lower ROI than the compiler/annotator/MIR hits because they are localized text/assembly scanners. They can be cleaned up later with small lexical helper predicates if the report needs to go to zero.
