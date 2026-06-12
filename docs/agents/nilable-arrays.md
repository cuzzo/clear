# Nilable Array Inventory

## Purpose

`T.nilable(T::Array[...])` should be rare. In most cases the absence of elements is better represented by an empty array, because nilable arrays add avoidable control-flow and type pressure. This inventory records every current textual occurrence, then tracks whether it is fixed, generated/historical text, a test fixture, or a justified optional-array boundary.

## Initial Count

- Total textual matches: 180
- Production/source matches under `src/`: 136
- `gems/nil-kill` implementation matches: 2
- `gems/nil-kill` spec fixtures: 10
- Generated Sorbet RBI matches: 11
- Historical/generated report matches: 20
- Docs text matches: 1

Nil-kill evidence highlights the strongest source-side pressure in parser pattern plumbing, MIR checker body walks, FSM segment splitting, auto-inference collectors, AST recursive traversal, and MIR unhoisted-use checking.

## Current Status

- Production/source matches under `src/`: 0
- `src/annotator` matches: 0
- `src/ast` matches: 0
- `src/mir` matches: 0
- Remaining whole-repo textual matches: 45

The remaining textual matches are not active production contracts:

- Generated RBI files still contain stale signatures and should be refreshed by their generator rather than hand-edited.
- `gems/nil-kill/report.md` is historical evidence from the prior run.
- `gems/nil-kill/spec` entries are fixtures proving nil-kill can reason about this type shape.
- `gems/nil-kill/lib` entries are string-recognition logic for nil-kill itself, not a nilable-array API.
- Existing docs mention prior bugs or this inventory.

## Source Resolution Summary

- Parser DSL optional pattern captures were normalized to empty arrays.
- AST recursive traversal helpers and diagnostic collectors that returned nil for side-effect-only work now return `void`.
- MIR checker body walkers now accept non-nil arrays and callers normalize absent bodies to `[]`.
- Auto-inference collectors now use side-effect contracts instead of accidental nilable-array returns.
- Intrinsic FSM metadata uses non-nil arrays plus explicit presence booleans where distinguishing absence from an empty template matters.
- FSM segment splitting now returns an optional `SplitResult` object whose `segments` field is always a non-nil array, preserving the legitimate "unsupported shape" nil boundary without making the array optional.
- `src/annotator`, `src/ast`, and `src/mir` no longer contain any `T.nilable(T::Array...)` source signatures.

## Source Inventory

### `src/annotator`

- [ ] `src/annotator/annotator.rb:770`
- [ ] `src/annotator/domains/control_flow.rb:271`
- [ ] `src/annotator/domains/execution_boundaries.rb:338`
- [ ] `src/annotator/domains/execution_boundaries.rb:569`
- [ ] `src/annotator/domains/expressions.rb:338`
- [ ] `src/annotator/domains/lifetimes.rb:652`
- [ ] `src/annotator/domains/variables.rb:498`
- [ ] `src/annotator/helpers/auto_inference.rb:719`
- [ ] `src/annotator/helpers/auto_inference.rb:789`
- [ ] `src/annotator/helpers/auto_inference.rb:807`
- [ ] `src/annotator/helpers/auto_inference.rb:816`
- [ ] `src/annotator/helpers/effects.rb:233`
- [ ] `src/annotator/helpers/effects.rb:1157`
- [ ] `src/annotator/helpers/fixable_helpers.rb:33`
- [ ] `src/annotator/helpers/function_analysis.rb:77`
- [ ] `src/annotator/helpers/function_analysis.rb:872`
- [ ] `src/annotator/helpers/function_analysis.rb:952`
- [ ] `src/annotator/helpers/function_analysis.rb:971`
- [ ] `src/annotator/helpers/generic_analysis.rb:43`
- [ ] `src/annotator/helpers/intrinsic_emit.rb:29`
- [ ] `src/annotator/helpers/intrinsic_emit.rb:30`
- [ ] `src/annotator/helpers/intrinsic_emit.rb:31`
- [ ] `src/annotator/helpers/intrinsic_emit.rb:32`
- [ ] `src/annotator/helpers/intrinsic_emit.rb:76`
- [ ] `src/annotator/helpers/pipe_analysis.rb:1173`
- [ ] `src/annotator/helpers/pipe_analysis.rb:1823`
- [ ] `src/annotator/helpers/pipe_analysis.rb:1845`
- [ ] `src/annotator/helpers/reentrance.rb:34`
- [ ] `src/annotator/helpers/reentrance.rb:96`
- [ ] `src/annotator/helpers/reentrance.rb:176`
- [ ] `src/annotator/helpers/test_annotation.rb:78`
- [ ] `src/annotator/helpers/test_annotation.rb:99`
- [ ] `src/annotator/helpers/with_match_check.rb:53`
- [ ] `src/annotator/helpers/with_match_check.rb:419`
- [ ] `src/annotator/phases/body_analysis.rb:40`
- [ ] `src/annotator/phases/body_analysis.rb:49`

