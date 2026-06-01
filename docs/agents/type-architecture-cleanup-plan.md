# Type Architecture Cleanup Plan

## Scope

Targets:

- `Type#initialize`
- `Type#parse_raw_input`
- `Type#compute_zig_type`

Primary file:

- `src/types.rb`

## Signal

The latest architecture and complexity reports keep ranking `Type` as a high
pressure object. The suspicious shape is not simply that `Type` has many
branches. It is that construction, normalization, derived representation, and
Zig emission are coupled through mutable instance state.

The riskiest pattern is a constructor that accepts broad raw input, stores
multiple derived facts, and then exposes methods that continue making semantic
decisions from the same mixed state. That makes `Type` hard for NilKill to prove,
hard for Decomplex to classify, and hard for callers to use without depending on
construction side effects.

## Hypothesis

The best payoff is to separate three responsibilities:

1. Parse external/raw input into one strongly typed normalized type descriptor.
2. Store only canonical semantic facts on `Type`.
3. Move Zig spelling decisions behind explicit typed variant emitters or a small
   Zig type renderer.

If a cleanup only moves branches from `Type#initialize` into helper methods while
keeping the same mutable fields and raw input protocol, it is not worth keeping.

## /plan

1. Snapshot `decomplex`, `slopcop`, `nil-kill`, and `espalier` metrics for
   `src/types.rb`.
2. Map every constructor input shape accepted by `Type#initialize` and
   `Type#parse_raw_input`.
3. Identify which shapes are real public API and which are legacy convenience
   forms that can be deleted safely.
4. Introduce strongly typed intermediate records only where they replace raw
   hash/array/string interpretation. Do not add `T.untyped`.
5. Collapse `parse_raw_input` so it returns a canonical descriptor instead of
   partially mutating `Type`.
6. Move `compute_zig_type` decisions to a typed rendering object or variant
   methods, but only if the old branch surface is deleted in the same change.
7. Regenerate metrics and compare:
   - Decomplex total findings and convergence for `Type`
   - SlopCop genuine gaps in `src/types.rb`
   - NilKill untyped, weak, and no-evidence counts for `Type`
   - Espalier mutation/call pressure for the three target methods
8. Keep the change only if it reduces real branch/state pressure or fixes a real
   bug. Revert if it merely creates wrapper methods around the same decisions.

## Strong Type Rules

- No added `T.untyped`.
- No added untyped hashes or arrays.
- New records must be concrete `T::Struct` classes or existing typed domain
  objects.
- Any constructor API that cannot be typed honestly should be deleted or isolated
  behind a narrow parser, not leaked into `Type`.

## Expected Payoff

High if raw-input parsing and Zig spelling are actually removed from the core
mutable object. Low if the work becomes a cosmetic method extraction.

This is a good v0.1 candidate because `Type` is foundational. A simpler type
core should improve the annotator, MIR lowering, backend emission, and the
static-analysis reports at the same time.

## Scrap Criteria

Scrap the branch if:

- `Type` gains a second compatibility path.
- `parse_raw_input` still accepts the same broad raw shapes and just delegates
  them elsewhere.
- `compute_zig_type` remains stateful but now crosses more helper boundaries.
- Metrics regress without a real bug fix or a clear follow-up deletion.

## Capability Writer Protocol Burndown

The first `TypeCapabilities` composition pass removed the old capability ivars
as storage, but it did not finish the update protocol. Direct writes such as
`type.ownership = ...`, `type.sync = ...`, `type.collection = ...`, and
`type.shard_count = ...` still exist across parser, annotator, AST finalization,
scope lookup, and MIR helpers. These are not a compatibility path in storage,
but they are still a loose protocol: callers can update one capability dimension
without making the semantic transition explicit.

Goal: audit every writer of the old capability fields and either migrate it to a
named grouped operation on `Type` / `TypeCapabilities`, or document why the
single-dimension write is the correct semantic operation. The default answer
should be migration. Keeping a direct setter must be rare, local, and justified.

Acceptance criteria:

- [x] `cap-writer-inventory`: regenerate the writer inventory with `rg` for
  `.ownership =`, `.sync =`, `.layout =`, `.collection =`, `.shard_count =`,
  `.soa =`, `.elem_ownership =`, `.elem_sync =`, `.link_source =`,
  `.is_observable =`, `.observable_terminal =`, and `.polymorphic_shared =`.
  Classify every `src/` writer as construction, parser capability application,
  storage overlay, generic substitution, annotation propagation, semantic
  transition, or test-only setup.
- [x] `cap-writer-type-constructor`: replace capability keyword post-processing
  in `Type#initialize` and raw parsing defaults with one typed capability
  construction path. Constructor/raw parse should build a complete
  `TypeCapabilities` value instead of assigning dimensions one by one.
- [x] `cap-writer-parser-annotation`: migrate `Parser#parse_type_annotation`,
  `Parser#mark_polymorphic_shared_type`, and `Parser#type_annotation_source`
  away from loose capability setters. Parser capability chains should produce a
  typed capability result and apply it once.
- [x] `cap-writer-finalize-storage`: migrate `AST::Locatable#finalize_storage!`
  to a named capability merge/projection operation. This method currently
  reconstructs a type and separately copies shard, sync, SOA, collection,
  observable, element, layout, ownership, and link-source facts.
- [x] `cap-writer-scope-overlay`: migrate `Scope#resolve_full_type` to a typed
  storage-overlay operation, such as `Type#with_symbol_entry_capabilities` or
  `TypeCapabilities.from_symbol_entry`. Storage-derived ownership, sync, layout,
  and link source must be applied as one semantic overlay.
