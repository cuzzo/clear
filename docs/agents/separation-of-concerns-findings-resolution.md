# Separation of Concerns Findings Resolution

Date: 2026-06-11

Scope: `src/annotator` and `src/ast`, using Decomplex Function LCOM and
Operational Discontinuity after the high-confidence tier-2 split.

## Result

Initial report after introducing the metrics:

- Operational Discontinuity (High Confidence): 6
- Function LCOM: 4
- Operational Discontinuity: 12

After the resolution pass:

- Operational Discontinuity (High Confidence): 0
- Function LCOM: 2
- Operational Discontinuity: 7

## Changed

| Finding | Action |
| --- | --- |
| `src/annotator/helpers/function_analysis.rb` `analyze_routine` | Extracted `collect_routine_returns` so the return-fact save/reset/collect/restore lifecycle is one private protocol. |
| `src/annotator/helpers/capabilities.rb` `predicate_impurity_reason` | Split direct call flags, stdlib metadata, and semantic function effects into separate private helpers. |
| `src/annotator/phases/annotation_boundary.rb` `verify_annotation_boundary!` | Split unresolved type facts, deferred validations, and function signature assertions into private helpers. |
| `src/annotator/domains/member_access.rb` `visit_GetField` | Extracted moved-path and capability-field diagnostics; left schema field resolution intact. |
| `src/annotator/helpers/effects.rb` `compute_needs_rt!` | Split direct runtime need collection, imported callee seeding, and transitive propagation. |
| `src/annotator/helpers/effects.rb` `compute_stack_tiers!` | Split base tier assignment from unbounded call-graph propagation. |
| `src/ast/type.rb` `slot_size` | Extracted fixed-array and struct slot-size helpers. |
| `src/ast/type.rb` `compute_zig_type` | Extracted generic-instance Zig rendering; map rendering was already a helper. |
| `src/annotator/domains/lifetimes.rb` `visit_CopyNode` | Extracted collection deep-copy requirement detection. |
| `src/annotator/domains/execution_boundaries.rb` `mark_unrequired_polymorphic_with_runtime!` | Extracted the polymorphic runtime-bound lookup. |
| `src/annotator/helpers/generic_analysis.rb` `find_container_source` | Extracted non-copy field container source handling. |
| `src/annotator/phases/auto_finalization.rb` `apply_auto_resolution_stamps!` | Extracted slot restamping from function/signature restamping. |
| `src/ast/type.rb` `needs_cleanup?` | Extracted non-string array cleanup handling. |

## Intentionally Ignored

| Remaining finding | Reason |
| --- | --- |
| `src/ast/parser.rb` `parse_raise_stmt` | Parser grammar alternatives for legacy string raise, empty raise, and typed raise. Extraction would add parser indirection without reducing architectural risk. |
| `src/ast/parser.rb` `parse_if_chain` | Parser grammar alternatives for shorthand IF, bind IF, paren-bind IF, and else chaining. Useful review signal, but not worth churn alone. |
| `src/ast/parser.rb` `parse_bg_body_stmt` | Keyword statement vs expression/THEN-chain grammar split. Kept review-only by the parser guard. |
| `src/ast/type.rb` `initialize` | Constructor initialization and explicit capability overrides are real phases, but changing constructor flow is high blast-radius. Leave until broader Type construction work. |
| `src/ast/parser.rb` `parse_unary` | Unary operator parsing plus reserved call-site override syntax. Small grammar alternative; no action. |
| `src/ast/parser.rb` `parse_cap_join` | Capability-chain parser loop. Cohesive enough and parser-local. |
| `src/annotator/domains/lifetimes.rb` `lookup_source_name` | Scope scan plus function-param fallback. Acceptable fallback helper shape; low value to split. |
| `src/annotator/phases/body_analysis.rb` `analyze_program_bodies!` | Small intentional pass over normal declarations followed by synthetic functions. |
| `src/ast/parser.rb` `type_annotation_source` | Small special-case for polymorphic shared type source rendering before normal annotation parts. |

## Verification

- `ruby -c` on all changed Ruby files: clean.
- Focused `bundle exec prspec` targets covering touched annotator/type paths:
  567 examples, 0 failures.
- Full `bundle exec prspec spec/`: 5784 examples, 0 failures.
- `bundle exec srb tc`: only the pre-existing unrelated
  `src/mir/lowering/expressions.rb:440` `lowering_counters` error remains.
- Regenerated Decomplex report:
  `ruby gems/decomplex/exe/decomplex report --output=tmp/decomplex-soc-src.md src/annotator src/ast`