### `src/ast`

- [ ] `src/ast/ast.rb:718`
- [ ] `src/ast/ast.rb:725`
- [ ] `src/ast/ast.rb:743`
- [ ] `src/ast/ast.rb:1260`
- [ ] `src/ast/ast.rb:1272`
- [ ] `src/ast/ast.rb:1977`
- [ ] `src/ast/ast.rb:1983`
- [ ] `src/ast/ast.rb:2411`
- [ ] `src/ast/fixable_error.rb:132`
- [ ] `src/ast/fixable_error.rb:149`
- [ ] `src/ast/parser.rb:53`
- [ ] `src/ast/parser.rb:69`
- [ ] `src/ast/parser.rb:495`
- [ ] `src/ast/parser.rb:1209`
- [ ] `src/ast/parser.rb:1637`
- [ ] `src/ast/parser.rb:2044`
- [ ] `src/ast/parser.rb:3051`
- [ ] `src/ast/parser.rb:3433`
- [ ] `src/ast/parser.rb:3576`
- [ ] `src/ast/parser.rb:3838`
- [ ] `src/ast/schemas.rb:218`
- [ ] `src/ast/schemas.rb:223`
- [ ] `src/ast/source_error.rb:94`
- [ ] `src/ast/symbol_entry.rb:463`
- [ ] `src/ast/syntax_typo_scanner.rb:124`

### `src/mir`

- [ ] `src/mir/cleanup_classifier.rb:537`
- [ ] `src/mir/control_flow.rb:1487`
- [ ] `src/mir/control_flow.rb:1493`
- [ ] `src/mir/control_flow.rb:1543`
- [ ] `src/mir/control_flow.rb:1704`
- [ ] `src/mir/control_flow.rb:1715`
- [ ] `src/mir/control_flow.rb:1885`
- [ ] `src/mir/fsm_lowering.rb:307`
- [ ] `src/mir/fsm_transform/segments.rb:122`
- [ ] `src/mir/fsm_transform/segments.rb:170`
- [ ] `src/mir/fsm_transform/segments.rb:215`
- [ ] `src/mir/fsm_wrapper_emitter.rb:236`
- [ ] `src/mir/hoist.rb:256`
- [ ] `src/mir/lowering/capabilities.rb:45`
- [ ] `src/mir/lowering/capabilities.rb:363`
- [ ] `src/mir/lowering/capabilities.rb:371`
- [ ] `src/mir/lowering/capabilities.rb:410`
- [ ] `src/mir/lowering/capabilities.rb:664`
- [ ] `src/mir/lowering/capabilities.rb:914`
- [ ] `src/mir/lowering/control_flow.rb:221`
- [ ] `src/mir/lowering/control_flow.rb:246`
- [ ] `src/mir/lowering/control_flow.rb:849`
- [ ] `src/mir/lowering/control_flow.rb:1166`
- [ ] `src/mir/lowering/expressions.rb:816`
- [ ] `src/mir/mir.rb:426`
- [ ] `src/mir/mir.rb:555`
- [ ] `src/mir/mir.rb:1603`
- [ ] `src/mir/mir.rb:1844`
- [ ] `src/mir/mir.rb:1855`
- [ ] `src/mir/mir.rb:1866`
- [ ] `src/mir/mir.rb:1888`
- [ ] `src/mir/mir.rb:2650`
- [ ] `src/mir/mir.rb:2652`
- [ ] `src/mir/mir.rb:2655`
- [ ] `src/mir/mir.rb:2656`
- [ ] `src/mir/mir_checker.rb:563`
- [ ] `src/mir/mir_checker.rb:849`
- [ ] `src/mir/mir_checker.rb:1043`
- [ ] `src/mir/mir_checker.rb:1084`
- [ ] `src/mir/mir_checker.rb:1115`
- [ ] `src/mir/mir_checker.rb:1126`
- [ ] `src/mir/mir_checker.rb:1310`
- [ ] `src/mir/mir_checker.rb:1906`
- [ ] `src/mir/mir_checker.rb:1950`
- [ ] `src/mir/mir_checker.rb:2029`
- [ ] `src/mir/mir_checker.rb:2086`
- [ ] `src/mir/mir_checker.rb:2581`
- [ ] `src/mir/mir_checker.rb:2616`
- [ ] `src/mir/mir_checker.rb:2731`
- [ ] `src/mir/mir_checker.rb:2737`
- [ ] `src/mir/mir_checker.rb:2777`
- [ ] `src/mir/mir_checker.rb:2790`
- [ ] `src/mir/mir_checker.rb:2799`
- [ ] `src/mir/mir_checker.rb:2805`
- [ ] `src/mir/mir_lowering.rb:221`
- [ ] `src/mir/mir_lowering.rb:1022`
- [ ] `src/mir/mir_pass.rb:486`
- [ ] `src/mir/test_lowering.rb:193`
- [ ] `src/mir/test_lowering.rb:217`
- [ ] `src/mir/test_lowering.rb:241`
- [ ] `src/mir/test_lowering.rb:254`
- [ ] `src/mir/thunk_transform/recursive_splitter.rb:93`
- [ ] `src/mir/thunk_transform/recursive_splitter.rb:139`
- [ ] `src/mir/thunk_transform/recursive_splitter.rb:256`

