# CLEAR Self-Host Status

This document records the current state of the Ruby compiler to CLEAR
translation effort and the work remaining before generated `compiler/src/*.clear`
files should be committed as source.

Measured on 2026-07-08 against `compiler/ruby/**/*.rb` using the current
`gems/ruby-to-clear` translator.

## Commit Policy

Do not commit generated `compiler/src/**/*.clear` as source until:

- the relevant Ruby source set translates with no missing generated
  dependencies;
- generated files needed by `REQUIRE` are present;
- unsupported placeholders are limited to small, explicitly reviewed TODOs;
- `./clear build compiler/src/ast/parser.clear` or the equivalent stage target
  gets past dependency resolution and parser/type-checking;
- manual fixes are minimal enough that regeneration remains practical.

The current generated output is not there yet. `compiler/src/ast/parser.clear`
now requires generated helper files, and the current dirty tree has missing
dependencies such as `compiler/src/annotator/helpers/function_return.clear`.
Several generated files still contain `unsupportedRuby(...)` placeholders.

## Current Metrics

Full compiler Ruby scope:

| Metric | Clean | Total | Percent |
| --- | ---: | ---: | ---: |
| Nonblank source lines | 90,863 | 94,332 | 96.32% |
| Prism node sites | 465,849 | 467,314 | 99.69% |
| Ruby `CallNode` sites | 89,811 | 90,728 | 98.99% |
| Call-related sites | 89,448 | 90,728 | 98.59% |
| Function bodies | 4,944 | 5,691 | 86.87% |

Strict file status:

- files: 165
- parse errors: 0
- complete files: 52
- partial files: 113
- failed transpiles: 0
- dirty function bodies: 747

Current self-host seed set, which matches the files represented by the local
generated `compiler/src/**/*.clear` work plus missing required helper sources:

| Metric | Percent |
| --- | ---: |
| Nonblank source lines clean | 98.63% |
| Prism node sites clean | 99.85% |
| Ruby `CallNode` sites clean | 99.73% |
| Function bodies clean | 93.71% |

Seed set counts:

- files: 18
- nonblank source lines: 17,772
- unsupported line ranges: 243
- functions: 1,113
- dirty function bodies: 70

The line metric is already above the 95% target. The remaining problem is that
unsupported sites are spread across enough functions to keep generated code from
being buildable.

## Lexer Status

Updated 2026-07-08:

- `compiler/ruby/ast/lexer.rb` now translates with `unsupportedRuby(...)` count
  `0` in the default `ruby-to-clear` mode.
- With `gems/ruby-to-clear/config/compiler_regex_helpers.json`, the lexer also
  translates with `unsupportedRuby(...)` count `0`.
- The configured lexer output emits inline `EXTERN` declarations for
  `compiler_regex`, maps `StringScanner` to `CompilerRegexScanner`, and lowers
  Ruby regex/scanner calls to `compilerRegex*` helpers.
- The configured lexer output was 321 lines in the latest smoke check.
- `compiler/src/compiler_regex.zig` has a direct Zig unit test for the
  PCRE2-backed scanner path.

This resolves the previous lexer-specific blockers: interpolated regexes,
`StringScanner` helper calls, `to_i(base)`, codepoint `chr`, and the dynamic
regex in `strip_digit_separators`.

## Biggest Gaps

Full compiler placeholder categories:

| Category | Sites | Functions | Notes |
| --- | ---: | ---: | --- |
| Constructor metadata | 842 | 395 | mostly unknown fields for `.new(...)` and keyword constructors |
| Block control flow | 135 | 121 | `next`, `return`, `break`, pair destructuring inside blocks |
| Write/operator forms | 115 | 70 | `[]=`, `foo +=`, `hash[key] ||=`, call/index operator writes |
| Splat call shapes | 99 | 55 | `*args`, generated overloads, explicit spread support |
| Rescue/exception forms | 91 | 82 | `rescue` modifiers and begin/rescue blocks |
| Global process state | 37 | 23 | `$stdout`, `$stderr`, `$?`, similar Ruby globals |
| Regex/match state | 23 | 10 | interpolated regex and `Regexp.last_match` |
| Stdlib adapter gaps | 23 | 9 | `defined?`, `to_i(base)`, small host-runtime APIs |
| Dynamic dispatch placeholders | 16 | 9 | unsupported emitted `send` / `public_send` |

