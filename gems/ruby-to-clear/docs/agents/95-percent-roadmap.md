# Ruby-to-CLEAR 95% Translation Roadmap

Audit date: 2026-06-29.

Command:

```text
ruby gems/ruby-to-clear/exe/ruby-to-clear-audit --glob 'src/**/*.rb' --markdown --top 50
```

This roadmap assumes the CLEAR-side stdlib primitives already exist. Work here
is scoped to the Ruby-to-CLEAR transpiler and small Ruby source refactors where
dynamic Ruby cannot be translated efficiently.

## Language Design Guardrails

The transpiler must not make executive language-design decisions for CLEAR.
Ruby source contains classes, modules, mixins, and dynamic dispatch, but those
features should not automatically become CLEAR namespaces, modules,
traits/interfaces, or an OOP runtime.

When a Ruby construct has no existing direct CLEAR shape, the first question is
whether CLEAR can get by without adding that feature. The preferred direction is
closer to C/Zig plus accessible functional programming: free functions,
explicit data, structs, UFCS-style calls, pipelines, and local state where it is
actually needed. A useful mental model is closer to OCaml with UFCS and explicit
state than to Java or Ruby.

For migration output, this means:

- Ruby classes should lower only where they are really static data plus
  functions over that data.
- Ruby modules should preserve organization and source location, but should not
  imply a new CLEAR module/namespace feature.
- Ruby mixins, interfaces-by-convention, and dynamic dispatch should become
  localized TODOs or source refactor targets unless an existing CLEAR pattern
  handles them directly.
- If the transpiler needs a new CLEAR language feature to translate a construct,
  it should emit a TODO and escalate that as a separate design decision.

## Baseline

Whole-codebase audit over `src/**/*.rb`:

| metric | value |
| --- | ---: |
| Ruby files | 163 |
| Parse errors | 0 |
| Source LoC | 93,037 |
| Complete files | 6 |
| Partial files | 151 |
| Failed files | 6 |
| Unsupported/commented LoC | 68,433 |
| Useful translated LoC coverage | 26.45% |

To reach 95% useful LoC coverage, unsupported/commented output must fall to at
most about 4,652 LoC. That means reclaiming roughly 63,781 LoC from the current
baseline.

The six failed files all fail on the same transpiler bug:

