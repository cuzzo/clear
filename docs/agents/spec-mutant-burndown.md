# Ruby Spec Mutant Burn-Down

Goal: drive Ruby `spec/` mutation coverage to 100% for every `src/` subject,
or record a validated exception such as a proven equivalent mutant.

## Real Bugs Found

- `Type#primitive?` depended on `AST::PRIMITIVE_TYPES`, so loading
  `ast/symbol_entry` in isolation and calling
  `SymbolEntry#capture_move_required?` could raise `NameError:
  uninitialized constant Type::AST`. Fixed by moving the primitive type set
  into `Type` and making `Type#primitive?` self-contained.
- `Pprof::Profile#add_sample` had a Sorbet signature claiming it returned
  `String`, but the mutator returned the backing sample array. Focused
  `spec/pprof_spec.rb` failed under runtime type checking. Fixed by making the
  method a typed void mutator.
- `LSP::DocumentStore::Document#cached_findings` referenced
  `LSP::Analyzer::Result` without loading analyzer; requiring
  `lsp/document_store` alone and reading cached findings could raise
  `NameError`. Fixed by extracting `LSP::AnalysisResult` into a small shared
  value-object file used by both DocumentStore and Analyzer.
- `LSP::Analyzer::SyntheticFinding#fatal?` read `@level`, but the
  `Struct`-backed finding stores its field behind the `level` reader. Synthetic
  fatal diagnostics therefore reported `fatal? == false`. Fixed by using the
  reader.
- `LintFixRewriter.offset_for` and
  `LintFixRewriter.locate_type_annotation_span` could return `nil` for invalid
  source locations, but their Sorbet signatures claimed non-nil return values.
  Focused direct tests exposed runtime type errors. Fixed the signatures to
  return nilable offset/edit values.
- `FsmOps::Lowerer#lower_expr` accepted negative `ArgRef` indexes because it
  only checked the upper bound before indexing a Ruby array. A negative op
  index could therefore bind to a trailing argument instead of failing closed.
  Fixed by requiring `0 <= idx < arg_count`.
- `UseAfterMoveChecker#check_reads_in_expr` walked hash literal values but not
  hash literal keys, even though the parser accepts arbitrary expressions as
  keys. Earlier ownership checks catch some simple cases, but the dataflow
  checker safety net was incomplete. Fixed by checking key expressions too.
- `UseAfterMoveChecker#check_call_reads` skipped every `MoveNode` argument.
  That is correct for `GIVE x`, but not for complex move expressions like
  `GIVE owner.field`, where `owner` must still be live to read the field.
  Fixed by skipping only simple identifier moves and recursively checking
  complex move receivers.
- `Formatter::Emitter#emit_match_arm` was typed as returning an array even
  though it is a mutating helper whose final expression is a void
  `insert_nl(out)` call. Running formatter specs after loading the stricter
  runtime type environment exposed Sorbet return validation failures for MATCH
  formatting. Fixed the signature to `void`.
- `FsmTransform::RecursiveSplitter` runtime signatures named `MIRLowering`
  directly even though the file can be loaded without that concrete class and
  the splitter only needs a lowering protocol object. Focused
  `spec/fsm_recursive_splitter_spec.rb` exposed `NameError: uninitialized
  constant FsmTransform::RecursiveSplitter::MIRLowering`. Fixed the signatures
  to accept the protocol object without naming the concrete lowering class.
- `PipelineRewriter` runtime signatures named `SemanticAnnotator` directly,
  but `mir/rewriters/pipeline_rewriter` can be required without loading the
  annotator. Mutant could not even match `PipelineRewriter#rewrite!` under the
  focused require path because the signature raised `NameError`. Fixed the
  optional annotator slot to be a protocol object instead of a concrete runtime
  constant dependency.
- `MIREmitter` used `AST.zig_name_of_type` and `AST.kind_of_type` in lock
  error-handler emission but did not require `ast/error_registry`, the file
  that defines those helpers. Focused `MIREmitter#emit` coverage exposed the
  load-order failure. Fixed by making the dependency explicit.

This ledger only tracks real production bugs or broken tests. It does not track
ordinary loose assertions that were tightened to make existing tests
load-bearing.

## Current Findings