Dynamic/reflection in source is larger than the emitted placeholder count:

| Call | Sites |
| --- | ---: |
| `public_send` | 18 |
| `send` | 13 |
| `__send__` | 4 |
| `const_get` | 4 |
| `define_method` | 3 |
| `const_defined?` | 1 |
| `instance_variable_set` | 1 |

These 44 dynamic/reflection sites live in 30 function bodies across 21 files.
They are the most likely true manual source-refactor work. The other buckets
should mostly be solved by improving `ruby-to-clear`.

## Current Hot Files

The largest full-compiler dirty files by unsupported site count are:

| File | Sites | Dirty Functions |
| --- | ---: | ---: |
| `compiler/ruby/mir/lowering/expressions.rb` | 165 | 62 |
| `compiler/ruby/mir/lowering/control_flow.rb` | 101 | 36 |
| `compiler/ruby/mir/lowering/functions.rb` | 97 | 37 |
| `compiler/ruby/mir/lowering/variables.rb` | 70 | 25 |
| `compiler/ruby/mir/lowering/capabilities.rb` | 62 | 27 |
| `compiler/ruby/mir/lowering/concurrency.rb` | 55 | 24 |
| `compiler/ruby/tools/doctor.rb` | 46 | 17 |
| `compiler/ruby/annotator/helpers/fixable_helpers.rb` | 44 | 30 |

For the current self-host seed set, the largest gaps are:

| File | Sites | Dirty Functions |
| --- | ---: | ---: |
| `compiler/ruby/annotator/helpers/fixable_helpers.rb` | 44 | 30 |
| `compiler/ruby/ast/type.rb` | 23 | 15 |
| `compiler/ruby/annotator/helpers/intrinsic_registry.rb` | 19 | 7 |
| `compiler/ruby/ast/lexer.rb` | 0 | 0 |
| `compiler/ruby/ast/schemas.rb` | 7 | 4 |
| `compiler/ruby/ast/source_error.rb` | 6 | 4 |

## Required ruby-to-clear Work

These are translator improvements rather than Ruby source changes.

1. Constructor metadata

   Extend metadata preloading to cover:

   - all local and `require_relative` `T::Struct` declarations;
   - `Struct.new` assigned constants and superclass forms;
   - ordinary `initialize` keyword and positional signatures;
   - nested constants and namespace aliases;
   - generated helper files that currently miss constructor field maps.

   This is the largest bucket and should be handled before hand-editing
   generated Clear.

2. Block control flow

   Add lowering for common control-flow forms inside safe collection blocks:

   - `next` in `each`, `map`, `filter_map`, `any?`, `all?`, `find`;
   - `break` in effect-only loops where it maps to `BREAK`;
   - local `return` patterns that should become explicit function returns;
   - pair destructuring in `each_pair`, hash iteration, and tuple-like blocks.

3. Write/operator nodes

   Add Prism handlers for:

   - `IndexOrWriteNode`;
   - `IndexOperatorWriteNode`;
   - `CallOperatorWriteNode`;
   - `CallOrWriteNode`.

   These should map to explicit read/modify/write CLEAR statements where the
   receiver and setter are known.

4. Splat support

   Support high-confidence splats:

   - constructor and method call splats when parameter metadata is known;
   - array literal splats;
   - generated overloads or explicit helper functions for dynamic rest cases.

5. Rescue support

   Support a small subset first:

   - `expr rescue default`;
   - `begin ... rescue ... end` with local fallback;
   - `JSON.parse(...) rescue nil` style host-code patterns.

   Broader exception semantics should not be generalized beyond what the
   compiler source actually uses.

