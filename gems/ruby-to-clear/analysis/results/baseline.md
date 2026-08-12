# True Clean Transpilation Report

- revision: `630b27f329ee0ffed358b454f3f52b27ac9d8aa7`
- manifest: `d58de02b2774713ac7ca609b6055a2d778c61ad912537f95b347a065a2f7a8dc`
- corpus: 188 files, 108721 nonblank Ruby source LoC
- artifacts: `tmp/ruby-to-clear-verify/630b27f329ee-d58de02b2774`

## Gates

| Gate | Files | File % | Source LoC | LoC % | Unknown |
| --- | ---: | ---: | ---: | ---: | ---: |
| G0 | 188/188 | 100.00% | 108721/108721 | 100.00% | 0 |
| G1 | 171/188 | 90.96% | 89283/108721 | 82.12% | 0 |
| G2 | 113/188 | 60.11% | 47456/108721 | 43.65% | 1 |
| G3 | 12/188 | 6.38% | 2077/108721 | 1.91% | 1 |
| G4 | 11/188 | 5.85% | 2036/108721 | 1.87% | 0 |

Clean transpilation means raw G1-G4 success. Autofix-assisted results are separate.

- raw build-clean files: 11
- autofix-assisted build-clean files: 0
- autofix completed files: 0/0 (0 fixer crashes)
- autofix changed files: 0
- behavior oracles: 0/0 configured units verified

## Failure Codes

- `C0`: 10
- `C2`: 100
- `C3`: 1
- `C4`: 1
- `T0`: 17
- `Z0`: 1
- blocked by a failed generated dependency: 47

## Top Failure Fingerprints

- 97 x `C2`: [Compiler Error] [ARGUMENT_TYPE_ERROR] Type Error: Function 'Expression' argument <n> expects TypeConstructionInput, got TypeTypeInput
- 4 x `C0`: [Parser Error] [UNEXPECTED_TOKEN_LINE] Unexpected token RETURN (KEYWORD) line <n>
- 3 x `C0`: s no implicit future flattening because that would hide an additional scheduling and ownership boundary.", :fix_hint: "Use NEXT explicitly inside a BG block, or return a non-future member from the navigation."}, :TENSE_NAVIGATION_MUTATION: 
- 3 x `T0`: Error: Unsupported Ruby syntax: Complex exception handling (rescue) is not supported at line <n>:<n>
- 3 x `T0`: Error: Unsupported Ruby syntax: gsub with block or invalid arguments is not supported at line <n>:<n>
- 2 x `T0`: Error: Unsupported Ruby syntax: is_a? requires a static type argument at line <n>:<n>
- 1 x `T0`: ?? ??? ??? ??? ??? ??? ??? ??? ????????? statements:
- 1 x `T0`: Error: Unsupported Ruby syntax: Keyword arguments are not supported for this constructor at line <n>:<n>
- 1 x `C0`: tegory: :type, :template: "Type Error: Cannot access field '%{field}' on optional '%{type}' without safe navigation.", :summary: "Field access on an optional value requires `?.` so NIL propagates safely.", :cause: "An indexed @list read and
- 1 x `C4`: [Compiler Error] [INTRINSIC_NO_OVERLOAD] No overload for 'last' matches arguments (Tuple<String@symbol,Int64>).
- 1 x `Z0`: error: string literal contains invalid byte: '\x01'
- 1 x `T0`: ????????? equal_loc: ???
- 1 x `C2`: [Compiler Error] [IF_EXPR_RESULT_NOT_COPYABLE] IF expression result type '?String' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-IF with RETURN for heap-allocated values.
- 1 x `T0`: Error: Unsupported Ruby syntax: force_encoding is only translatable for Encoding::UTF_8; CLEAR strings do not carry mutable encoding tags at line <n>:<n>
- 1 x `T0`: Error: Unsupported Ruby syntax: each_with_index requires a statically typed collection at line <n>:<n>
- 1 x `C0`: [Parser Error] [PARSER_EXPECTED] Expected END, got ; (CHAR) line <n>
- 1 x `C2`: [Compiler Error] [IS_A_RUNTIME_NEEDS_UNION] Runtime IS_A requires a union-typed value on the left, got Any.
- 1 x `T0`: Error: Unsupported Ruby syntax: const_get is a Ruby dynamic/reflection call: dynamic constant lookup; replace with an explicit registry map at line <n>:<n>
- 1 x `T0`: Error: Unsupported Ruby syntax: map! block contains unsupported EnsureNode at line <n>:<n>
- 1 x `C0`: [Parser Error] [PARSER_EXPECTED] Expected END, got = (CHAR) line <n>

## Observed Diagnostic Inventory

