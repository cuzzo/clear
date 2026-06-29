# CLEAR Self-Host Plan

Goal: port the Ruby compiler in `src/` to CLEAR using a deterministic bulk
translator, then use LLM-assisted repair and oracle tests to reach a real
stage1/stage2 self-host.

This is not a manual line-by-line rewrite plan. The intended path is:

1. Build a Ruby-to-CLEAR translator that covers the repetitive 70-80%.
2. Use its failures to define a CLEAR-portable Ruby subset.
3. Refactor Ruby code only where it materially improves mechanical translation.
4. Add missing CLEAR stdlib/compiler-hosting features.
5. Drive the remaining gap down with phase-by-phase equivalence tests.

## Target

The practical target is:

- 70-80% translated directly by script.
- 90-95% after Ruby refactors remove high-volume dynamic patterns.
- About 99% practical completion after adding missing CLEAR stdlib support and
  hand-fixing the semantic hotspots.

The final 1% is expected to be judgment work: ownership invariants, cleanup,
FSM paths, dynamic Ruby behavior, and stage1/stage2 determinism.

## Scope

Initial self-hosting scope is compiler core only:

- lexer/parser;
- AST and type model;
- annotator and semantic analysis;
- MIR prep, lowering, checker, and emitter;
- compiler frontend/module importer/transpiler path;
- enough CLI surface to build, check, transpile, and run tests.

Out of initial scope:

- LSP;
- formatter;
- migration tools;
- pprof/doctor tooling;
- fuzz tool implementation itself;
- Espalier and other repo-maintenance tools.

Those can be ported after the compiler can build itself.

## Translator Strategy

Implement the bulk translator with Ruby's `Prism` AST rather than regexes.

The translator should preserve:

- file structure;
- comments where practical;
- source locations;
- original names;
- pass/fact/type boundaries;
- TODO markers for unsupported Ruby features.

It should translate high-volume Ruby idioms:

- `class`, `module`, constants, and methods;
- `T::Struct`, `T::Enum`, and `Struct.new`;
- Sorbet `sig` types where obvious;
- arrays, hashes, sets, symbols, strings, literals;
- `if`, `case`, `while`, simple iterators, and blocks;
- keyword arguments;
- `attr_reader` and `attr_accessor`;
- simple `Enumerable` chains;
- common error-helper patterns.

The translator should not hide uncertainty. Unsupported constructs should
become explicit markers such as:

```clear
TODO_RUBY_SEND(...)
TODO_UNTYPED(...)
TODO_BLOCK_CONTROL_FLOW(...)
TODO_STDLIB_GAP(...)
```

The goal is deterministic, reviewable output, not perfect output.

## Portability Audit

Before doing broad Ruby refactors, build a blocker inventory from the
translator. Add a tool such as:

```text
tools/clear_portability_audit.rb
```

The audit should score files by translation blockers:

- dynamic dispatch: `send`, `public_send`, method-name construction;
- reflection: `const_get`, `instance_variable_get`, dynamic class checks;
- metaprogramming: `define_method`, `method_missing`, `eval`, `instance_eval`;
- broad `T.untyped` / `T.unsafe`;
- ad hoc hashes used as records;
- raw `Struct.new` with behavior;
- `include`-heavy shared receiver state;
- block control flow: nonlocal `return`, complex `break` / `next`;
- Ruby stdlib dependencies: `StringScanner`, regex-heavy parsing, `File`,
  `Dir`, `JSON`, `YAML`, `OptionParser`, `Open3`, `Set`.

Refactor by blocker category, not by file.

## Prism Audit Findings

The first migration audit command lives in the `ruby-to-clear` gem and is run as:

```text
ruby gems/ruby-to-clear/exe/ruby-to-clear-audit --top 30
```

Current `src/**/*.rb` results:

- 162 Ruby files parse cleanly with Prism.
- 89 unique Prism node types appear across 453,193 total nodes.
- Top 10 node types cover 79.84% of nodes.
- Top 20 node types cover 92.36% of nodes.
- Top 30 node types cover 97.05% of nodes.
- Top 40 node types cover 99.09% of nodes.

The practical conclusion is that the translator should not try to solve Ruby in
the abstract. It should cover the common node and call shapes first, emit clear
TODO markers for rare Ruby semantics, and use the audit output to drive each
coverage pass.

### CallNode Findings

`CallNode` is the largest surface:

