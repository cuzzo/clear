# FactMine Normalized Extractor Tech Debt Cleanup

Date: 2026-06-21

## High-Level Findings

- `gems/fact-mine/lib/fact_mine/syntax/normalized_extractor.rb` is the remaining major architecture violation.
  - It has 55 invariant-reported offender lines and 63 concrete-language occurrences when helper definitions and case arms are counted.
  - It is not merely oversized. It is compensating for missing normalized semantics by branching on concrete languages during generic fact extraction.
  - Until these branches are removed, we cannot estimate real per-language implementation cost.

- The repeated problem is not Ruby-specific. The extractor lacks normalized semantic attributes for common concepts.
  - Calls need normalized role, receiver, display text, access span, state-read eligibility, and suppression metadata.
  - Owners/functions need normalized name, owner, visibility, receiver alias, declaration kind, and owner-name span.
  - Branches/cases need normalized predicate text, enclosing span, case patterns, and duplicate-arm suppression.
  - State references need normalized read/write targets rather than language-specific raw-source recovery.

- The correct fix is not to add more generic helper methods with language branches.
  - Language files may inspect raw parser syntax.
  - The generic extractor must consume only normalized nodes and normalized metadata.
  - If the extractor asks "is this Python?" or "is this Java?", the architecture has failed.

- `gems/fact-mine/lib/fact_mine/ast/normalizer.rb` is large but mostly on the correct side of the boundary.
  - Its debt is organization and contract shape, not hidden concrete-language detector logic.
  - It should be split into smaller normalization pass modules after the extractor boundary is fixed.

- `gems/fact-mine/lib/fact_mine/syntax.rb` is mostly framework plumbing, but has one real language-specific special case.
  - The Python owner-context fallback around line 1110 must move into Python syntax/profile code.
  - The Ruby legacy/native pipeline branch around line 3274 is transitional pipeline selection, not detector logic, but should be removed once the normalized pipeline is authoritative.

- `gems/fact-mine/lib/fact_mine/ast/adapters/base.rb` is generic but too broad.
  - The adapter hook surface allows too much private normalizer access through `helpers.__send__`.
  - It needs an explicit public `NormalizationContext` API so language adapters can only supply grammar facts and normalized semantic attributes.

## Target Invariant

The extractor boundary should be:

1. Raw Tree-sitter syntax is read only by `ast/adapters/<lang>` and `syntax/<lang>`.
2. `ast/normalizer.rb` converts raw syntax into the shared normalized AST vocabulary.
3. Language files attach normalized semantic attributes to normalized nodes when grammar shape alone is not enough.
4. `syntax/normalized_extractor.rb` reads only:
   - normalized node type,
   - normalized children,
   - normalized text,
   - normalized span fields,
   - normalized semantic attributes.
5. `syntax/normalized_extractor.rb` may retain `language` only as output metadata or to fetch a prebuilt profile object. It must not reference concrete language symbols or call concrete-language helper methods.

The architectural invariant test should fail on:

- Any concrete language symbol in `normalized_extractor.rb`, for example `:ruby`, `:python`, `:java`, `:zig`.
- Any concrete language helper name in `normalized_extractor.rb`, for example `java_projected_call`, `lua_suppressed_state_read?`, `record_go_embedded_member_reads`.
- Any raw-parser API use from extractor code once the normalized AST has enough metadata, for example raw Tree-sitter kind APIs outside `ast/normalizer.rb` and language adapters.

Allowed extractor language usage:

- Storing `@language` to write document metadata.
- Passing `language` to an already-created profile if the profile contains no detector-specific concrete-language behavior.

This exception should be small and explicit in tests.

## Required Normalized IR Extension

`FactMine::Ast::Node` currently has only:

```ruby
type, children, first_lineno, first_column, last_lineno, last_column, text
```

That is not enough. It forces the extractor to recover semantics from raw source text.

Add a normalized metadata/attributes field to Ruby and Rust nodes:

```ruby
metadata
```

Use string or symbol keys consistently. The following normalized attributes are needed to remove the current concrete-language branches:

| Attribute | Purpose |
| --- | --- |
| `fact_roles` | Declares which fact categories this node participates in, such as `call_site`, `state_read`, `state_write`, `owner`, `function`, `branch`, `case_arm`, `semantic_effect`. |
| `suppress_fact_roles` | Suppresses specific generic facts without hard-coding a language in the extractor. |
| `call_receiver` | Canonical receiver for a call site. |
| `call_message` | Canonical message for a call site. |
| `call_display` | Source-stable display string for reports. |
| `call_access_span` | Span to use for call access/state read facts. |
| `call_site_span` | Span to use for call-site facts. |
| `state_read_targets` | Explicit state reads derived during normalization. |
| `state_write_targets` | Explicit state writes derived during normalization. |
| `owner_name` | Normalized owner/class/module/struct name. |
| `owner_kind` | Normalized owner kind. |
| `owner_span` | Span to report for owner declaration. |
| `function_name` | Normalized function/method name. |
| `function_owner` | Normalized owning type/module when available. |
| `function_visibility` | Normalized public/private visibility. |
| `receiver_aliases` | Normalized receiver alias map, for example Go receiver names to `self`. |
| `case_patterns` | Normalized case/match arm pattern display strings. |
| `branch_predicate` | Normalized branch predicate display string. |
| `branch_enclosing_span` | Span to use for decision/boolean grouping. |
| `semantic_effects` | Normalized dynamic dispatch, hidden IO, metaprogramming, and context-dependency effects. |

This is an IR extension, not an oracle change. Integration fixtures that assert final facts should remain byte-for-byte compatible. Only tests that assert normalized AST JSON should change.

## Current File Assessment

### `gems/fact-mine/lib/fact_mine/syntax/normalized_extractor.rb`

Status: not coherent yet.

Main issues:

- Contains concrete-language branches in generic extraction.
- Contains raw-source regex recovery for owners, functions, visibility, receiver aliases, state references, and case patterns.
- Contains helper functions named after concrete languages.
- Mixes stateless fact extraction with language-specific semantic recovery.

Required outcome:

- No concrete language references.
- No concrete-language helper names.
- No raw source regex fallback for language grammar.
- Extractor consumes normalized fields and emits facts.

### `gems/fact-mine/lib/fact_mine/ast/normalizer.rb`

Status: mostly architecturally acceptable, organizationally too large.

Main issues:

- `normalize_node` is a large dispatcher.
- Adapter hooks are broad.
- Normalizer and adapters communicate through private `helpers.__send__` calls.

Required outcome:

- Split by pass/category after the extractor is cleaned:
  - definitions,
  - calls,
  - assignment/state targets,
  - control flow,
  - literals,
  - exceptions,
  - strings/interpolation.
- Replace private helper access with an explicit `NormalizationContext`.
- Keep concrete-language grammar rules in `ast/adapters/<lang>`.

### `gems/fact-mine/lib/fact_mine/syntax.rb`

Status: mostly framework, with one real hidden language special case.

Main issues:

- Python owner-context fallback around line 1110 is language-specific and must move to Python profile/syntax code.
- The native Ruby pipeline branch around line 3274 should disappear once normalized extraction is the only production path.
- File is too large and should eventually split into registry, language profile, parser facade, document structs, and raw syntax traversal modules.

Required outcome:

- No concrete-language detector behavior in generic syntax traversal.
- Registry/loader language references may remain as plumbing, but should live in a smaller registry module.

### `gems/fact-mine/lib/fact_mine/ast/adapters/base.rb`

Status: generally on the right side of the boundary, but too permissive.

Main issues:

- Adapters can call private normalizer helpers through `helpers.__send__`.
- Hook names are broad enough to become detector backdoors.
- The base adapter currently defines many optional hooks without a clear "grammar fact only" contract.

Required outcome:

- Add `NormalizationContext` with explicit public methods.
- Make adapter hooks return normalized syntax or semantic attributes, not final detector facts.
- Add invariant tests that adapters cannot require extractor files and cannot call private normalizer methods.

## Every Concrete-Language Violation In `normalized_extractor.rb`

Line numbers reflect the file state audited on 2026-06-21.