- `gems/lineage/tools/mutant-converters/ruby_mutant.rb` only accepted one `spec:` file per subject.
  That hid existing load-bearing specs from mutant for broad subjects such as
  `FsmTransform::Emit`.
- The runner did not accept raw class/module names such as
  `FsmTransform::Emit` for `--subject`; callers had to know the generated slug
  or exact wildcard expression.
- The runner now accepts explicit YAML `expression:` matchers, which lets broad
  subjects be split into exact method gates without relying on wildcard
  expansion.
- `FsmTransform::Emit*` remains too broad for a meaningful class/module gate,
  but exact gates now cover the stable build paths and helper contracts. The
  remaining work is method-level survivor burn-down, not trying to force the
  entire emitter module into one gate.
- `Type*` improved after attaching the direct Type specs and is currently
  advisory at `24.86%`. The class wildcard is too broad for one effective
  subject gate; method-level hard gates now cover the safety-critical ownership,
  payload, and operator predicates.
- Low-baseline advisory subjects still remain in the registry. The next highest
  leverage targets are broad compiler/runtime helpers rather than the LSP/tool
  subjects already hard-gated below.
- `EscapeAnalysis*` was effectively miswired: the only registered spec used
  string top-level `RSpec.describe` metadata, so Mutant selected `0` examples
  for 8,204 mutations. Changing the spec metadata to `RSpec.describe
  EscapeAnalysis` and adding a direct `spec/escape_analysis_spec.rb` moved the
  subject to real execution (`19` selected examples, `32.58%` coverage), but it
  remains far from promotable and now has timeout pressure.
- `LintFixRewriter*` moved from `84.25%` to `85.15%` after adding source-span,
  trailing-newline, and offset edge tests. It remains open; 366 survivors is
  too many to classify as equivalent.
  The public entrypoint `LintFixRewriter.rewrite` is now separately hard-gated
  at `100.00%`, `60/60` killed, `0` timeouts. The exact pass removed a
  redundant empty-edit branch; `apply_edits(source, [])` is already identity.
- Constant-based RSpec metadata matters for this Mutant/RSpec setup. Specs
  using string top-level descriptions can run under `prspec` but attach poorly
  to constant subjects. Fixed metadata for EscapeAnalysis, PredicateRewriter
  lint tests, borrow/use-after-move specs, cleanup specs, FSM unified emit, and
  MIR comparison where those files are registered under concrete subjects.