- 88,805 `CallNode` instances.
- 5,943 unique call names.
- 8,938 calls have a block-like attachment.
- 8,670 of those are literal `BlockNode` blocks.
- 268 are `BlockArgumentNode` block forwarding or `&block` style calls.

The top call names are dominated by Sorbet DSL and ordinary Ruby calls:

- `sig`: 5,511
- `new`: 5,356
- `[]`: 4,985
- `returns`: 4,902
- `params`: 4,267
- `nilable`: 2,154
- `is_a?`: 1,780
- `==`: 1,715
- `const`: 1,543
- `untyped`: 1,325
- `<<`: 1,284
- `name`: 1,238
- `let`: 1,163
- `bind`: 1,100

Receiver kinds are also concentrated:

- implicit receiver: 29,353
- local receiver: 25,037
- call-result receiver: 13,918
- constant receiver: 11,766
- constant-path receiver: 6,272

Argument shapes are simple enough for a high-coverage first pass:

- `args=0`: 35,718
- `args=1`: 33,280
- `args=2`: 9,522
- `args=1+kw`: 5,582

Those four shapes cover 84,102 of 88,805 calls, or about 94.7% of the call
surface. This supports a translation strategy centered on a small set of call
forms plus named handlers for high-volume DSL calls.

The high-risk dynamic/reflection calls are low-volume and should be refactored
or manually mapped rather than generalized in the translator:

- `instance_variable_get`: 44
- `public_send`: 17
- `send`: 16
- `const_get`: 7
- `define_method`: 3

### Dynamic/Reflection Design Inventory

Design judgment:

- None of these dynamic/reflection forms should survive unchanged in the
  self-hosted CLEAR compiler.
- Some are reasonable Ruby host-code design: bounded generated delegation,
  registry hydration, enum-like constant lookup, and lazy optional metadata
  accessors.
- The raw `send` sites are the highest-risk group because several bypass Ruby
  visibility or hide closed dispatch sets from the translator.

`define_method` inventory:

- `src/ast/symbol_entry.rb:101`, `:104`, `:111` generate `SymbolEntry`
  delegation methods for lifecycle and flow facts.
- Judgment: acceptable Ruby design because the delegated fields are declared by
  explicit `lifecycle_attr` / `flow_attr` calls. For CLEAR, generate explicit
  methods or emit them from a static table.

`public_send` inventory:

- `src/ast/symbol_entry.rb:102`, `:105`, `:112`: generated lifecycle/flow
  delegation. Not visitor dispatch.
- `src/annotator/helpers/intrinsic_registry.rb:52`, `:54`, `:55`, `:56`,
  `:58`, `:59`, `:61`: bounded registry-key setter hydration for
  `IntrinsicEmit`. Not visitor dispatch; use an explicit key-to-setter case.
- `src/mir/hoist.rb:905`, `:908`: reflective getter/setter for a MIR statement
  attribute. Not visitor dispatch; use a typed operation or case over fields.
- `src/mir/mir_pass.rb:711`, `src/mir/lowering/functions.rb:1981`,
  `src/mir/cleanup_classifier.rb:888`, `src/tools/clear_fix_support.rb:438`,
  `src/annotator/helpers/function_signature.rb:707`: guarded reflective
  property reads such as `name`, `symbol`, `storage`, or token integer fields.
  These are not visitor dispatch; replace with explicit protocols or typed
  unions.

Conclusion: there are `public_send` calls that are not visitor/dispatch. In
fact, essentially all current `public_send` sites are reflective property access
or bounded schema hydration rather than visitor dispatch.

For migration, treat these as explicit protocol work rather than visitor work:
`public_send` is mostly being used to avoid spelling out property access,
setter hydration, or token-field access. That is acceptable Ruby ergonomics, but
it is not a good compiler self-hosting surface.

`send` inventory:

- `src/ast/parser.rb:529`: parser grammar action dispatch via
  `send("parse_#{item}")`. This sits after `private` in `ClearParser`, so it
  depends on Ruby reflective access to private parse methods. Replace with a
  generated grammar action table or explicit case.
- `src/mir/hoist.rb:508`: `parent.send(field)` for dynamic AST child access.
  Replace with an explicit field case or child-access protocol.
- `src/mir/hoist.rb:631`: `T.unsafe(self).send(:call_union_return_needs_hoist?, ...)`.
  This appears to be an unnecessary dynamic call to a lowering helper; make the
  helper directly callable through the module boundary.