| Lines | Current concrete-language behavior | Why it is wrong | Correct fix |
| --- | --- | --- | --- |
| 207 | Python `YIELD` nodes skip semantic-effect extraction. | The extractor knows Python yield semantics. | Normalize Python generator yield to either a non-effect `YIELD` with `suppress_fact_roles: ["semantic_effect"]` or a distinct normalized role. Extractor checks suppression metadata only. |
| 277 | Python conjunction members are sorted. | Boolean decision ordering policy is hidden behind a language branch. | Normalizer should emit deterministic conjunction member order, or extractor should apply the same deterministic order to all conjunctions if ordering is semantically irrelevant. |
| 307 | Zig field writes use a custom receiver-field span. | State-write span recovery is language-specific. | Zig adapter/normalizer should attach `state_write_targets` with the exact target span. Extractor records supplied write targets. |
| 393 | PHP call access span is forced to full span. | Call span policy is language-specific. | PHP normalizer should set `call_access_span` and `call_site_span` for normalized calls. |
| 411 | Lua call-site span uses `lua_full_span_call?`. | Lua report span policy is in generic extraction. | Lua syntax/adapter should attach `call_site_span` and `call_access_span`; extractor chooses the normalized field. |
| 416 | C rewrites `self` receiver based on first argument. | C pointer/member receiver semantics are language-specific. | C adapter should normalize receiver and receiver aliases before call extraction. |
| 424-425 | Java calls are projected through `java_projected_call`. | Java call shaping is detector behavior in the extractor. | Java adapter should normalize call receiver/message/display. Any projection needed for facts must be present on the normalized call node. |
| 458 | Python pseudo-calls `break`, `continue`, `value` are suppressed. | Parser artifacts leak into generic extraction. | Python normalizer should not emit these as calls, or should mark them with `suppress_fact_roles: ["call_site", "state_read"]`. |
| 459 | Zig `std.debug.print` is suppressed as a call site. | Language/library-specific call suppression is in generic extraction. | Zig adapter should tag this as hidden IO or suppress call-site role via normalized metadata. If this is generic IO suppression, represent it as `semantic_effects`. |
| 473 | Zig dot-prefixed local assignment becomes `.literal` state write. | Zig literal syntax recovery is embedded in generic assignment scanning. | Zig adapter should emit an explicit state-write target for dot literals. |
| 570 | Go embedded member reads are extracted by scanning text. | Go-specific state reads are mined in generic extraction from raw source. | Go adapter should normalize embedded member accesses to explicit `state_read_targets`. |
| 596 | Zig literal reads are extracted only for Zig. | Dot literal semantics are language-specific. | Zig adapter should emit explicit literal state-read targets. |
| 626 | C++ constructor initializer reads are scanned from raw source. | C++ grammar is parsed in the extractor. | C++ adapter/normalizer should turn initializer-list field references into normalized `state_read_targets`. |
| 653 | Lua suppresses state reads through `lua_suppressed_state_read?`. | Lua-specific detector suppression is hidden in generic state-read extraction. | Lua adapter should mark normalized calls with `suppress_fact_roles: ["state_read"]` when they are not state reads. |
| 655 | Lua calls with arguments are skipped as state reads. | Lua property/call semantics are language-specific. | Lua call normalization should distinguish property read, method call, and plain call roles. |
| 656 | Java non-`self` receivers are skipped as state reads. | Java method-vs-field semantics are language-specific. | Java adapter should tag field/property reads explicitly and suppress method calls from state-read facts. |
| 657 | Java `.name()` source is skipped as a state read. | Java source text pattern matching is inside the extractor. | Java adapter should project `.name()` chains into normalized call/state roles before extraction. |
| 658 | Zig `std.debug` is skipped as a state read. | Zig library/module shape is in generic extraction. | Zig adapter should mark this access as non-state or hidden IO metadata. |
| 659 | C `self.*` calls with arguments are skipped as state reads. | C receiver/call conventions are language-specific. | C adapter should tag function-like self calls as calls only, not state reads. |
| 667 | Ruby receiver text with parentheses uses call span instead of access span. | Ruby span quirks are in generic state-read extraction. | Ruby adapter/normalizer should set normalized `state_read_targets` or `call_access_span` correctly. |
| 729 | Lua `elseif` branch decisions are suppressed by source text. | Lua control-flow normalization is incomplete. | Lua normalizer should convert `elseif` into a normalized nested/linked `IF` representation that does not duplicate branch facts. |
| 962 | PHP source text is normalized by stripping `$` and `->`. | PHP text normalization belongs in PHP adapter/syntax. | PHP adapter should emit canonical normalized text, receiver, and message fields. |
| 1015 | C++/Rust append `()` to source message text. | Language-specific display formatting is in generic call formatting. | Adapter/normalizer should attach `call_display` or normalized message display. |
| 1023-1025 | `self_member_receiver` chooses `self->`, `self.`, or `this.` by language. | Receiver display syntax is language-specific. | Adapters should normalize self-member receiver display. Generic extractor should not render language syntax. |
| 1144 | Rust struct owner span is special-cased. | Rust declaration span policy is in generic owner extraction. | Rust adapter should set `owner_span` on struct owner nodes. |
| 1146 | C/Rust/Zig owner spans use `struct_keyword_span`. | Struct span recovery is language-specific. | C/Rust/Zig adapters should set `owner_span` during normalization. Generic owner extraction should use it. |
| 1186-1191 | Function owner detection branches for C, Go, Zig. | Owner inference from source text belongs to language adapters. | C/Go/Zig adapters should set `function_owner` and any receiver aliases on DEFN/DEFS nodes. |
| 1248 | C++/C# are declared implicit-owner-field languages. | Language capability gating is in extractor state-read logic. | Adapters should mark implicit owner fields or expose normalized `owner_field` metadata. Generic extraction should not ask which language has implicit fields. |
| 1261 | C `static` functions are private. | Visibility grammar is language-specific. | C adapter should set `function_visibility`. |
| 1262 | C++ visibility is computed by `cpp_visibility_from_context`. | C++ class access rules are implemented in generic extraction. | C++ syntax/adapter should compute visibility and attach `function_visibility`. |
| 1265 | Go lowercase function names are private. | Go export rules are language-specific. | Go adapter should set `function_visibility`. |
| 1266 | Python single-leading-underscore functions are private. | Python convention is language-specific. | Python adapter/syntax should set `function_visibility`. |
| 1268 | Rust/Zig functions default private. | Rust/Zig visibility defaults are language-specific. | Rust/Zig adapters should set `function_visibility`. |
| 1286 | Rust/Zig function names are regex-parsed from source. | Function grammar is parsed in extractor. | Rust/Zig normalizers must emit `function_name` directly. |
| 1287 | Go function names are regex-parsed from source. | Go grammar is parsed in extractor. | Go normalizer must emit `function_name`, receiver, and owner. |
| 1288 | Kotlin function names are regex-parsed from source. | Kotlin grammar is parsed in extractor. | Kotlin normalizer must emit `function_name`. |
| 1289 | Swift function names are regex-parsed from source. | Swift grammar is parsed in extractor. | Swift normalizer must emit `function_name`. |
| 1290 | PHP function names are regex-parsed from source. | PHP grammar is parsed in extractor. | PHP normalizer must emit `function_name`. |
| 1308 | Go receiver parameter is skipped while parsing params. | Go method syntax is language-specific. | Go adapter should normalize receiver separately from function parameters. |
| 1365 | Go parameter names drop `?` and use first token. | Go parameter parsing is in extractor. | Go adapter should emit normalized function parameter names. |
| 1371 | Ruby disables property-read call detection. | Ruby call/property semantics are language-specific. | Ruby adapter should mark property reads and call roles explicitly. Generic extractor should not infer from language. |
| 1485 | Zig case patterns keep only first value. | Zig case/match semantics are language-specific. | Zig adapter should emit normalized `case_patterns`. |
| 1489 | Go case source is not split on comma. | Go case syntax is language-specific. | Go adapter should emit normalized case pattern list. |
| 1495 | Java case patterns get `case ` prefix. | Java display formatting is language-specific. | Java adapter should emit pattern display text. |
| 1500 | C++/Kotlin strip wrapping parentheses from case predicate. | Predicate display normalization is language-specific. | C++/Kotlin adapters should emit `branch_predicate`/`case_predicate` text. |
| 1506-1511 | Kotlin and Swift have call-site access span exceptions. | Language/report span policy is in extractor. | Kotlin/Swift adapters should set `call_site_span` for these calls. |
| 1540 | Ruby boolean enclosing span uses node span directly. | Ruby decision span policy is in generic extractor. | Ruby normalizer should attach `branch_enclosing_span`, or generic boolean extraction should use normalized spans consistently. |
| 1548-1553 | Self-call state-read suppression branches for Ruby, Python, C, C++, C#, Java, Kotlin. | Method-call/state-read distinction is language-specific. | Adapters should mark normalized calls as state reads or suppress state-read role. |
| 1628 | Zig dot literals are collected as `.literal.*` branch refs. | Zig literal state refs are language-specific. | Zig adapter should emit normalized state refs for branch predicates. |
| 1648 | Branch predicate wrapping is disabled for C#, Go, Kotlin, Swift, Zig, Ruby, Lua. | Predicate display formatting is language-specific. | Normalizer should attach `branch_predicate` and `branch_enclosing_span`; generic extraction should not wrap by language. |
| 1663 | Go explicit self state refs recover receiver from raw text. | Go receiver alias handling belongs in Go adapter. | Go adapter should normalize receiver aliases and state-ref display. |
| 1673 | Java method calls are excluded from state refs by raw source check. | Java method/property distinction is in generic extraction. | Java adapter should tag method calls and property reads explicitly. |
| 1696 | C++ stream insertion operator is detected through `std::` raw text. | C++ operator semantics are in generic extraction. | C++ adapter should mark stream insertion as IO/noise or suppress corresponding generic facts. |