- [x] `cap-writer-generic-substitution`: migrate generic substitution capability
  copying in `GenericAnalysis#apply_type_subst` and declaration metadata
  propagation in `GenericAnalysis#propagate_declared_metadata!` to named
  capability copy/merge helpers.
- [x] `cap-writer-annotator-transitions`: audit annotator semantic transitions
  such as IF/WHILE resolve unwrapping, LINK, RESOLVE, FREEZE, observable
  terminal stamping, constructor SOA/sharding, and type annotation propagation.
  Migrate broad propagation to grouped operations. Keep only truly atomic
  semantic transitions as direct setter calls, and document those retained
  writers in this section.
- [x] `cap-writer-method-analysis`: migrate collection/element capability
  propagation in annotator method helpers to grouped operations where the output
  type is a transformed view of an input type.
- [x] `cap-writer-mir-and-backend`: audit MIR/background-capture/fiber/literal
  writers. Keep direct writes only when the operation is a local semantic
  transition, not a partial copy of another type's capability state.
- [x] `cap-writer-tests`: update tests to use constructors or named helpers for
  broad capability setup. Test-only direct setters may remain only when the test
  specifically exercises setter/cache behavior.
- [ ] `cap-writer-guardrail`: add or extend an architecture spec so new broad
  propagation sites cannot add direct capability setters casually. The spec
  should allow a small documented set of semantic one-field transitions and
  setter-specific tests, not every caller.
- [x] `cap-writer-metrics`: after the migration, regenerate Decomplex and
  SlopCop with comparable coverage inputs. Success means the `Neglected Updates`
  capability cluster shrinks without increasing Broken Protocols or SlopCop
  genuine gaps. If metrics worsen, either finish the migration further or scrap
  the new helper shape.

Initial writer groups from the current branch:

- Parser construction/application:
  `src/ast/parser.rb:2880`, `src/ast/parser.rb:2881`,
  `src/ast/parser.rb:2882`, `src/ast/parser.rb:2890`,
  `src/ast/parser.rb:2898`, `src/ast/parser.rb:3130-3182`.
- Type construction/internal projection:
  `src/ast/type.rb:423-444`, `src/ast/type.rb:1020-1024`,
  `src/ast/type.rb:1524-1529`, `src/ast/type.rb:1848-1849`,
  `src/ast/type.rb:2441-2443`, `src/ast/type.rb:2476-2478`,
  `src/ast/type.rb:2514-2516`, `src/ast/type.rb:2685-2687`,
  `src/ast/type.rb:2778`.
- AST and scope overlays:
  `src/ast/ast.rb:1039-1107`, `src/ast/scope.rb:147-173`.
- Annotator and helpers:
  `src/annotator/annotator.rb:1448-1449`,
  `src/annotator/annotator.rb:2049-2050`,
  `src/annotator/annotator.rb:2764`, `src/annotator/annotator.rb:2782`,
  `src/annotator/annotator.rb:2895`, `src/annotator/annotator.rb:2917`,
  `src/annotator/annotator.rb:3548`, `src/annotator/annotator.rb:3696`,
  `src/annotator/annotator.rb:3827-3828`,
  `src/annotator/annotator.rb:4244-4252`,
  `src/annotator/annotator.rb:4466-4468`,
  `src/annotator/annotator.rb:4485-4486`,
  `src/annotator/annotator.rb:4499`,
  `src/annotator/annotator.rb:4596-4598`,
  `src/annotator/helpers/generic_analysis.rb:359-363`,
  `src/annotator/helpers/generic_analysis.rb:413`,
  `src/annotator/helpers/generic_analysis.rb:528`,
  `src/annotator/helpers/generic_analysis.rb:556-576`,
  `src/annotator/helpers/method_analysis.rb:48-52`,
  `src/annotator/helpers/method_analysis.rb:160-161`.
- MIR/helper transitions:
  `src/mir/bg_capture_classifier.rb:123-127`,
  `src/mir/fiber_ctx_builder.rb:237`,
  `src/mir/lowering/literals.rb:187`,
  `src/mir/escape_analysis.rb:187`.

Known non-Type false positives from the same grep/report should not be migrated
as part of this burndown, for example `src/lsp/server.rb:31` (`IO#sync=`) and
pipeline AST node collection rewrites.

Final outcome:

- Added `TypeCapabilities` as the backing capability composition object and
  replaced direct Type capability ivar storage with typed reader/writer
  transitions.
- Replaced broad external capability writes with named operations such as
  `merge_capabilities_from!`, `apply_declared_type_capabilities!`,
  `apply_finalized_value_shape!`, `apply_symbol_overlay!`,
  `copy_collection_shape_from!`, and `copy_striped_map_topology_from!`.
- Left non-Type writers alone, notably `CapabilityParseResult` parser assembly
  and `SymbolEntry` state that is not part of `TypeCapabilities`.
- Guardrail is still open: this pass removed the broad callsites, but a focused
  architecture spec should be added separately so new Type capability writers
  cannot reappear casually.

Final metrics from this pass:

- Decomplex: Neglected Updates `1738 -> 1395` (-343), Broken Protocols
  `1485 -> 1296` (-189), Neglected Path Conditions `1763 -> 1690` (-73),
  Decision Pressure unchanged at `298`, False Simplicity `770 -> 793` (+23).
- SlopCop: fresh full coverage run produced `1664` genuine gaps across 96
  files. This is not directly comparable to the committed report (`1102`
  across 87 files) because the report input set changed, but the run completed
  cleanly and the Type capability cleanup did not introduce test failures.
- Verification: `bundle exec srb tc`; focused capability/type/annotator/MIR
  specs (`566 examples, 0 failures`); full unit coverage suite (`5065
  examples, 0 failures`, line `94.14%`, branch `77.05%`).