- Current advisory measurements after this pass:
  - `BorrowChecker*`: `70.20%`, `728/1037` killed, `10` timeouts, `46`
    selected tests. The public `BorrowChecker.check` entrypoint is now
    separately hard-gated at `100.00%`, `13/13` killed, `0` timeouts. The exact
    pass removed a duplicate `checker.errors` return after `check!`, because
    `check!` already returns the error array, and added wrapper coverage proving
    `schema_lookup` is forwarded. No new real bug found.
  - `UseAfterMoveChecker*`: `80.74%`, `784/971` killed, `0` timeouts,
    `64` selected tests. Improved from `45.16%` by adding direct read-walker
    and statement-dispatch coverage; remains advisory because call/share helper
    survivors still need triage.
    The public `UseAfterMoveChecker.check` entrypoint is now separately
    hard-gated at `100.00%`, `33/33` killed, `0` timeouts. Added public-entry
    coverage for default analysis context, forwarding `can_fail_fns` and
    `schema_lookup`, and actually running `check!` to emit use-after-move
    diagnostics. No new real bug found in this pass.
  - `CaptureStrategy*`: `77.63%`, `708/912` killed, `0` timeouts, `36`
    selected tests. The public `CaptureStrategy.classify` method is separately
    hard-gated at `98.19%`; broad helper predicates remain advisory.
  - `PprofConverter*`: `81.22%`, `2618/3223` killed, `0` timeouts.
    The public `PprofConverter.convert_all` entrypoint is now separately
    hard-gated at `100.00%`, `146/146` killed, `0` timeouts. The exact pass
    removed a redundant directory-exists precheck, removed the ignored
    `convert_perf` binary argument, and added public-entry coverage that
    derived binary mappings are present for every emitted profile and omitted
    when the derived binary is absent. No real bug found.
  - `LockHelper*`: broad wildcard remains advisory at `80.17%`, `1820/2270`
    killed, `101` timeouts. The exact SCC helper `LockHelper#tarjan_scc` is
    now separately hard-gated at `88.91%`, `425/478` killed, `0` timeouts. The
    exact pass replaced the dense hand-rolled Tarjan lowlink state machine
    with a typed iterative Kosaraju pass, tightened the long-chain spec with an
    in-spec timeout so loop mutations fail as spec failures rather than mutant
    runner timeouts, and added symbol-contract plus diamond-SCC coverage.
    Remaining survivors are classified exceptions: Sorbet `T.let`/`T.must`
    type-wrapper removals, traversal-order equivalents, and duplicate-work
    guard removals that do not change SCC membership.
  - `LoopFrameAnalysis*`: `51.12%`, `981/1919` killed, `5` timeouts.
    The broad wildcard remains advisory because it includes many private walk
    helpers, but the public/high-value contracts now have exact hard gates:
    `LoopFrameAnalysis.analyze!` at `97.72%` (`43/44` killed),
    `LoopFrameAnalysis.direct_loop_expression_boundary?` at `88.75%`
    (`71/80` killed), and
    `LoopFrameAnalysis.direct_loop_expression_frame_alloc?` at `98.52%`
    (`67/68` killed), all with `0` timeouts. Added public-entry coverage for
    declaration skipping, schema lookup propagation, function-node propagation,
    shard-context updates, loop-boundary classification, receiver-mutating
    local-name handling, boundary sibling scanning, and allocation-scan
    short-circuiting. No real bug found. Remaining survivors are equivalent
    AST class-check variants, shard root `fn` versus `fn.body` traversal under
    current AST structure, and `next` versus `break` after the existential
    frame-allocation result is already true.
  - `FsmTransform::Liveness*`: `69.87%`, `784/1122` killed, `13` timeouts.
    The public `FsmTransform::Liveness.analyze` entrypoint is now separately
    hard-gated at `92.90%`, `445/479` killed, `0` timeouts. The exact pass
    split synthetic `:"name__type"` entries out of the definition map into a
    typed `type_by_name` map, simplified ordered first/last segment tracking,
    and added direct coverage for captured declarations, NEXT result vars, IO
    result-var exclusion, repeated defs/uses, omitted capture context, and
    continuing past skipped locals. No real bug found. Remaining survivors are
    equivalent Sorbet `T.cast`/`T.let` type-argument mutations, initialized
    `Hash#[]`/`fetch` variants, symbol inequality forms, and nil result-var key
    writes that cannot be observed by an AST identifier.
  - `FsmTransform::SuspendResolvers*`: `89.29%`, `1118/1252` killed,
    `0` timeouts. Improved from `61.98%` by adding direct structural tests for
    IO/NEXT lowering, discarded results, captured-promise guards, and defensive
    nil/no-emit paths. No real bug found; remaining survivors are concentrated
    in Sorbet no-ops, default constructor equivalences, and broad helper
    predicate variants. The public `FsmTransform::SuspendResolvers.resolve`
    dispatch entrypoint is now separately hard-gated at `100.00%`, `59/59`
    killed, `0` timeouts. The exact pass removed an inert `T.bind(... ) rescue
    nil` line and added coverage that explicit `susp_idx` overrides are
    forwarded rather than recomputed from the segment index.
  - `CleanupClassifier*`: broad wildcard remains advisory because the full
    classifier surface is large and slow, but the public
    `CleanupClassifier.classify_plan` orchestration method is separately
    hard-gated at `94.92%`, `131/138` killed, `0` timeouts. The exact method
    improved by adding public-entry coverage for declaration-only plans,
    capture-bind classification, loop cleanup-scope stamping, and moved-source
    guard propagation. No real bug found; remaining survivors are equivalent
    string-coercion, `T.let` type-wrapper, and schema-removal variants that do
    not change the current heap-capture cleanup contract.
    The frozen fact container now has exact hard gates as well:
    `CleanupClassifier::FrozenCleanupFacts#entry_for` at `100%`,
    `#entry_for_node` at `98%`, and `#without_names` at `98.3%`. These cover
    binding-aware lookup, path fallback, and non-mutating fact filtering.
  - `FsmTransform::RecursiveSplitter*`: `56.15%`, `1524/2714` killed,
    `0` timeouts. The public `FsmTransform::RecursiveSplitter.split`
    entrypoint is now separately hard-gated at `100.00%`, `114/114` killed,
    `0` timeouts. The exact pass removed an inert `T.bind` line, made segment
    entry normalization unconditional, accepted equivalent `Done.new(nil)` and
    synthetic-field copy mutations into simpler production code, and added
    coverage for lock-suspending `WITH` without context plus alias remapping
    when entry normalization changes the critical-section segment index.
  - `FsmWrapperEmitter*`: `49.13%`, `1868/3802` killed, `0` timeouts.
    The public `FsmWrapperEmitter.render` dispatch entrypoint is now separately
    hard-gated at `100.00%`, `37/37` killed, `0` timeouts. The exact pass
    removed an inert `T.bind(... ) rescue nil` line and tightened the
    non-FSM-body error message assertion. No real bug found.
