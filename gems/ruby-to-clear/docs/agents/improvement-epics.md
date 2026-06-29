# Ruby-to-CLEAR Transpiler Improvement Epics

Branch context: `rb-to-clear-improv`, based on `origin/rb-to-clear`.

This document defines improvement epics for the existing `ruby-to-clear` gem.
The goal is not to build a Ruby compatibility compiler or a Grumpy-style
runtime. The goal is to translate the Ruby subset that maps cleanly to CLEAR
with near-perfect efficiency, and to leave everything else as precise,
localized comments/TODOs that are easy to repair by hand.

## Non-Goals

- Do not emulate the Ruby object model in CLEAR.
- Do not add a general runtime compatibility layer for Ruby semantics.
- Do not translate code when the generated CLEAR would be meaningfully less
  direct or less efficient than handwritten CLEAR.
- Do not hide uncertainty behind helpers with Ruby-like behavior.
- Do not treat "more accepted Ruby syntax" as success unless the emitted CLEAR
  is mechanically clear, efficient, and reviewable.

## Success Criteria

- Supported constructs emit direct CLEAR with no hidden runtime tax.
- Unsupported constructs preserve the original Ruby source as local comments.
- Mixed constructs preserve all safely translated inner/outer structure.
- The output is deterministic and source-oriented enough for manual repair.
- The audit process identifies the next highest-value handler by observed
  source frequency and risk, not by speculation.

## Epic 1: Partial Translation Instead Of Whole-Subtree Loss

Problem:

The current fallback model is too coarse. If an unsupported inner node appears
inside a partially translatable parent, the parent can collapse into a comment
for the entire source slice. That loses useful translated structure and creates
larger manual repair regions than necessary.

Direction:

- Introduce an internal translation result shape with at least `complete`,
  `partial`, and `unsupported` states.
- Let visitors compose child results instead of detecting unsupported output by
  string search.
- Emit localized TODO comments for only the unsupported source spans.
- Preserve translated siblings, parent control structure, indentation, and
  source ordering.
- Keep strict mode available, but make lax/repair mode produce maximally useful
  partial output.

Example target behavior:

```ruby
if ok
  x = supported_call(1)
  y = dynamic_send(:foo)
end
```

Should become a real CLEAR `IF` with the supported assignment translated and
only the dynamic call commented, not a commented-out `if` block.

Acceptance:

- Fixtures prove unsupported expressions inside `if`, `case`, method bodies,
  array/hash literals, interpolated strings, and call arguments do not erase
  surrounding translatable structure.
- Unsupported comments include node type, source location, and original Ruby
  source.

## Epic 2: Fail-Closed Confidence Model

Problem:

The translator should be aggressive about preserving structure but conservative
about claiming semantic equivalence. Today "supported" and "unsupported" are
mostly visitor-presence decisions.

Direction:

- Classify translations as exact, mechanical-but-needs-review, or unsupported.
- Require exact/mechanical handlers to state their assumptions in code or tests.
- Make risky handlers fail closed when receiver kind, argument shape, block
  shape, or control flow is outside the known subset.
- Prefer explicit TODO markers over helper calls that smuggle Ruby semantics
  into CLEAR.

Acceptance:

- Registry handlers can reject unsupported receiver/argument/block shapes with
  localized TODOs.
- Golden tests cover both accepted and rejected forms for every nontrivial
  handler.

## Epic 3: Context-Aware Method Registry

Problem:

`MethodRegistry` is currently keyed mostly by method name. That is not enough:
Ruby method names are overloaded across strings, arrays, hashes, sets, files,
compiler domain objects, and DSLs.

Direction:

- Pass receiver kind and any known type/shape information into registry lookup.
- Split generic method handlers from receiver-specific adapters.
- Prefer entries like `Array#map`, `Hash#each`, `Set#include?`,
  `String#gsub_literal`, and `File.read` over unqualified names.
- Keep unknown receivers as ordinary calls only when the call maps directly to
  valid CLEAR syntax.
- Require receiver-aware tests for common overloaded names such as `new`,
  `[]`, `each`, `map`, `include?`, `size`, `empty?`, and `to_s`.

Acceptance:

- The same Ruby method name can produce different CLEAR only when receiver
  shape proves the difference.
- Ambiguous receiver cases emit ordinary direct calls or TODOs, not guessed
  stdlib translations.

## Epic 4: Block Lowering For The Common Safe Subset

Problem:

Blocks are common and mostly regular, but block control flow is where Ruby
semantics can diverge sharply from direct CLEAR.

Direction:

- Keep expression-only `map`, `select`, and `reduce` support.
- Add safe handlers for high-frequency collection shapes:
  `filter_map`, `flat_map`, `reject`, `any?`, `all?`, `find`, `sort_by`,
  `each_with_index`, `each_value`, and `each_with_object`.
- Treat `next` inside known enumerable blocks as a first-class case when it has
  a direct CLEAR equivalent.
- Emit TODOs for nonlocal `return`, `break`, `rescue`, `ensure`, `super`, and
  `yield` unless the enclosing call has a proven safe lowering.
- Support multi-statement blocks only for known loop-like lowerings where
  statement order and mutation are direct.

Acceptance:

- Audit-backed fixtures cover the top block callee and parameter shapes.
- Unsupported block control flow comments only the unsafe statement or block
  region, not the surrounding method when possible.

## Epic 5: Thin Compiler-Hosting Stdlib Adapters

Problem:

The self-hosting path needs recurring Ruby stdlib behavior, but a broad Ruby
stdlib clone would violate the efficiency and clarity goals.

Direction:

- Build small CLEAR-side compiler-hosting adapters for recurring surfaces:
  file read/write/list/path helpers, stable maps/sets, JSON parse/emit,
  string scanning, limited regexp support, CLI option parsing, and process
  execution.
- Keep adapters narrow and explicit. Each adapter should document ordering,
  allocation, nil/error behavior, and unsupported Ruby semantics.
- Map only call shapes that correspond to those adapters directly.
- Leave unsupported regexp and scanner behavior as comments with source text.

Priority surfaces:

- `Set.new`, `Set.[]`
- `File.exist?`, `File.join`, `File.expand_path`, `File.readlines`, `File.read`
- `Dir.glob`
- `JSON.parse`
- `Regexp.escape`
- `StringScanner.new`
- option parsing and process execution only where needed for compiler hosting

Acceptance:

- Every stdlib adapter has focused translation tests and direct CLEAR examples.
- No adapter attempts to preserve broad Ruby behavior beyond compiler-hosting
  requirements.

## Epic 6: Sorbet And Shape Metadata As Translation Fuel

Problem:

Sorbet annotations and common Ruby data-shape idioms can improve emitted CLEAR
without requiring semantic inference from scratch.

Direction:

- Continue parsing `sig` for parameter and return types.
- Improve handling of `T::Array`, `T::Hash`, `T::Set`, `T.nilable`, simple
  `T.any(..., NilClass)`, and relevant enum/struct forms.
- Drop Sorbet-only runtime DSL output when it has no CLEAR runtime meaning.
- Translate `Struct.new`, `T::Struct`, simple attrs, and constant records into
  explicit CLEAR structs when field sets are static.
- Use shape metadata to improve constructor and collection literal output.

Acceptance:

- Sorbet-only constructs either improve CLEAR types or disappear; they never
  produce runtime compatibility scaffolding.
- Static record shapes produce explicit CLEAR fields with stable ordering.

## Epic 7: Dynamic Ruby As Refactor Targets, Not Runtime Features

Problem:

Dynamic Ruby features are low-frequency but high-risk. Translating them by
runtime emulation would undermine the project.

Direction:

- Treat `send`, `public_send`, `const_get`, `instance_variable_get`,
  `define_method`, `method_missing`, `eval`, and `instance_eval` as explicit
  portability blockers.
- Where the target set is finite, recommend or generate closed dispatch tables.
- Where the dynamic access crosses private state, prefer Ruby source refactors
  before translation.
- Keep TODO output specific enough to guide the refactor.

Acceptance:

- Audit output groups dynamic/reflection sites by category and sample location.
- The design never introduces a generic Ruby dynamic dispatch runtime in CLEAR.

## Epic 8: Audit-Driven Backlog And Progress Metrics

Problem:

Feature selection should follow observed source shapes. The existing Prism audit
already captures useful data, but it should drive implementation order more
directly.

Direction:

- Treat the audit script as the roadmap driver. A developer should be able to
  run a command against a directory, such as:

  ```text
  ruby gems/ruby-to-clear/exe/ruby-to-clear-audit --glob 'src/**/*.rb' --markdown
  ```

  and get a ranked implementation backlog for the transpiler.
- Evolve the existing `ruby-to-clear-audit` audit toward this roadmap mode
  instead of creating a separate planning workflow.
- Extend the audit to run the transpiler and report complete, partial, and
  unsupported counts by node type, call shape, receiver kind, and block shape.
- Track largest unsupported source-slice regions separately from most frequent
  nodes.
- Emit samples for top unsupported shapes.
- Add a "next best handlers" report that estimates source coverage gained by
  adding one handler.
- Separate roadmap buckets by kind:
  - Prism node support, such as `CaseNode`, `KeywordHashNode`, or
    `MultiWriteNode`.
  - Call/stdlib translations, such as `list.map { ... }`, `Set.[]`,
    `File.read`, `JSON.parse`, or `StringScanner.new`.
  - Block forms, such as expression-only `map`, multi-statement `each`, or
    `next` inside enumerable blocks.
  - Ruby refactor blockers, such as `send`, `public_send`, `const_get`, and
    `instance_variable_get`.
- For each suggested feature, include frequency, sample locations, estimated
  source coverage gain, semantic risk, and whether the right action is
  "transpile", "add thin adapter", "leave TODO", or "refactor Ruby source".
- Keep audit output stable enough to compare over time.

Acceptance:

- Each new handler can cite the audit bucket it reduces.
- Progress is measured by useful translated structure and localized TODO size,
  not only by number of accepted files.
- The roadmap report can be run on `src/`, an individual compiler subdirectory,
  or a fixture corpus and produce actionable next-step recommendations.
- A proposed transpiler epic should be traceable back to audit evidence unless
  it is foundational infrastructure like the translation-result model.

## Epic 9: Output Repairability

Problem:

The generated CLEAR is an intermediate migration artifact. It should be easy to
review and repair.

Direction:

- Preserve file/module structure where practical.
- Preserve comments when Prism locations make that reliable.
- Emit source locations on TODO comments.
- Use stable temporary names and deterministic field ordering.
- Avoid formatting churn unrelated to translation.
- Make generated TODOs searchable by category, for example
  `TODO_RUBY_SEND`, `TODO_STDLIB_GAP`, `TODO_BLOCK_CONTROL_FLOW`, and
  `TODO_UNTYPED`.

Acceptance:

- A developer can jump from each TODO to the original Ruby span.
- Re-running the translator on the same input produces byte-identical output.

## Epic 10: Equivalence And Golden Testing Process

Problem:

The project needs confidence that translated pieces are exact, but it should not
wait for a full self-host before finding divergences.

Direction:

- Keep small golden tests for each visitor and registry handler.
- Add corpus fixtures from real compiler files for partial-output behavior.
- Use the Ruby compiler as the oracle for phase outputs when translating larger
  compiler slices.
- Compare tokens, AST dumps, semantic indexes, MIR, diagnostics, and emitted
  Zig one phase at a time.
- For unsupported regions, assert that the TODO output is precise and stable.

Acceptance:

- Every supported translation path has positive and negative fixtures.
- Partial translation tests prove unsupported inner nodes do not erase safe
  outer structure.

## Suggested Implementation Order

1. Add translation-result objects and localized TODO composition.
2. Convert existing visitors and registry handlers to the result model.
3. Extend `ruby-to-clear-audit` into roadmap mode with
   complete/partial/unsupported metrics and ranked next-feature suggestions.
4. Make `MethodRegistry` receiver/context-aware.
5. Add thin stdlib adapter specs for the observed top compiler-hosting calls.
6. Add safe block handlers by audited frequency.
7. Add Sorbet/shape improvements that directly improve emitted CLEAR types.
8. Add equivalence fixtures for the first real compiler slice.

This order improves the existing tool before broadening its surface area. The
first milestone should make current output more useful even when no new Ruby
constructs are supported.