6. Ruby stdlib adapters

   Keep translating common host APIs to first-party CLEAR packages:

   - `File` / `Dir` -> `stdlib/fs`;
   - `File.basename`, `dirname`, `join`, `expand_path` -> `stdlib/path`;
   - `JSON` -> `stdlib/json`;
   - `StringScanner` or regex scanning -> `stdlib/scanner` or `stdlib/regex`;
   - `OptionParser` -> `stdlib/cli`;
   - process globals and status -> `stdlib/process`.

7. Measurement tooling

   Promote the stricter unsupported-site counter into a checked-in audit tool.
   The current markdown audit's `useful LoC coverage` is optimistic because it
   counts unsupported comment blocks but not every inline `unsupportedRuby(...)`
   expression.

## Required Ruby Source Refactors

These source shapes should not survive into self-hosted CLEAR.

1. Replace dynamic visitor dispatch.

   `send("visit_#{...}")` should become generated closed dispatch. This is a
   compiler-appropriate pattern in Ruby, but CLEAR should see an explicit case
   over known AST node variants.

2. Replace bounded `public_send` / `send` property access.

   Current uses include registry hydration, enum-like field access, MIR
   property access, token field reads, and helper calls across private
   boundaries. Replace with explicit methods, typed protocols, or closed cases.

3. Replace metaprogrammed `define_method`.

   `SymbolEntry` lifecycle and flow delegators should be generated explicitly
   or expressed as a static table that `ruby-to-clear` can lower.

4. Replace dynamic constant lookup.

   `const_get` / `const_defined?` should become explicit registries or closed
   maps. This helps both translation and stage1 determinism.

5. Replace `instance_variable_set`.

   The remaining optional metadata mutation in `Type` should become a declared
   field or typed side table.

6. Replace implicit regex match state.

   `Regexp.last_match` should become an explicit match result object. This also
   matches the likely `stdlib/regex` API.

7. Reduce Ruby globals.

   `$stdout`, `$stderr`, `$?`, and similar globals should go through explicit
   process/io APIs.

## Required CLEAR Language / Runtime Work

Some gaps are better solved in CLEAR than in the translator.

- Native package build support through generated `build.zig`; see
  `docs/agents/build-system.md`.
- `stdlib/path`, `stdlib/fs`, `stdlib/process`, and `stdlib/json`.
- The compiler-local regex/native wrapper in `compiler/src/compiler_regex.*`
  for compiler code that should remain regex-based.
- More complete generic type predicates. `COMPTIME IF T IS_A String@symbol`
  now parses and lowers, but `String@symbol` still erases to the same Zig type
  as `String` in equality checks.
- Stable generated dispatch tables for visitors and parser rules.
- A generated source dependency manifest so the self-host compiler can rebuild
  when generated support files change.

## Build-System Dependency

The self-host compiler now has a bootstrap-specific native regex bridge:

`ruby-to-clear` injects inline `EXTERN ... FROM "compiler_regex"` declarations
for generated compiler files. `compiler/src/build.zig` points the build at the
native module directory and links PCRE2 through the existing CLEAR build path.
This is not a general stdlib regex package. Filesystem, JSON, process, and
future native dependencies should still move toward generated build metadata so
they do not require one-off CLI wiring.

## Near-Term Plan

1. Keep generated `*.clear` out of commits except for narrow, known-good
   stdlib files.
2. Promote strict translation metrics into a repeatable audit command.
3. Fix constructor metadata until the seed set has no constructor placeholders.
4. Generate every required helper source in the seed set, including currently
   missing annotator helper dependencies.
5. Add write/operator node lowering.
6. Add block control-flow lowering for the common safe subsets.
7. Refactor the 44 dynamic/reflection source sites, starting with visitor
   dispatch and `IntrinsicRegistry` hydration.
8. Add or design native support for fs/path, JSON, process, and CLI argument
   parsing; keep regex on the compiler-local PCRE2 bridge for now.
9. Regenerate the seed set and require zero missing `REQUIRE` dependencies.
10. Build the generated parser target before committing generated compiler
    source.