- `src/semantic/escape_analysis.rb:69`, `:72`: calls private class helper
  `EscapeAnalysis.symbol_heap?` through `send`. Expose a named query or move the
  logic into the nested context.
- `src/semantic/escape_analysis.rb:381`: dispatches bounded escape-sink handler
  symbols to private class methods. This is a reasonable Ruby table-dispatch
  pattern, but CLEAR should lower it to an enum/case or a table of callable
  functions.
- `src/mir/control_flow.rb:1967`, `:1986`, `:2011`: reaches into private
  `OwnershipDataflow` move collectors from `UseAfterMoveChecker`. This is the
  clearest private-boundary violation; expose a public collector API or split a
  shared service object out of `OwnershipDataflow`.
- `src/mir/lowering/capabilities.rb:630`, `src/mir/lowering/variables.rb:1178`:
  dynamic calls to `placement_for_node`. This helper is directly callable
  elsewhere, so these should become direct calls.
- `src/annotator/annotator.rb:702`: visitor dispatch via
  `send("visit_#{node.class.name.split("::").last}", node)`. This is normal Ruby
  visitor style but should become generated closed dispatch before translation.
- `src/annotator/helpers/function_return.rb:112`: host inference dispatch from
  a bounded stdlib return spec symbol. Replace with an explicit inference
  function table.
- `src/annotator/helpers/function_signature.rb:342`: class wrapper calls private
  `FunctionSignature#sync_from_function_def!` via `send`. Replace with a public
  internal helper or make the mutation path explicit.
- `src/annotator/helpers/method_analysis.rb:92`: dynamic setter for the stdlib
  method tag field. Replace with a case over `pool_method`, `set_method`, and
  `map_method`.
- `src/annotator/helpers/function_analysis.rb:1341`: dynamic call to
  `full_type!`. The method is public, so this is not a privacy issue, but it
  should become a typed protocol call.

`send` severity:

- Bad/private-boundary violations:
  `src/ast/parser.rb:529`, `src/semantic/escape_analysis.rb:69`, `:72`,
  `src/mir/control_flow.rb:1967`, `:1986`, `:2011`, and
  `src/annotator/helpers/function_signature.rb:342`.
- Bounded dynamic dispatch that should become closed dispatch:
  `src/annotator/annotator.rb:702`,
  `src/semantic/escape_analysis.rb:381`, and
  `src/annotator/helpers/function_return.rb:112`.
- Dynamic field/helper access that should become direct calls or typed
  protocols: `src/mir/hoist.rb:508`, `:631`,
  `src/mir/lowering/capabilities.rb:630`,
  `src/mir/lowering/variables.rb:1178`,
  `src/annotator/helpers/method_analysis.rb:92`, and
  `src/annotator/helpers/function_analysis.rb:1341`.

The parser and ownership-dataflow cases are the most important to remove first:
they cross abstraction boundaries and make the eventual CLEAR version harder to
type, harder to translate, and harder to audit.

`const_get` inventory:

- `src/annotator/helpers/function_return.rb:73`: enum-like lookup for
  `FunctionReturn::Kind`. Use an explicit symbol-to-kind map.
- `src/backends/transpiler.rb:284`: CLI log-level lookup through
  `Logger.const_get`. Use a fixed log-level map.
- `src/annotator/helpers/intrinsic_registry.rb:211`, `:283`, `:284`: registry
  discovery and map-method alias lookup through top-level constants. Reasonable
  during Ruby bootstrapping, but translate to explicit registry maps.
- `src/mir/mir_checker.rb:1253`: checker introspection over `MIR.constants`.
  Acceptable for a Ruby verifier, but a self-hosted checker should iterate an
  explicit registry.
- `src/mir/mir.rb:4800`: optional legacy MIR ownership node compatibility list.
  This is compatibility/refactor glue; replace with a static list once the
  legacy names settle.

`instance_variable_get` inventory:

- Mostly optional metadata access on AST/MIR nodes, for example typed wrappers
  around `@type_object`, `@matched_signature`, `@symbol`, FSM ownership facts,
  destroy actions, and boundary facts.
- Some are mixin escape hatches, such as `src/ast/source_error.rb` reading
  `@source_code`, `src/ast/scope.rb` reading `@scope_stack`, and parser/literal
  metadata such as `@suppress_struct_lit` or `@constructor_collection`.
- The worst instances are cross-object private-state reads:
  `src/ast/symbol_entry.rb:432`, `src/mir/control_flow.rb:256`, `:257`, and
  `:1310`.