```text
NoMethodError: undefined method `statements' for Prism::InterpolatedStringNode
```

That should be treated as a small correctness fix, not a separate feature area.

## Directory Pressure

Current useful coverage by source area:

| area | unsupported LoC | source LoC | useful coverage |
| --- | ---: | ---: | ---: |
| `src/mir` | 27,394 | 38,580 | 28.99% |
| `src/annotator` | 17,234 | 19,712 | 12.57% |
| `src/ast` | 10,828 | 17,367 | 37.65% |
| `src/tools` | 5,097 | 8,424 | 39.49% |
| `src/backends` | 3,464 | 3,828 | 9.51% |
| `src/semantic` | 3,057 | 3,612 | 15.37% |
| `src/lsp` | 1,122 | 1,123 | 0.09% |
| `src/compiler` | 237 | 389 | 39.07% |

The 0% files are mostly not hopeless files. They are large Ruby module/class
regions collapsing into one unsupported region. The first milestone must
recover structure before optimizing smaller call translations.

## Ordered Epics

### 1. Preserve Ruby Module Structure Without Designing Namespaces

Audit signal:

- `ModuleNode`: 120 unsupported output sites.
- Many large files are 0% useful because a top-level Ruby `module` is
  unsupported.

Implementation:

- Add `ModuleNode` lowering that emits a stable migration/comment boundary and
  translates the body.
- Do not create a Ruby module runtime, trait/interface system, or new namespace
  mechanism from the transpiler.
- Preserve nested module names for TODO locations and collision diagnostics.
- Emit flat declarations where that is valid CLEAR. If flattening creates a
  collision or ambiguity, emit a localized TODO instead of choosing a new
  namespacing scheme.
- Treat mixin declarations (`include`, `extend`) as metadata or localized TODOs,
  not runtime emulation.

Acceptance:

- `ModuleNode` disappears from unsupported-output audit results.
- Large files under `src/mir`, `src/annotator`, `src/ast`, `src/backends`,
  `src/semantic`, and `src/lsp` become partial instead of fully commented.
- The emitted CLEAR does not rely on a new language-level namespace decision.

Expected impact:

- This is the highest-leverage step. It should reclaim tens of thousands of LoC
  because it unlocks translation inside top-level Ruby modules.

### 2. Support Keyword Arguments And Keyword Parameters

Audit signal:

- `KeywordHashNode`: 439 unsupported output sites.
- `ParametersNode`: 121 unsupported output sites.
- Call argument shapes include 5,730 `args=1+kw` calls and 1,043 `args=3+kw`
  calls.

Implementation:

- Stop rejecting every `KeywordHashNode` at call entry.
- Lower simple keyword calls into direct CLEAR named arguments or struct-style
  fields where the target call shape is known.
- Support required and optional keyword parameters in `DefNode` signatures.
- Fail closed on keyword splats and ambiguous forwarding.
- Add negative tests for keyword rest, keyword splat, and mixed unsupported
  destructuring.

Acceptance:

- `KeywordHashNode` and simple `ParametersNode` unsupported-output counts fall
  near zero.
- Common constructor, diagnostic, and helper calls with keyword args translate
  without wrapping the enclosing method in TODO comments.

Expected impact:

- Required for >90%. Keyword args are frequent in constructors and diagnostics,
  and currently erase useful inner method bodies.

### 3. Lower Unknown Calls With Literal Blocks

Audit signal:

- 9,021 literal blocks attached to calls.
- Top non-Sorbet block callees include `each` (925), `map` (338), `new` (319),
  `any?` (126), `each_with_index` (73), `filter_map` (64), `select` (55),
  `flat_map` (52), `each_value` (49), `find` (46), `reject` (44),
  `each_with_object` (36), `sort_by` (31), `each_pair` (25), `loop` (20),
  `map!` (20), `reverse_each` (17), `sum` (16), and `each_key` (15).

Implementation:

- Add a real `BlockNode` visitor or block lowering result object so unknown
  helper calls with blocks can preserve their bodies.
- Keep existing efficient pipeline translations for expression-only enumerable
  blocks.
- Add direct loop-like lowering for `each_with_index`, `each_key`,
  `each_value`, `each_pair`, `reverse_each`, `loop`, and simple
  multi-statement `each`.
- Support `next` inside known enumerable blocks only where it has a direct CLEAR
  equivalent.
- Leave nonlocal `return`, `break`, `yield`, `super`, `rescue`, and `ensure`
  localized as TODOs unless the enclosing block shape has an exact lowering.

Acceptance:

- Unknown block calls no longer collapse into large unsupported regions.
- Top enumerable block shapes have oracle tests using real source snippets.

Expected impact:

- Necessary to move from structural partial output to high useful LoC coverage.
  This is also where manual-repair quality improves the most.

### 4. Complete Method And Declaration Shapes

Audit signal:

- `DefNode`: 5,590 total nodes.
- `RequiredParameterNode`: 9,533 total nodes.
- `OptionalKeywordParameterNode`: 470 total nodes.
- `RequiredKeywordParameterNode`: 310 total nodes.
- Top calls include Sorbet-heavy declarations: `sig` (5,686), `params`
  (4,376), `returns` (5,045), `const` (1,552), `prop` (267),
  `type_alias` (408).

Implementation:

- Finish Sorbet erasure/type extraction for the shapes already present.
- Lower `attr_reader`, `attr_writer`, `attr_accessor`, `private`,
  `private_class_method`, `include`, and `extend` as declaration metadata or
  precise TODOs.
- Improve `T::Struct`, plain `Struct.new`, and constant-record output where
  field sets are static.
- Support singleton/class methods where the receiver is statically known.
- Translate Ruby class-like code only into structs plus functions/UFCS when the
  data and method set are static. Inheritance, mixins, and interface-like
  behavior should remain TODO/refactor targets unless CLEAR already has a direct
  construct for the specific case.

Acceptance:

- Declaration-only Ruby syntax should rarely contribute unsupported LoC.
- Unsupported declaration semantics are one-line TODOs, not whole-file comments.
- No class/mixin handler introduces hidden OOP semantics.

Expected impact:

- Medium to high. This removes syntactic Ruby/Sorbet noise so the remaining
  unsupported output represents real semantic work.

### 5. Localize Remaining Prism Node Gaps

Audit signal from unsupported output:

| node | count |
| --- | ---: |
| `MultiWriteNode` | 20 |
| `CallOperatorWriteNode` | 12 |
| `IndexOrWriteNode` | 10 |
| `SplatNode` | 8 |
| `YieldNode` | 6 |
| `AliasMethodNode` | 3 |
| `BeginNode` | 3 |
| `ClassVariableReadNode` | 3 |
| `ClassVariableWriteNode` | 3 |
| `GlobalVariableReadNode` | 3 |
| `InstanceVariableOrWriteNode` | 3 |
| `SingletonClassNode` | 3 |

Implementation:

- Add exact handlers for simple assignment variants:
  `a ||= b`, `h[k] ||= v`, `obj.x += y`, and literal destructuring.
- Localize unsupported splats and forwarding instead of commenting the enclosing
  call or method.
- Treat aliases, globals, class variables, singleton classes, `yield`, and
  forwarding `super` as refactor/TODO surfaces unless an exact static lowering
  is obvious.

Acceptance:

- These node types do not expand into multi-line unsupported regions.
- Each has positive and negative oracle fixtures.

Expected impact:

- Medium. Counts are low now, but they will become more visible after module and
  block support exposes more inner code.

### 6. Regex, Scanner, And Interpolation Surface

Audit signal:

- `RegularExpressionNode`: 183 total nodes.
- `InterpolatedStringNode`: 1,812 total nodes.
- `EmbeddedStatementsNode`: 3,005 total nodes.
- Current six hard transpiler failures are all interpolated-string visitor bugs.
- Stdlib sites include `Regexp.escape` (12), `Regexp.last_match` (6),
  `Regexp.new` (1), and `StringScanner.new` (2).

Implementation:

- Fix interpolated string traversal for all Prism part shapes.
- Lower regex literals only to explicit CLEAR regex/scanner primitives once the
  stdlib package exists.
- Fail closed on Ruby's implicit regexp match state (`Regexp.last_match`, `$1`,
  etc.) and recommend explicit match-result variables.

Acceptance:

- No files fail the audit pass.
- Regex literals become either direct CLEAR regex values or precise TODOs with
  the original pattern preserved.

Expected impact:

- Small for raw LoC, high for eliminating hard failures and lexer/parser source
  friction.

### 7. Dynamic Ruby Refactor Pass

Audit signal:

| category | calls |
| --- | ---: |
| dynamic instance state | 96 |
| dynamic dispatch | 36 |
| dynamic constant lookup | 5 |
| dynamic definition | 3 |

Implementation:

- Replace `instance_variable_get`/`instance_variable_set` with declared fields
  or typed side tables.
- Replace `send`, `__send__`, and `public_send` with closed case/table
  dispatch where the method set is finite.
- Replace `const_get`/`const_defined?` with explicit registries.
- Replace `define_method` with generated explicit methods or a closed
  dispatcher.

Acceptance:

- Dynamic/reflection blockers are either gone from the Ruby source or emitted as
  small localized TODOs.
- No generic Ruby dynamic dispatch runtime is introduced in CLEAR.

Expected impact:

- Required for the last 5-10%. These sites are low frequency but high semantic
  risk; they should be treated as source-portability work.

### 8. Audit Tool Upgrade For Coverage-Gain Accounting

Audit signal:

- Current audit reports aggregate unsupported LoC and unsupported node counts,
  but not line impact by file/node/feature.

Implementation:

- Add per-file coverage rows.
- Attribute unsupported source spans to node type and sample location.
- Add "estimated LoC reclaimed" for each roadmap bucket.
- Emit a stable machine-readable format for tracking trend over commits.

Acceptance:

- Each phase can cite coverage before/after with the same command.
- The tool can answer whether the next best handler is syntax, block lowering,
  stdlib mapping, or Ruby source refactor.

Expected impact:

- Does not directly translate more code, but prevents wasted implementation
  effort and makes the 95% target measurable.

## Work Estimate

This is not a runtime-compatibility project. Reaching roughly 95% useful LoC is
mostly a sequence of narrow transpiler handlers plus a small dynamic-Ruby source
refactor pass.

Practical size estimate:

- Essential to reach high partial coverage: epics 1 and 2.
- Essential to reach >90% useful coverage: epics 1 through 4.
- Needed for ~95%: epics 5 through 7 plus audit-tool verification.
- Expected implementation size: roughly 25-35 small handlers/refactor slices,
  each with oracle-style positive and negative fixtures.
- Expected source refactor size: focused patches for about 140 dynamic or
  reflection call sites, many of which can be grouped by helper.

The first re-audit after `ModuleNode` and keyword support is the key checkpoint.
If useful coverage does not jump substantially there, the audit tool needs
line-impact attribution before continuing.