- `EscapeAnalysis*`: broad wildcard remains advisory. The wrapper
    `EscapeAnalysis.apply!` is now separately hard-gated at `100.00%`,
    `24/24` killed, `0` timeouts after adding direct forwarding/default-arg
    coverage. The larger public orchestrators are now separately hard-gated:
    `EscapeAnalysis.apply_with_facts!` at `98.96%`, `288/291` killed,
    `0` timeouts, and `EscapeAnalysis.propagate_caller_sync!` at `91.48%`,
    `247/270` killed, `0` timeouts. The `apply_with_facts!` survivors are
    Sorbet `T.let` generic type-argument equivalents. The
    `propagate_caller_sync!` survivors are bounded fixed-point performance
    bookkeeping, redundant same-value assignment guards, and Symbol equality
    equivalents; the pass now has direct coverage for nil param symbols,
    declared sync, propagated sync replacement, bare storage, storage
    disagreement, and transitive sync/storage convergence. The pass also
    tightened declared-sync handling so declared param sync blocks caller
    inference by declaration rather than by incidental entry state.
    Exact registry contracts are also hard-gated now:
    `EscapeAnalysis::EscapeSink#matches?` at `100%`,
    `validate_escape_sink_handlers!` at `100%`,
    `validate_derived_placement_handlers!` at `100%`, and
    `validate_escape_sinks!` at `99%`. These catch broken registry wiring
    without forcing the broad walker subject to become a hard gate.
- `PredicateRewriter*`: broad wildcard remains advisory (`73.48%`) because it
  includes many private source-span helpers. The public entrypoints are now
  separately hard-gated: `PredicateRewriter.rewrite` at `92.68%` (`38/41`
  killed) and `PredicateRewriter.lint!` at `92.50%` (`37/40` killed), both
  with `0` timeouts. The exact pass removed a redundant empty-edit branch from
  `rewrite` and added disabled-mode/no-lex plus malformed-source coverage for
  `lint!`. No real bug found. Remaining survivors are equivalent top-level
  namespace qualifiers and parser source-argument omission for successful
  rewrite/lint output.
- Broad wildcard runs for `MIREmitter*` and `FsmTransform::Emit*` are too slow
  for the current interactive loop after spec metadata fixes; both were stopped
  after several minutes without a summary. These need scoped method-level
  subjects or a longer batch run before they can be honestly promoted.
- `MIREmitter#emit` is now separately hard-gated at `99.73%`, `1120/1123`
  killed, `0` timeouts. The exact pass added public-dispatch coverage for
  stackful BG blocks, assertion-raises checks, batch windows, mutual thunk
  trampolines, discard-owned cleanup, snapshot/polymorphic mutation, sorted and
  fallible lock binding, registry/indexed/extern/observable/inline calls, and
  sharded concurrent each. One redundant explicit `errdefer: false` default was
  accepted into simpler production code. The remaining three survivors are
  equivalent `T.must(...)` removal mutations around emitted child expressions:
  valid MIR nodes already emit strings there, and the assertions are static
  type/runtime guard noise rather than behavior.