- Judgment: not all are bad Ruby, but they are bad compiler-porting surface.
  Convert recurrent metadata to explicit fields/accessors and expose narrow
  public APIs for cross-object state.

Refactor priority:

1. Remove raw `send` calls that cross private boundaries.
2. Replace visitor/parser dynamic dispatch with generated closed dispatch.
3. Replace `public_send` property reflection with explicit typed protocols.
4. Turn `const_get` registries into explicit maps.
5. Convert repeated `instance_variable_get` metadata slots into declared fields
   or typed side-table records.

The stdlib surface is also adapter-friendly. The main recurring calls are
`Set.new`, `Set.[]`, `File.exist?`, `File.join`, `File.expand_path`,
`File.readlines`, `File.read`, `Dir.glob`, `JSON.parse`, `Regexp.escape`, and
`StringScanner.new`.

CallNode migration priority:

1. Translate Sorbet signatures and constants into CLEAR declarations or dropped
   type metadata.
2. Translate simple implicit/local/constant receiver calls with 0-2 positional
   args and one-keyword-argument forms.
3. Add named handlers for common collection calls: `each`, `map`, `filter_map`,
   `flat_map`, `select`, `reject`, `any?`, `all?`, `find`, `sort_by`, and
   `each_with_object`.
4. Add adapters for the recurring file, JSON, regexp, set, and scanner calls.
5. Refactor or hand-map the small dynamic/reflection set.

### BlockNode Findings

Literal blocks are numerous but mostly regular:

- 8,670 literal `BlockNode` blocks attached to calls.
- 152 unique block callee names.
- `sig` accounts for 5,511 blocks.
- `type_alias` accounts for 255 blocks.
- After ignoring Sorbet-only blocks, the real runtime/control block surface is
  about 2,900 blocks.

Top runtime block callees include:

- `each`: 915
- `map`: 337
- `new`: 319
- `any?`: 128
- `each_with_index`: 72
- `filter_map`: 62
- `select`: 55
- `flat_map`: 53
- `each_value`: 49
- `find`: 48
- `reject`: 44
- `lambda`: 39
- `each_with_object`: 37

Block parameter shapes are concentrated:

- no explicit block parameters: 6,423
- one required parameter: 1,783
- two required parameters: 457
- three required parameters: 6
- four required parameters: 1

Block bodies are usually small:

- one statement: 7,527
- two to three statements: 607
- four to eight statements: 421
- nine or more statements: 114
- empty: 1

Control-flow nodes inside blocks are the main semantic hazard:

- `NextNode`: 691
- `ReturnNode`: 67
- `BreakNode`: 44
- `SuperNode`: 35
- `RescueModifierNode`: 31
- `ForwardingSuperNode`: 20
- `YieldNode`: 14
- `EnsureNode`: 4
- `RescueNode`: 3

Most blocks can be translated mechanically as iterator closures or inlined loops.
The translator should treat `next` in enumerator blocks as a first-class case,
but nonlocal `return`, `break`, rescue/ensure inside blocks, `super`, and
`yield` should initially emit explicit TODO markers unless the surrounding call
has a known safe lowering.

BlockNode migration priority:

1. Drop or convert Sorbet `sig` and `type_alias` blocks before general block
   lowering.
2. Lower one-statement `each` blocks into loops.
3. Lower expression-producing collection blocks for `map`, `filter_map`,
   `flat_map`, `select`, `reject`, `any?`, `all?`, `find`, and `sort_by`.
4. Lower `T::Struct.new` / class-builder `new` blocks through a dedicated
   structural handler.
5. Emit TODO markers for nonlocal block control flow until the Ruby source is
   refactored or the CLEAR equivalent is explicit.

### Budget Note

The earlier budget still looks reasonable after the audit:

- M0 audit and translator skeleton: 1-3 days.
- M1 bulk translator to about 70-80% useful output: about 1 focused week.
- M2 refactor pass to move toward 90-95% useful output: 1-3 weeks, dominated by
  dynamic dispatch cleanup, stdlib adapters, and block-control edge cases.

The audit makes the M1 estimate more credible: the breadth is large, but the
shape distribution is highly concentrated.

## Ruby Refactor Targets

High-ROI refactors before final translation:

- Replace `send("visit_#{...}")` with explicit dispatch tables or `case`
  dispatch.