### Language-Named Helper Definitions To Remove

These helpers are also architectural violations even when the concrete language branch appears elsewhere. They make it too easy to hide detector logic under a "generic" file name.

| Helper | Current purpose | Correct destination |
| --- | --- | --- |
| `java_projected_call` | Rewrites Java call receiver/message pairs for report compatibility. | Java adapter/syntax call metadata normalization. |
| `record_go_embedded_member_reads` | Scans Go raw source for embedded member reads. | Go adapter/syntax state-read target normalization. |
| `record_zig_literal_read` | Converts Zig dot literals to `.literal` state reads. | Zig adapter/syntax state-read target normalization. |
| `zig_literal_span` | Computes Zig dot literal spans from raw text. | Zig adapter/syntax span metadata. |
| `record_cpp_initializer_field_reads` | Scans C++ initializer lists for field reads. | C++ adapter/syntax state-read target normalization. |
| `cpp_visibility_from_context` | Computes C++ method visibility from access labels. | C++ adapter/syntax function visibility metadata. |
| `java_case_pattern` | Formats Java case labels. | Java adapter/syntax case pattern metadata. |
| `lua_full_span_call?` | Chooses Lua call-site span behavior. | Lua adapter/syntax call span metadata. |
| `lua_suppressed_state_read?` | Suppresses Lua call-derived state reads. | Lua adapter/syntax call role metadata. |
| `java_method_state_ref?` | Suppresses Java method calls from state refs. | Java adapter/syntax call/property role metadata. |
| `stream_insertion_operator?` | Suppresses C++ stream insertion facts. | C++ adapter/syntax operator-call role metadata. |