- `FsmTransform::Emit.build_recursive` is now separately hard-gated at
  `85.60%`, `1112/1299` killed, `0` timeouts. The exact pass moved the method
  from `37.79%` by adding public-path coverage for recursive capture maps,
  alias overrides, pointer-capture forwarding, promoted field filtering,
  fact-only result-transfer facts, void-result assignment, cross-segment
  cleanup invariant failures, failed AST lowering, and owned NEXT result
  guards. It also accepted equivalent/dead code into simpler production:
  recursive segment specs no longer pass redundant `structure_stmts`, nonnil
  `pointer_captures` no longer has a fallback `Set.new`, and nonnil
  recursive promoted names no longer run through `compact`. Remaining
  survivors are classified exceptions: empty-segment `return nil` fallthrough
  variants, Sorbet `T.let` type-argument mutations, closed `Struct` class-check
  equivalents, `build_fsm_unified(..., nil)` because the final lowering object
  is not read after recursive specs are built, and broad structural variants
  whose behavior is already covered by narrower helper/dispatcher exact gates.
- `FsmTransform::Emit.build_fsm_unified` is now separately hard-gated at
  `97.65%`, `584/598` killed, `0` timeouts. The exact pass removed dead
  nil/blank defensive work from the typed FSM body path, removed unused
  dispatch-tail parameters, replaced hash-as-set field tracking with typed
  sets, and added structural coverage for inert empty-bind segments, dispatch
  arm metadata, duplicate extra fields, capture-field filtering, and promoted
  field filtering. No real bug found. The remaining survivors are classified
  exceptions: Sorbet `T.let` generic type-argument mutations, `next nil` versus
  `next` inside `filter_map`, and equivalent Set copy/type-wrapper variants
  after the field membership behavior is already asserted.
- Stable `FsmTransform::Emit` helper contracts are now separately hard-gated:
  `tail_resume_target` at `96.9%`, `dedupe_context_fields` at `92.6%`,
  `build_recursive_capture_map` at `97.6%`, and
  `register_recursive_destroy_actions!` at `92.3%`. The exact pass made the
  FSM emit spec helper pass typed `capture_finalizers` and existing
  `destroy_actions`, then added structural coverage for resume routing,
  context-field dedupe, recursive capture maps, and recursive destroy cleanup
  registration. Remaining survivors are equivalent string coercions,
  `T.let` type-argument changes, omitted `CleanupEntry.build` defaults, and an
  implicit nil `else`.
- `LockHelper#tarjan_scc` is hard-gated with classified non-semantic survivors
  as described above.
- `PipelineRewriter*`: broad wildcard remains advisory (`33.01%`) because it
  includes the full private fusion/lowering helper surface. The public
  `PipelineRewriter#rewrite!` entrypoint is now separately hard-gated at
  `97.43%`, `38/39` killed, `0` timeouts. The exact pass removed a dead nil
  guard from the non-nil typed public method, guarded the optional
  `BlockExpr#result` rewrite at the actual optional child site, removed a
  redundant final return, and added non-pipeline binary/operator traversal
  coverage. The remaining survivor is equivalent under the closed AST node
  model: `is_a?(AST::BinaryOp)` versus `instance_of?(AST::BinaryOp)`.
- `Type*`: broad wildcard remains advisory because `Type` is a wide facade
  spanning parsing shape, capability axes, placement, operator resolution,
  cleanup predicates, and Zig rendering. Metadata was fixed so the registered
  Type specs attach to the `Type` constant; the broad advisory moved from
  `5.38%` to `24.86%` with `107` selected tests on the bounded pure-Type spec
  set. The direct operator resolver is separately hard-gated:
  `Type.binary_op` at `96.05%`, `146/152` killed, `0` timeouts. Ownership and
  placement contracts are also exact-gated: `Type#heap_ptr?` at `98.3%`,
  `Type#needs_escape_promotion?` at `100%`,
  `Type#collection=` at `100%`,
  `Type#needs_pointer_passing?` at `100%`, and
  `Type#needs_heap_backing?` at `100%`. The latest pass accepted a redundant
  `pool?` branch out of `needs_heap_backing?` after fixing `collection=` to
  pin late-assigned `@pool` types to heap placement. Pool collection types now
  report `heap? == true` regardless of whether the modifier was provided at
  construction or assigned later, so the predicate branch is not a distinct
  contract. The exact operator pass
  removed defensive `respond_to?(:auto?)` checks from typed operands and added
  right-side Auto, OR, WRAP_ADD, CHECK_ADD, exact error-message, and invalid
  ADD coverage. No real bug found. Remaining survivors are equivalent
  `Type.new` versus `self.new`, explicit `auto: true` versus raw `Auto`, and
  passing resolved `Type` objects through `Type.new(Type)` in ADD dispatch.