- Reduce include-heavy receiver-state modules in annotator and lowering.
- Pass explicit state/context objects where practical.
- Convert ad hoc hashes into named typed fact/plan classes.
- Replace `Struct.new` nodes with named classes/records where those nodes cross
  compiler phase boundaries.
- Replace symbol protocols with closed enums or named constants when the set is
  finite.
- Centralize file, JSON, option parsing, regex/scanner, and process execution
  behind adapters.
- Make visitor/emitter/checker dispatch fail closed over explicit node lists.
- Remove avoidable `T.unsafe` and narrow high-impact `T.untyped`.

Do not refactor unrelated code for aesthetics. The refactor criterion is:

> Does this make Ruby behavior easier to translate mechanically while preserving
> existing tests and architecture?

## CLEAR Stdlib Gaps

Track missing host-language features as first-class dependencies. Likely gaps:

- file read/write/listing/path helpers;
- string scanning and regex equivalents;
- maps/sets with stable iteration behavior where tests depend on it;
- JSON parsing/emission for compiler options and metadata;
- CLI option parsing;
- process execution for build/test orchestration;
- source span and diagnostic formatting helpers;
- stable sort and collection utilities used by compiler passes.

Prefer small compiler-hosting libraries over broad general-purpose stdlib work.

## Equivalence Harness

Use the Ruby compiler as the oracle until stage2 is trusted.

Add phase dumps and comparison gates for:

- tokens;
- parsed AST;
- annotated AST or semantic index;
- MIR after each major pass;
- MIR checker output;
- emitted Zig;
- compiler diagnostics.

The port should advance by matching one phase at a time. Do not debug final
emitted binaries when the AST or MIR already diverges.

## Milestones

### M0: Translator Skeleton

- Prism parser loads all `src/**/*.rb`.
- Emits CLEAR files with preserved module/file structure.
- Unsupported constructs are explicit TODO markers.

Expected time: 1-3 days.

### M1: Bulk Translation

- AST/MIR data definitions translate mostly mechanically.
- Simple helper modules and emitter cases translate.
- Translator covers roughly 70-80% of `src/`.

Expected time: about 1 week.

### M2: Portability Refactor Pass

- Audit identifies top blocker categories.
- Ruby code is refactored to remove high-volume dynamic patterns.
- Existing Ruby specs/transpile tests remain green.
- Translator reaches roughly 90-95% useful output.

Expected time: 1-3 weeks depending on blocker concentration.

### M3: CLEAR Compiler Builds Under Ruby Compiler

- Ruby compiler can compile the CLEAR compiler source.
- Stage0 produces a stage1 CLEAR compiler binary.
- Stage1 can lex, parse, and check simple programs.

Expected time: 4-8 weeks from start in a focused push.

### M4: Phase Equivalence

- Stage1 matches Ruby compiler outputs on token, AST, MIR, and emitted Zig
  golden tests for the core corpus.
- Core transpile tests pass.
- Divergences are classified as intentional or fixed.

Expected time: 6-10 weeks from start.

### M5: Real Self-Host

- Stage1 builds stage2.
- Stage1 and stage2 outputs match for the compiler.
- Stage2 passes core specs/transpile tests.
- Examples and benchmarks compile.

Expected time: 8-12 weeks if CLEAR stdlib gaps are modest.

### M6: Release-Quality Self-Host

- Fuzz suite passes.
- Mutant gates pass or known gaps are documented.
- Benchmarks compile and representative runtime benchmarks run.
- Stage2 compiler is used in CI as an optional or required path.

Expected time: 3+ months depending on assurance bar.

## Success Criteria

A self-host counts only when:

- the Ruby compiler is stage0;
- stage0 builds a CLEAR compiler;
- the CLEAR compiler builds itself;
- stage1 and stage2 agree on compiler output;
- the self-hosted compiler passes the core test/transpile corpus;
- MIR checker, fuzz, and mutation gates run against the self-hosted compiler.

Anything short of that is a porting milestone, not self-hosting.

## Risks

- Dynamic Ruby behavior hides semantic decisions the translator cannot infer.
- The annotator and MIR lowering include large shared-state surfaces.
- CLEAR stdlib gaps may dominate once mechanical translation is done.
- Stage1/stage2 mismatches can be slow to localize without phase dumps.
- LLM-generated repairs may drift style or duplicate abstractions unless guided
  by deterministic translator output and tests.

## Operating Rule

Script for volume. LLM for judgment. Tests for truth.