## Concrete Cleanup Architecture

### New Ruby Systems

| File/System | Purpose | Expected LoC |
| --- | --- | --- |
| `lib/fact_mine/ast/node.rb` | Add `metadata` field with default empty hash and helper accessors. | +20 to +40 |
| `lib/fact_mine/ast/normalized_metadata.rb` | Generic metadata helper methods: span lookup, role checks, suppression checks, call/state target readers. | +120 to +180 |
| `lib/fact_mine/ast/normalization_context.rb` | Public adapter context replacing `helpers.__send__`. | +120 to +220 |
| `lib/fact_mine/ast/passes/calls.rb` | Shared call normalization helpers that attach call metadata. | +120 to +220 |
| `lib/fact_mine/ast/passes/definitions.rb` | Shared owner/function/visibility metadata attachment. | +100 to +180 |
| `lib/fact_mine/ast/passes/control_flow.rb` | Shared branch/case/predicate metadata attachment. | +100 to +180 |
| `lib/fact_mine/ast/passes/state_targets.rb` | Shared state read/write target metadata attachment. | +100 to +180 |
| `lib/fact_mine/syntax/normalized_extractor.rb` | Remove concrete-language branches; consume metadata. | -250 to -450 net |
| `lib/fact_mine/syntax/python.rb` | Move owner-context fallback and Python visibility/yield policy. | +20 to +60 |
| `lib/fact_mine/ast/adapters/<lang>.rb` | Move each language's grammar facts and semantic normalization hooks. | +10 to +120 per existing language, depending on current debt |

### Rust Parity Systems

Rust needs the same architecture, not a different workaround:

| File/System | Purpose |
| --- | --- |
| `gems/fact-mine/rust/src/ast.rs` or equivalent normalized node module | Add normalized metadata/attributes to Rust `Node`. |
| `gems/fact-mine/rust/src/ast/normalized_metadata.rs` | Typed metadata readers/writers mirroring Ruby. |
| `gems/fact-mine/rust/src/ast/normalization_context.rs` | Explicit adapter context API. |
| `gems/fact-mine/rust/src/ast/passes/*` | Mirror Ruby normalization pass split. |
| `gems/fact-mine/rust/src/syntax/*` | Ensure extractors consume normalized metadata only. |
| `gems/fact-mine/rust/src/architecture_test.rs` | Enforce no concrete-language branches in generic extraction. |

Rust should not keep Ruby-specific or language-specific fact logic in generic modules. Any current Rust language-specific logic in generic syntax/fact extraction must follow the same migration path.

## Migration Plan

### Phase 1: Lock The Boundary

1. Add explicit invariant tests before cleanup.
2. The invariant should allow current failures only through a checked debt allowlist containing the exact line inventory above.
3. Any new concrete-language reference in `normalized_extractor.rb` should fail immediately.
4. Add a second invariant rejecting concrete-language helper names in generic extractor files.

Expected test delta: invariant tests fail until cleanup is complete unless they use an explicit allowlist.

### Phase 2: Add Normalized Metadata To The IR

1. Add `metadata` to Ruby `FactMine::Ast::Node`.
2. Add equivalent metadata to Rust normalized nodes.
3. Keep serialization backward-compatible where possible by omitting empty metadata from JSON, or update only normalized-AST fixtures that intentionally assert IR shape.
4. Add generic metadata helper methods.

Expected production fact delta: none.

Expected fixture delta: only normalized AST JSON fixtures, if any, should change.

### Phase 3: Move Call Semantics Out Of Extraction

Move these violations first because they are the most repeated:

- Lines 393, 411, 416, 424-425, 458, 459, 653, 655-659, 667, 962, 1015, 1023-1025, 1371, 1506-1511, 1548-1553, 1673, 1696.

Implementation:

1. Normalizer/adapters attach `call_receiver`, `call_message`, `call_display`, `call_access_span`, `call_site_span`.
2. Normalizer/adapters attach `fact_roles` and `suppress_fact_roles`.
3. Extractor records calls and state reads from metadata.
4. Remove `java_projected_call`, `lua_full_span_call?`, `lua_suppressed_state_read?`, `java_method_state_ref?`, and `stream_insertion_operator?` from generic extraction.

Verification:

1. Run existing integration fixtures before and after.
2. Add focused normalized-IR fixtures for Java projected calls, Lua span/suppression, PHP receiver text, C self pointer call, Ruby property calls, Zig debug calls, and C++ stream insertion.
3. Final facts must be byte-for-byte identical.

### Phase 4: Move State Target Semantics Out Of Extraction

Move:

- Lines 307, 473, 570, 596, 626, 1248, 1628, 1663.

Implementation:

1. Adapters emit `state_read_targets` and `state_write_targets`.
2. Shared generic passes can derive common state targets from normalized calls/assignments without concrete language branches.
3. Language adapters only supply grammar-specific target construction.

Verification:

1. Add normalized-IR fixtures for Zig dot literals, Go embedded member reads, C++ initializer list reads, and implicit owner-field writes.
2. Final facts remain byte-for-byte identical.

### Phase 5: Move Owner/Function/Visibility Semantics Out Of Extraction

Move:

- Lines 1144, 1146, 1186-1191, 1261, 1262, 1265, 1266, 1268, 1286-1290, 1308, 1365.

Implementation:

1. Normalized function nodes carry `function_name`, `function_owner`, `function_visibility`, `receiver_aliases`, and normalized params.
2. Normalized owner nodes carry `owner_name`, `owner_kind`, and `owner_span`.
3. Remove raw regex parsing from extractor.

Verification:

1. Add normalized-IR fixtures for C static functions, C++ access sections, Go receiver methods, Go export visibility, Python underscore visibility, Rust/Zig default privacy, Kotlin/Swift/PHP function names.
2. Final facts remain byte-for-byte identical.

### Phase 6: Move Branch/Case/Predicate Semantics Out Of Extraction

Move:

- Lines 207, 277, 729, 1485, 1489, 1495, 1500, 1540, 1648.

Implementation:

1. Normalized branches carry `branch_predicate`, `branch_enclosing_span`, and duplicate-suppression metadata.
2. Normalized case arms carry `case_patterns`.
3. Python yield effect suppression becomes normalized semantic-effect suppression, not a branch in `scan_yield`.

Verification:

1. Add normalized-IR fixtures for Lua `elseif`, Zig case patterns, Go comma case behavior, Java case display, C++/Kotlin predicate display, Ruby boolean enclosing spans, Python generator yield.
2. Final facts remain byte-for-byte identical.

### Phase 7: Remove Allowlist And Enforce The Invariant

1. Delete all concrete-language branches and helper names from `normalized_extractor.rb`.
2. Remove the invariant allowlist.
3. Keep only allowed language metadata plumbing.
4. Run Ruby and Rust tests.
5. Run cross-implementation oracle tests.

Exit criteria:

- `normalized_extractor.rb` has zero concrete-language references.
- Generic extractor tests cannot be bypassed by adding helper files.
- Language-specific logic exists only in:
  - `ast/adapters/<lang>.*`,
  - `syntax/<lang>.*`,
  - explicitly named language fixture directories,
  - registry/loader plumbing.

## Testing Plan

### Integration Tests

Final fact JSON must remain byte-for-byte compatible unless an existing fact is proven wrong.

If facts change:

1. Determine whether the previous Ruby or Rust behavior was correct.
2. Add or update a fixture that exposes the real gap.
3. Fix the normalization or extractor bug.
4. Only update final fact oracles for deliberate, reviewed behavior changes.

### Normalized IR Tests

These are expected to change because the internal representation is changing.

Add normalized-IR fixtures for:

- call metadata,
- state target metadata,
- owner/function metadata,
- visibility metadata,
- branch/case metadata,
- suppression metadata.

These fixtures are the right place to prove that language-specific syntax was normalized correctly.

### Architecture Invariants

Add or tighten tests for:

- No concrete-language symbols in generic extractor files.
- No concrete-language helper names in generic extractor files.
- Generic extractor cannot require language adapter files.
- Language adapter files cannot require extractor files.
- Language adapters cannot call private normalizer methods.
- New language files must live under language-specific paths.
- Generic stateful passes cannot inspect raw parser nodes.

The invariant should prevent helper-file evasion. It should scan the whole generic extraction and generic pass directories, not just one file.

## Expected LoC Outcome

Current buried language-specific code in `normalized_extractor.rb`:

- Direct concrete-language offender lines: 55.
- Concrete-language occurrences including helper names/case arms: 63.
- Estimated real hidden language-specific implementation: 300 to 450 LoC, because each branch often has helper body, regex parsing, span math, or suppression behavior around it.

Expected movement:

| Destination | Estimated LoC |
| --- | --- |
| Deleted because normalized metadata makes it unnecessary | 60 to 120 |
| Moved into generic normalized metadata helpers/passes | 120 to 220 |
| Moved into existing language adapters/syntax files | 150 to 300 across all current languages |
| Net removed from `normalized_extractor.rb` | 250 to 450 |

Expected per-language cost after cleanup:

| Language shape | Adapter/syntax semantic LoC expectation |
| --- | --- |
| Simple C-family language with conventional grammar | 150 to 400 total language-specific LoC |
| Dynamic language with implicit receiver/property/call ambiguity | 500 to 1,000 total language-specific LoC |
| Ruby-level complex dynamic language | 900 to 1,300 total language-specific LoC |
| Any language needing 2,000+ LoC for normalized facts | Architecture failure unless the language itself is unusually complex and the code is clearly grammar normalization only |

This estimate is only meaningful after the cleanup. Today the extractor is hiding too much language behavior to trust language-specific LoC counts.

## Stop Conditions

Pause development if any of these occur during cleanup:

- A language requires detector-specific callbacks after normalized metadata is available.
- Generic extractor still needs concrete-language branches to pass final fact fixtures.
- Adding a new language requires duplicating generic extraction code rather than supplying grammar facts and normalized metadata.
- Rust and Ruby require different architecture to produce the same facts.
- The invariant cannot prevent someone from moving language branches into helper files under generic directories.

## Immediate Next Implementation Order

1. Add `metadata` to Ruby and Rust normalized nodes.
2. Add generic metadata readers and suppression helpers.
3. Move call metadata first because it eliminates the largest cluster of extractor branches.
4. Move state target metadata second.
5. Move owner/function/visibility metadata third.
6. Move branch/case metadata fourth.
7. Remove the extractor allowlist and enforce zero concrete-language references.
8. Split `normalizer.rb` and tighten adapter context only after the extractor boundary is clean.