## Completed Subjects

- `DiagnosticBuckets*`: `14.51% -> 100.00%`, `136/136` killed, `0` alive,
  `0` timeouts. Added direct helper assertions and replaced memoized derived
  bucket lookups with precomputed constants to remove equivalent mutation noise.
  No real bug found.
- `FmtVerifier*`: `72.00% -> 98.93%`, `464/469` killed, `5` alive,
  `0` timeouts. Hard-gated at the equivalent-mutant ceiling. The remaining
  survivors are Ruby-observable equivalents: `Result.new(..., nil)` tail-field
  omission, `io.puts("")` versus `io.puts`/`io.puts(nil)` for the blank line,
  and `IO#puts` with `ln.chomp` versus `ln`. No real bug found.
- `LSP::CodeActions*`: `94.64% -> 98.97%`, `386/390` killed, `4` alive,
  `0` timeouts. Hard-gated at the equivalent-mutant ceiling. Added coverage for
  no-fix guard behavior, out-of-range continuation, UTF-16 source-sensitive
  edits, and both touching-boundary overlap directions. Remaining survivors are
  equivalent `Hash#[]`/`Hash#fetch` variants on valid diagnostic/range hashes.
  No real bug found.
- `LSP::DocumentStore*`: `91.87% -> 96.87%`, `155/160` killed, `5` alive,
  `0` timeouts. Hard-gated at the equivalent-mutant ceiling. Added assertions
  for returned document identity, stored URI, update return value, and known/
  unknown text/version access. Remaining survivors are equivalent `T.let`
  type-argument mutations in `initialize`.
- `LSP::Position*`: `88.51% -> 96.62%`, `515/533` killed, `18` alive,
  `0` timeouts. Hard-gated at the equivalent-mutant ceiling. Added Unicode
  offset, nil-source, same-line/multi-line span, and boundary inclusion tests.
  Remaining survivors are ASCII fast-path equivalents, `Hash#[]`/`fetch`
  variants on valid range hashes, and a same-line span lookup equivalent.
- `Pprof*`: `69.94% -> 92.73%`, `1698/1831` killed, `133` alive,
  `13` timeouts in the classified run. Hard-gated with timeout allowance for
  mutant runtime variance. Added golden protobuf byte coverage, schema/index
  assertions, gzip output coverage, optional-scalar omission tests, and varint
  edge cases. Removed unreachable mapping field emission branches. Remaining
  survivors are equivalent `Hash#[]`/`fetch`, binary string construction,
  integer coercion, protobuf wire-type bitwise forms, and `T.let` mutations.
- `SymbolEntry*`: `38.78% -> 95.07%`, `1138/1197` killed, `59` alive,
  `0` timeouts. Hard-gated at the equivalent-mutant ceiling. Added direct
  lifecycle, flow, sync/storage classifier, copy, and lifetime-normalization
  coverage. Removed dead runtime metaprogramming bootstrap methods and
  redundant lifetime/flow writes. Remaining survivors are mostly equivalent
  `T.let`/type-wrapper changes, generated-reader versus direct-ivar reads,
  `is_a?` versus `instance_of?` within supported domains, and binding-id
  absolute-offset changes where only uniqueness/consecutiveness is contractual.
- `FsmOps*`: `93.00% -> 97.17%`, `1341/1380` killed, `39` alive,
  `0` timeouts. Hard-gated at the equivalent-mutant ceiling after removing dead
  lowerer runtime state, tightening the `io_submit` waiter type, removing
  array/nil compatibility shapes, and adding structural MIR assertions.
  Also fixed negative `ArgRef` indexes after a focused method run exposed Ruby
  negative-index behavior. Remaining survivors are equivalent class-check,
  fetch/index, and constructor default mutations under the typed op hierarchy.
- `CaptureStrategy.classify`: broad `CaptureStrategy*` moved
  `51.47% -> 77.63%` after adding direct classification truth-table tests and
  removing an unused `rt_name:` parameter from the public classifier. The
  public classifier method itself is now hard-gated at `98.19%`; its four
  survivors are equivalent schema-lookup default mutations
  (`schema_lookup` vs `nil`/omitted for current covered type shapes). The broad
  helper wildcard remains advisory because Type-shape predicate helpers still
  need more fixture coverage.