- observed instances: 177
- unique clusters: 31
- affected roots: 177
- limitation: Counts include diagnostics emitted before each compiler process stopped; fail-fast errors can hide additional latent diagnostics.

| Category | Instances | Unique clusters | Affected roots |
| --- | ---: | ---: | ---: |
| type_system | 100 | 4 | 100 |
| dependency | 47 | 7 | 47 |
| unsupported_ruby | 17 | 12 | 17 |
| clear_syntax | 10 | 5 | 10 |
| backend | 1 | 1 | 1 |
| compiler_internal | 1 | 1 | 1 |
| ownership_lifetime | 1 | 1 | 1 |

### Highest-Impact Clusters

- 97 roots / 97 instances, `type_system`: [Compiler Error] [ARGUMENT_TYPE_ERROR] Type Error: Function 'Expression' argument <n> expects TypeConstructionInput, got TypeTypeInput
- 23 roots / 23 instances, `dependency`: missing generated dependency: semantic/lifecycle_plan.clear
- 14 roots / 14 instances, `dependency`: missing generated dependency: annotator/phases/resolution_phase.clear
- 4 roots / 4 instances, `clear_syntax`: [Parser Error] [UNEXPECTED_TOKEN_LINE] Unexpected token RETURN (KEYWORD) line <n>
- 3 roots / 3 instances, `clear_syntax`: s no implicit future flattening because that would hide an additional scheduling and ownership boundary.", :fix_hint: "Use NEXT explicitly inside a BG block, or return a non-future member from the navigation."}, :TENSE_NAVIGATION_MUTATION: {:severity: :error, :category: :ownership, :template: "Tense
- 3 roots / 3 instances, `dependency`: missing generated dependency: semantic/tense_operation_plan.clear
- 3 roots / 3 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: Complex exception handling (rescue) is not supported at line <n>:<n>
- 3 roots / 3 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: gsub with block or invalid arguments is not supported at line <n>:<n>
- 2 roots / 2 instances, `dependency`: missing generated dependency: backends/mir_emitter.clear
- 2 roots / 2 instances, `dependency`: missing generated dependency: mir/mir_lowering.clear
- 2 roots / 2 instances, `dependency`: missing generated dependency: semantic/escape_analysis.clear
- 2 roots / 2 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: is_a? requires a static type argument at line <n>:<n>
- 1 roots / 1 instances, `backend`: error: string literal contains invalid byte: '\x01'
- 1 roots / 1 instances, `clear_syntax` at `mir/fsm_transform/segments.clear:273`: [Parser Error] [PARSER_EXPECTED] Expected END, got ; (CHAR) line <n>
- 1 roots / 1 instances, `clear_syntax` at `mir/rewriters/string_concat_rewriter.clear:63`: [Parser Error] [PARSER_EXPECTED] Expected END, got = (CHAR) line <n>
- 1 roots / 1 instances, `clear_syntax`: tegory: :type, :template: "Type Error: Cannot access field '%{field}' on optional '%{type}' without safe navigation.", :summary: "Field access on an optional value requires `?.` so NIL propagates safely.", :cause: "An indexed @list read and every other optional expression may be NIL. Plain `.` would
- 1 roots / 1 instances, `compiler_internal` at `ast/error_registry.clear:66`: [Compiler Error] [INTRINSIC_NO_OVERLOAD] No overload for 'last' matches arguments (Tuple<String@symbol,Int64>).
- 1 roots / 1 instances, `dependency`: missing generated dependency: incremental/source_catalog.clear
- 1 roots / 1 instances, `ownership_lifetime` at `semantic/effect_set.clear:68`: [Compiler Error] [TYPO_SUGGESTION_REJECTED] Unknown method 'hash' on Set<String>. Available: insert, contains?, remove, length, empty?, any?
- 1 roots / 1 instances, `type_system` at `semantic/ownership_edge_planner.clear:16`: [Compiler Error] [FIELD_TYPE_MISMATCH] Field 'op' expected ?String, got String
- 1 roots / 1 instances, `type_system` at `incremental/dependency_snapshot.clear:27`: [Compiler Error] [IF_EXPR_RESULT_NOT_COPYABLE] IF expression result type '?String' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-IF with RETURN for heap-allocated values.
- 1 roots / 1 instances, `type_system` at `mir/lowering/counters.clear:8`: [Compiler Error] [IS_A_RUNTIME_NEEDS_UNION] Runtime IS_A requires a union-typed value on the left, got Any.
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: Keyword arguments are not supported for this constructor at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: const_get is a Ruby dynamic/reflection call: dynamic constant lookup; replace with an explicit registry map at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: each_with_index requires a statically typed collection at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: fetch fallback blocks must contain one parameterless expression at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: force_encoding is only translatable for Encoding::UTF_8; CLEAR strings do not carry mutable encoding tags at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: map! block contains unsupported EnsureNode at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: Error: Unsupported Ruby syntax: reverse_each without a block is not supported at line <n>:<n>
- 1 roots / 1 instances, `unsupported_ruby`: ?? ??? ??? ??? ??? ??? ??? ??? ????????? statements:

## Units

| Unit | LoC | G1 | G2 | G3 | G4 | Failure | Autofix G4 |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `compiler/ruby/annotator.rb` | 2 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/annotator.rb` | 96 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/domains/control_flow.rb` | 1206 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/domains/destructuring.rb` | 135 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/domains/errors.rb` | 687 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/domains/execution_boundaries.rb` | 927 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/domains/expressions.rb` | 680 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/domains/lifetimes.rb` | 1314 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/domains/member_access.rb` | 676 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/domains/variables.rb` | 1184 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/function_registry.rb` | 49 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/auto_inference.rb` | 908 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/helpers/capabilities.rb` | 1354 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/effects.rb` | 1277 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/fixable_helpers.rb` | 2067 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/function_analysis.rb` | 1600 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/helpers/function_context.rb` | 88 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/function_return.rb` | 188 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/function_signature.rb` | 730 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/function_signature_returns.rb` | 71 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/generic_analysis.rb` | 1006 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/intrinsic_arg_spec.rb` | 89 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/annotator/helpers/intrinsic_contract.rb` | 174 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/intrinsic_emit.rb` | 90 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/annotator/helpers/intrinsic_registry.rb` | 550 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/lock_helper.rb` | 446 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/method_analysis.rb` | 296 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/helpers/pipe_analysis.rb` | 1859 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/helpers/prefixed_int_range.rb` | 79 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/recoverable_result.rb` | 35 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/reentrance.rb` | 800 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/test_annotation.rb` | 177 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/helpers/union.rb` | 165 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/helpers/with_match_check.rb` | 414 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/phases/annotation_boundary.rb` | 36 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/annotation_pipeline.rb` | 66 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/annotation_products.rb` | 220 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/auto_finalization.rb` | 180 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/phases/body_analysis.rb` | 509 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/builtin_environment.rb` | 30 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/capability_audit_phase.rb` | 42 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/capability_audit_session.rb` | 138 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/capability_evidence.rb` | 77 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/conformance_registration.rb` | 242 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/conformance_validation.rb` | 90 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/declaration_index.rb` | 100 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/deferred_validation.rb` | 127 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/phases/derived_program_facts.rb` | 112 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/expression_domains.rb` | 594 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/annotator/phases/implementation_registration.rb` | 220 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/import_resolution.rb` | 202 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/phase_handoffs.rb` | 22 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/program_finalization.rb` | 64 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/resolution_phase.rb` | 308 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/annotator/phases/signature_registration.rb` | 185 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/signature_registry.rb` | 98 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/type_analysis_phase.rb` | 115 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/type_analysis_session.rb` | 1124 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/annotator/phases/type_registration.rb` | 417 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/phases/whole_program_semantics.rb` | 111 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/annotator/protocol_projection_resolver.rb` | 140 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/ast.rb` | 3684 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/async_result_shape.rb` | 40 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/diagnostic_buckets.rb` | 572 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/diagnostic_examples.rb` | 199 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/diagnostic_registry.rb` | 3866 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/error_registry.rb` | 165 | pass | unknown | unknown | skipped | C4 | not_run |
| `compiler/ruby/ast/fixable_error.rb` | 180 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/fixable_suggestion_helper.rb` | 70 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/frontend_resource_budget.rb` | 61 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/ast/function_signature_forward.rb` | 6 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/ast/lexer.rb` | 540 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/ast/param.rb` | 68 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/parsed_type_syntax.rb` | 22 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/parser.rb` | 486 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/ast/parser/collections_capabilities_and_tenses.rb` | 829 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/parser/declarations_and_definitions.rb` | 1369 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/parser/expressions_and_postfix.rb` | 1061 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/parser/predicates_and_refinements.rb` | 261 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/parser/state.rb` | 245 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/parser/statements_and_control_flow.rb` | 723 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/parser/types.rb` | 539 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/parser_rules.rb` | 41 | pass | pass | pass | fail | Z0 | not_run |
| `compiler/ruby/ast/scope.rb` | 448 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/source_error.rb` | 235 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/std_lib.rb` | 1654 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/struct_field.rb` | 20 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/ast/symbol_entry.rb` | 617 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/syntax_typo_scanner.rb` | 182 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/ast/type.rb` | 5372 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/ast/type_capabilities.rb` | 240 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/ast/type_expression.rb` | 870 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/backends/fsm_wrapper_emitter.rb` | 703 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/backends/mir_emitter.rb` | 3369 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/backends/transpiler.rb` | 387 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/backends/type_zig_renderer.rb` | 36 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/backends/zig_type.rb` | 102 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/backends/zig_type_mapper.rb` | 41 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/compiler/compiler_frontend.rb` | 162 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/compiler/entrypoint.rb` | 8 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/compiler/module_importer.rb` | 317 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/compiler/package_source.rb` | 154 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/ffi/c_header_importer.rb` | 294 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/incremental.rb` | 4 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/incremental/compilation_session.rb` | 237 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/incremental/dependency_snapshot.rb` | 44 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/incremental/item_reconciler.rb` | 45 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/incremental/portable_cache.rb` | 198 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/incremental/program_artifact.rb` | 204 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/incremental/source_catalog.rb` | 223 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/incremental/watch_compiler.rb` | 34 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/incremental/zig_compiler.rb` | 130 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/alloc.rb` | 76 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/cleanup_classifier.rb` | 1337 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/cleanup_entry.rb` | 170 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/control_flow.rb` | 1770 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/fiber_ctx_builder.rb` | 440 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/fsm_lowering.rb` | 618 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/fsm_ops.rb` | 462 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/fsm_transform.rb` | 319 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/fsm_transform/context.rb` | 96 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/fsm_transform/emit.rb` | 1438 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/mir/fsm_transform/liveness.rb` | 306 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/fsm_transform/lowering_protocol.rb` | 10 | pass | pass | pass | pass |  | not_run |
| `compiler/ruby/mir/fsm_transform/recursive_splitter.rb` | 578 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/mir/fsm_transform/segments.rb` | 409 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/mir/fsm_transform/suspend_resolvers.rb` | 271 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/hoist.rb` | 1409 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_batch_window_lowerer.rb` | 369 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_binding_chain_lowerer.rb` | 322 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 1335 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_context.rb` | 359 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_each_lowerer.rb` | 251 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_host.rb` | 1429 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_list_lowerer.rb` | 588 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_lowering_bridge.rb` | 186 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_materializer.rb` | 556 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_placeholder_usage.rb` | 65 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_plan.rb` | 234 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_range_lowerer.rb` | 1150 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_records.rb` | 75 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_scalar_lowerer.rb` | 221 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lower/pipeline/pipeline_set_index_lowerer.rb` | 398 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lowering/capabilities.rb` | 1162 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/concurrency.rb` | 1337 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/control_flow.rb` | 1484 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/counters.rb` | 130 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lowering/expressions.rb` | 2962 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/functions.rb` | 2607 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/literals.rb` | 466 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/ownership_scanner.rb` | 113 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/lowering/schema_registry.rb` | 81 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lowering/state.rb` | 146 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/lowering/variables.rb` | 1584 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/materialization.rb` | 99 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/mir.rb` | 4828 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/mir_checker.rb` | 2854 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/mir/mir_lowering.rb` | 4627 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/mir/mir_pass.rb` | 568 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/mir_planning.rb` | 65 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/placement.rb` | 71 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/pre_mir_type_check.rb` | 90 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/program_mir_facts.rb` | 356 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/rewriters/pipeline_rewriter.rb` | 892 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/mir/rewriters/string_concat_rewriter.rb` | 78 | pass | fail | skipped | skipped | C0 | not_run |
| `compiler/ruby/mir/test_lowering.rb` | 441 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/mir/thunk_transform.rb` | 23 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/thunk_transform/emit.rb` | 376 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/mir/thunk_transform/recursive_splitter.rb` | 268 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/bg_capture_classifier.rb` | 130 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/capability_plan.rb` | 328 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/capture_strategy.rb` | 296 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/concurrency_checks.rb` | 198 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/effect_inference.rb` | 50 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/effect_set.rb` | 89 | pass | pass | fail | skipped | C3 | not_run |
| `compiler/ruby/semantic/escape_analysis.rb` | 1536 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/semantic/keep_analysis.rb` | 69 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/semantic/lifecycle_plan.rb` | 400 | fail | skipped | skipped | skipped | T0 | not_run |
| `compiler/ruby/semantic/local_binding_facts.rb` | 98 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/semantic/ownership_edge_planner.rb` | 89 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/ownership_graph.rb` | 442 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/ownership_identity.rb` | 65 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/ownership_transport.rb` | 260 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/pass_state.rb` | 102 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/pass_work_profiler.rb` | 554 | pass | fail | skipped | skipped | C1 | not_run |
| `compiler/ruby/semantic/semantic_ids.rb` | 94 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/semantic_index.rb` | 57 | pass | pass | fail | skipped | C2 | not_run |
| `compiler/ruby/semantic/tense_operation_plan.rb` | 564 | fail | skipped | skipped | skipped | T0 | not_run |