### Other `src`

- [ ] `src/backends/importer.rb:136`
- [ ] `src/lsp/server.rb:76`
- [ ] `src/semantic/escape_analysis.rb:868`
- [ ] `src/tools/doctor.rb:1218`
- [ ] `src/tools/formatter.rb:158`
- [ ] `src/tools/formatter.rb:2468`
- [ ] `src/tools/migration_suggester_helpers.rb:60`
- [ ] `src/tools/migration_suggester_helpers.rb:84`
- [ ] `src/tools/migration_suggester_helpers.rb:106`
- [ ] `src/tools/stack_verifier.rb:158`
- [ ] `src/tools/stack_verifier.rb:444`

### `gems/nil-kill` Source

- [ ] `gems/nil-kill/lib/nil_kill/apply.rb:553`
- [ ] `gems/nil-kill/lib/nil_kill/infer.rb:764`

## Generated, Historical, And Fixture Text

These are inventory entries but are not direct production design sites. They should disappear only when their generating source or fixture purpose changes.

### Generated RBI

- [ ] `sorbet/rbi/ast-struct-fields.rbi:364`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1270`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1272`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1282`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1284`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1300`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1302`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1581`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1583`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1602`
- [ ] `sorbet/rbi/clear-attr-accessors.rbi:1835`

### Nil-kill Report Evidence

- [ ] `gems/nil-kill/report.md:483`
- [ ] `gems/nil-kill/report.md:485`
- [ ] `gems/nil-kill/report.md:488`
- [ ] `gems/nil-kill/report.md:490`
- [ ] `gems/nil-kill/report.md:540`
- [ ] `gems/nil-kill/report.md:543`
- [ ] `gems/nil-kill/report.md:544`
- [ ] `gems/nil-kill/report.md:1535`
- [ ] `gems/nil-kill/report.md:1635`
- [ ] `gems/nil-kill/report.md:1645`
- [ ] `gems/nil-kill/report.md:1661`
- [ ] `gems/nil-kill/report.md:1667`
- [ ] `gems/nil-kill/report.md:1899`
- [ ] `gems/nil-kill/report.md:1933`
- [ ] `gems/nil-kill/report.md:2070`
- [ ] `gems/nil-kill/report.md:2071`
- [ ] `gems/nil-kill/report.md:2073`
- [ ] `gems/nil-kill/report.md:2074`
- [ ] `gems/nil-kill/report.md:2097`
- [ ] `gems/nil-kill/report.md:2099`

### Nil-kill Spec Fixtures

- [ ] `gems/nil-kill/spec/apply_spec.rb:154`
- [ ] `gems/nil-kill/spec/apply_spec.rb:163`
- [ ] `gems/nil-kill/spec/apply_spec.rb:169`
- [ ] `gems/nil-kill/spec/nil_kill_spec.rb:1493`
- [ ] `gems/nil-kill/spec/nil_kill_spec.rb:1495`
- [ ] `gems/nil-kill/spec/nil_kill_spec.rb:1501`
- [ ] `gems/nil-kill/spec/nil_kill_spec.rb:1665`
- [ ] `gems/nil-kill/spec/nil_kill_spec.rb:1674`
- [ ] `gems/nil-kill/spec/nil_kill_spec.rb:1679`
- [ ] `gems/nil-kill/spec/source_index_spec.rb:1404`

### Existing Documentation Text

- [ ] `docs/agents/vm-bugs.md:434`
