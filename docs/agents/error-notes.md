# CLEAR Error-Message Notes

This log records diagnostics encountered during self-hosting work that do not
give a user enough context to correct the source or build configuration.

## Retired bang-mutation syntax bypasses its migration diagnostic

### Trigger

Build a pre-migration source containing a declaration such as
`FN tokenizeSource!(...)` after bang-suffixed mutability has been removed.

### Current diagnostic

Direct compilation reports `Expected (, got ! (CHAR)` at the bang. Running
`clear fix` separately reports the useful explanation that `!` no longer marks
mutation and proposes removing the suffix before adding explicit `&value`
arguments.

### Why it is insufficient

The parser error describes only its immediate token expectation and hides a
known, mechanically fixable language migration. A user building old CLEAR is
not told that the syntax was retired or that the compiler already knows how to
rewrite it.

### Desired diagnostic

Surface the registered mutability migration diagnostic during ordinary build,
including the fix and a `clear fix <file>` command, instead of the generic
parser expectation.

## Indexed field-access autofix changes the value to optional

### Trigger

Access a field on a fallible indexed value, for example
`sub_tokens[i].type`, inside a fallible function.

### Current diagnostic and fix

The compiler correctly says the indexed value must be handled, but proposes
`sub_tokens[i]?.type`. That expression has type `?String@symbol`, so passing it
to a function expecting `String@symbol` immediately produces another error.

### Why it is insufficient

Safe navigation is not semantics-preserving when the consumer requires a
definite value. In this case the intended correction is
`token = TRY sub_tokens[i]; token.type`, which propagates the bounds failure
through the already-fallible function.

### Desired diagnostic

Offer context-sensitive alternatives: `TRY` when the enclosing function can
propagate failure, `OR_ELSE ...` when a local fallback is needed, and safe
navigation only when the downstream context accepts an optional value.

## Nested package import was not registered

Status 2026-07-20: fixed. `clear build` accepts `--pkg name=path`
registrations, registered paths take precedence over directory discovery, and
package aliases reached through locally REQUIREd modules are rewritten in the
emitted root Zig. Covered by `compiler/spec/clear_cli_registered_pkg_spec.rb`.

### Trigger

`main.clear` imports package `lexer`, whose `lib.clear` imports package
`frontend_resource_budget`.

### Current diagnostic

`REQUIRE error: unknown package 'rtoc_…'. Register it with --pkg …`

### Why it is insufficient

The package is present under the normal `packages/<name>/src/lib.clear`
layout. The actual defect was build orchestration registering only the root
package before the annotator recursively resolved its imports. Asking the user
to register a path obscures that distinction.

### Desired diagnostic if resolution still fails

State the importing package and explain the resolution roots checked, e.g.:

`Package 'frontend_resource_budget', required by package 'lexer', was not found under packages/<name>/src/lib.clear while resolving <path>. Add the package, or register it with --pkg <name>=<path>.`

## Imported type lost its module qualification

Status 2026-07-20: fixed in the compiler rather than the translator. Package
imports now emit `const TypeName = module.TypeName;` aliases for every pub
type of the imported package (the same contract EXTERN STRUCT emits), and
package emission carries PUB visibility onto Zig type defs. Covered by
`compiler/spec/clear_cli_registered_pkg_spec.rb`.

### Trigger

A generated module imports `FrontendResourceBudget` from another generated
package and uses it in a field or function signature.

### Current diagnostic

The final Zig compiler reports `use of undeclared identifier
'FrontendResourceBudget'` at generated `.zig` lines.

### Why it is insufficient

The authored CLEAR package has a valid `REQUIRE ... AS frontend_resource_budget`.
The problem is Ruby-to-CLEAR lowering the imported type without its module
qualification. Neither the generated CLEAR location nor the source Ruby type
is identified.

### Desired diagnostic if lowering cannot resolve it

`Type 'FrontendResourceBudget' is imported from package 'frontend_resource_budget' but is used without a visible package qualification in generated module 'lexer'. Qualify the type or add it to the generated import map.`

## Module graph reports backend symbols instead of source imports

Status 2026-07-20: the two defects behind these diagnostics are fixed
(foreign EXTERN module imports are rewritten inside emitted package files;
duplicate package imports landing in one Zig unit are deduped by alias). The
diagnostic-quality complaint below still stands: failures of this class still
surface as Zig errors without a CLEAR source location.

### Trigger

A local generated module imports a helper module that owns an `EXTERN STRUCT`,
and the root imports the generated module.

### Current diagnostics

Zig reports `use of undeclared identifier 'CompilerRegexScanner'` and
`ambiguous reference frontend_resource_budget`, pointing only to generated Zig
lines.

### Why they are insufficient

The useful problem statement is that the module lowering omitted an imported
foreign declaration and emitted the same local module namespace twice. The
diagnostics provide no CLEAR source location, import edge, or indication that
this is a compiler module-lowering issue rather than an error in the program.

### Desired diagnostic

`Module 'lexer.clear' requires foreign declaration 'CompilerRegexScanner' from 'compiler_regex', but it was not propagated to the root module.`

`Local module 'frontend_resource_budget.clear' was emitted more than once while lowering imports from 'lexer.clear'.`

## Optional owned constructor parameter has inconsistent representation

### Trigger

The translated `Lexer#initialize` accepts optional `FrontendResourceBudget` and
creates a default budget when it is absent.

### Current diagnostic

Zig reports `expected type 'FrontendResourceBudget', found 'CheatLib.Rc(FrontendResourceBudget)'` at a generated temporary line.

### Why it is insufficient

This is an ownership-lowering mismatch between an optional input and the owned
default constructor result. The user sees neither `Lexer#initialize` nor the
`budget || FrontendResourceBudget.new` source expression.

### Desired diagnostic

`While lowering Lexer#initialize, optional parameter 'budget' has value type FrontendResourceBudget but its fallback constructs owned FrontendResourceBudget@multiowned. Normalize both branches to the declared ownership representation.`

## Propagated runtime failure discards the original error

### Trigger

A CLEAR lexer function raises a specific error while tokenizing source, and a
caller propagates it with `OR_ELSE RAISE`.

### Current diagnostic

`[Scheduler] Task Crashed: error.CheatError`

### Why it is insufficient

The original lexer message, source location, and propagation path are all
discarded. This made an unsupported `\\u{2014}` escape indistinguishable from a
memory, scheduler, or ownership failure in the compatibility oracle.

### Desired diagnostic

Preserve and print the original error payload, for example:
`Lexer Error: invalid Unicode codepoint in \\u{} escape`, followed by a concise
propagation stack when diagnostic builds enable one.

## Rc structural-copy failure lacks the CLEAR ownership path

### Trigger

Inline the generated `FrontendResourceBudget` and lexer, then store an optional
constructor budget in the lexer's `FrontendResourceBudget@multiowned` field.

### Current diagnostic

`[OWNERSHIP_STRUCTURAL_RC_COPY] lexer__initialize::CheatLib.Rc(FrontendResourceBudget) -- reference-counted handles must be retained, upgraded, or downgraded; MIR::DeepCopy may not structurally duplicate an Rc/Arc handle`

### Why it is insufficient

The verifier correctly prevents an unsound Rc bit-copy, but reports an internal
MIR operation and generated Zig type. It does not identify the source parameter,
field assignment, or the missing bind-time capability transport. In this case a
payload deep copy would also be semantically wrong: every nested lexer must
share one resource-budget counter.

### Desired diagnostic

Point at the field assignment and explain that a plain borrowed parameter cannot
be retained as `@multiowned`. Suggest the eventual explicit local-identity
transport form once that contract is settled; never suggest `COPY` or an
automatic `@shared` upgrade.

## Translator: class-method prefixing is invisible cross-invocation (undiagnosed root cause, deferred)

### Trigger

Any zero-argument `self.foo` class method whose name also appears as a
`self.foo` on some OTHER, unrelated class ANYWHERE in the transpiled corpus
(not just the current file or its direct requires). Real case: `compiler/ruby/
annotator/helpers/intrinsic_contract.rb`'s `IntrinsicContract.self.empty`
(called from `function_signature.rb:246`'s `emit ? IntrinsicContract.from_emit(
emit, @contract.params) : IntrinsicContract.empty`); 11 other unrelated
classes across compiler/ruby also define `self.empty` (pipeline_context.rb,
mir.rb, effect_set.rb, control_flow.rb, etc.) - all outside function_signature.
rb's own require closure.

### Current behavior

`gems/ruby-to-clear/lib/ruby_to_clear/transpiler.rb`'s `class_method_function_
name` only prefixes a class method (`intrinsicContract__empty`) when
`@duplicate_class_method_names` - computed FRESH per transpile invocation from
that file's own AST plus whatever `require_resolver.rb` walks into via direct/
transitive `require_relative` - contains the name. `intrinsic_contract.rb`,
transpiled through the full verifier corpus, correctly sees the 12-way global
collision and prefixes. `function_signature.rb`, transpiled independently
(its own require closure never reaches the other 11 files), does not see the
same collision and emits the bare, now-mismatched `empty()`. Confirmed via
direct file-pair repros: two files whose ONLY shared `self.empty` is between
each other never reproduce the mismatch - it requires true whole-corpus
knowledge neither file's local scan can have. Result: `TYPO_SUGGESTION_
REJECTED: Undefined function 'empty'` (56 corpus files share this exact root
once the unrelated ternary-narrowing bug fixed in 5d9c5cf7a stopped masking
it upstream).

### Why it is deferred rather than fixed here

Two real fixes exist, both larger than a local patch: (a) a genuine
whole-corpus pre-scan cache of class-method names that every transpile
invocation consults (new persistent-metadata infrastructure); (b) always
prefix class methods with their class name, removing the collision-dependent
optimization entirely (architecturally simplest and immune to this whole bug
class, but changes the emitted name of every currently-bare, currently-unique
class method across the corpus - large blast radius on existing golden/spec
expectations that needs deliberate, reviewed validation, not an autonomous
one-off fix).

### Desired outcome

Whichever fix lands, caller and callee must derive the SAME prefixing
decision from a source of truth neither file's local, per-invocation scan can
diverge on.

## Translator: `END;` from a multi-line safe-nav-or declaration preceding a trailing IF (FIXED 2026-07-25, commit dd080f2422)

### Trigger

`x = a&.method || fallback` where `fallback` is itself a multi-line
expression (e.g. a `begin...end` branching on a second optional). Real case:
`compiler/ruby/mir/fsm_transform.rb#foreach_local_entry`'s `elem_zig =
desc&.var_zig_type || begin ... end`. Generated CLEAR:

```clear
MUTABLE elem_zig = { ...multi-line value block, itself containing an
  expression-form (IF elem_t != NIL THEN ... ELSE ... END)... };
IF desc != NIL THEN
  elem_zig = (desc?).var_zig_type;
END;   # <- invalid: CLEAR rejects the trailing `;`
```

Root cause: `block_statement_output?`'s "one or more decl lines precede the
block keyword" heuristic (`gems/ruby-to-clear/lib/ruby_to_clear/transpiler.rb`)
is a single-line regex (`[^\n]*;\n\s*`). It cannot recognize a *multi-line*
preceding declaration (the value-block above spans several lines before its
own closing `};`), so it fails to classify the combined text as
"already block-terminated," and `statement_code` appends a stray `;` after
the trailing `IF...END`'s closing `END`. This is the confirmed cause of the
34x `Unexpected token CATCH (KEYWORD)` / other `Unexpected token ; (CHAR)`
corpus fingerprints (the specific trailing token after `END;` varies by what
follows in the surrounding generated file).

### Fix attempt and revert (2026-07-24)

Replaced the single-line regex with a depth-aware scan
(`final_top_level_statement`, tracking both bracket AND CLEAR keyword-block
nesting under one counter) to correctly find the trailing statement
regardless of how many lines the preceding declaration spans. Confirmed via
isolated repro and `--only fsm_transform` that this resolved the target
`CATCH` error. **However**, a clean, uncontaminated full-corpus verifier
comparison (fresh worktree at the fix's parent commit, full 216-file run,
per-file G2 diff) showed it dropped G2 (CLEAR-parses) from 76/216 to 18/216 -
58 files regressed, 0 improved. The exact regression mechanism was not
tracked down before reverting (commit reverted the same session it landed).
Given the function is used broadly (every statement's semicolon placement
routes through it), a change here has wide blast radius; the restructuring
likely altered behavior for some OTHER common shape beyond the multi-line-
preceding-declaration case it targeted - possibly related to how the
`no_trailing_statement`-gated early-return heuristics interact with the new
check's control flow, but this needs verification, not another guess.

### Recommended approach for the next attempt

1. Before wiring `final_top_level_statement` (or any replacement) into
   `block_statement_output?`, write it against a WIDE spec matrix covering
   every existing shape the function's current regex-based checks handle
   (single-line decl + block, multi-line decl + block, bare block, `.nil?`
   ternary false-branch, `END)`-suffixed value expressions, etc.) - not just
   the one target repro - and confirm each still classifies correctly BEFORE
   touching the corpus.
2. Land the fix, then immediately re-run the FULL verifier (not a scoped
   `--only` check) and do a real per-file G2 diff against a clean baseline
   (a separate worktree at the parent commit, not a reused/contaminated
   artifacts directory - re-running `--only` scoped checks in the same
   worktree overwrites the SAME revision-keyed artifacts dir and invalidates
   later comparison) before declaring the fix safe.
3. If the regression reappears, bisect by testing the new
   `final_top_level_statement`-based logic and the original regex-based
   logic on the SAME broad shape matrix side by side to find exactly where
   they diverge, rather than reasoning about the code in the abstract.

### Fix landed (2026-07-25, commit dd080f2422), following the recommended approach above

Purely additive instead of a restructure: a new `multiline_prefixed_block_output?`
check runs first (before the early-`false` heuristics that would otherwise
short-circuit on the declaration's own unclosed first-line delimiter) and
peels off zero-or-more leading `decl = value;` statements - single-line via
the existing regex, or multi-line via a new quote-aware bracket scan - before
checking whether what remains is a trailing block keyword. Every existing
branch in `block_statement_output?` is untouched, so it can only turn
previously-false cases true, never the reverse.

Verified with a 22-case shape matrix spec (`#block_statement_output?` in
`transpiler_spec.rb`) covering every existing branch plus the new multi-line
case, the full gem spec suite (632/0), the full `compiler/spec/` suite
(7848/0), `./clear test transpile-tests/` (659/659, 0 leaks), and a clean
per-file G1-G4 diff between two full uncontaminated verifier runs
(`d8532c2092` before, `dd080f2422` after): **0 files regressed, 0 files
improved**.

The first attempt at this exact fix collided a new helper's name
(`balanced_delimiter_end`) with an existing 4-arg method of the same name
used elsewhere in the file (line ~487, single opener/closer pair, no quote
awareness) - Ruby silently redefines same-named methods, so this broke 98
unrelated specs relying on the original definition until renamed to
`quote_aware_bracket_end`. Any future helper addition to this file should
grep for the chosen name first.

### The 34x "Unexpected token CATCH" corpus fingerprint is NOT this bug

The zero-regression/zero-improvement per-file diff above means this fix,
while correct and now safety-verified, does not move the "34x
`Unexpected token CATCH`" fingerprint that motivated it - that count is
byte-for-byte identical before and after. Direct inspection of a real
failing corpus file (`compiler/src/mir/mir_pass.clear`, from
`compiler/ruby/mir/mir_pass.rb#owning_field_move?`, a bare `def ... rescue
... end`) shows a DIFFERENT, unrelated trigger:

```clear
WITH POLYMORPHIC self AS rtoc_self_view {
    IF node IS_A GetField AS get_field THEN
      ...
    ELSE
      RETURN FALSE;
    END
  CATCH Transient, Input, System, NotFound, Permission, Canceled
    RETURN FALSE;
}
```

A `WITH { ... }` block whose body is a statement-form `IF...END`, followed by
a postfix `CATCH` clause with no `;` between `END` and `CATCH`. The parser
rejects `CATCH` as an unexpected continuation after a statement-shaped IF.
This is a distinct question from `block_statement_output?`'s semicolon
placement (which only decides whether a TRAILING `;` gets appended after a
block; this is about whether `CATCH` is a legal postfix continuation of a
preceding statement-form block at all) - most likely in the ensure/rescue
lowering path that emits the `WITH { <body> } CATCH <types> <handler>` shape
for a Ruby bare-rescue method, not in `block_statement_output?`. Not yet
investigated further. This is now the real, still-open, still-dominant
contributor to the "34x CATCH" fingerprint and the natural next target -
distinct from, and should not be confused with, the bug this section
documents (which is fixed and verified).

## Optional pipeline element into a non-optional callee param (FIXED 2026-07-25, commit 31f8bf1e91)

### Trigger (confirmed reproducible 2026-07-25)

```clear
FN observeItem(x: String) RETURNS Int64 ->
  RETURN x.length();
END

FN main() RETURNS !Void ->
  src: [~]?String = BG STREAM {
      x1: ?String = COPY "ab";
      x2: ?String = COPY "cd";
      YIELD x1;
      YIELD x2;
  };
  out: [~]Int64 = src |> SELECT observeItem(_);
  MUTABLE total = 0_i64;
  WHILE NEXT out EXISTS AS item DO
      total = total + item;
  END
  RETURN;
END
```

### Current behavior

The CLEAR frontend accepts this without any diagnostic. It fails only at the
Zig backend, with a raw type mismatch instead of a CLEAR-level error:

```
._clear_tmp_repro.zig:112:63: error: expected type '[]const u8', found '?[]const u8'
                  try __select_stream1_local.push(observeItem(__select_item));
```

This means `_`'s stamped type inside the SELECT body is plain `String`, not
`?String` - the argument-type check that would normally catch this
(`ARGUMENT_TYPE_ERROR`, the same one ordinary non-pipeline calls go through)
never sees the optionality, so it never fires.

### Root cause (confirmed) and fix

`pipeline_source_fact` (`compiler/ruby/annotator/helpers/pipe_analysis.rb`,
~line 262) stamped `_`'s item type via `source_type.tense_type.element_type`
(dynamic/bounded branches) or `source_type.open_stream_element_type`/
`inf_stream_element_type` - all of which route through `Type#element_type`,
whose own docstring on the correct alternative already gave away the bug:

```ruby
# Preserve all wrappers on the item (`?T`, `!T`, `!?T`) instead of
# deriving through tense_type/element_type, which intentionally normalizes
# some collection shapes for older stream aliases.
def canonical_stream_item_type
```

`canonical_stream_item_type` (`type.rb` ~line 3798) already exists as the
wrapper-preserving accessor and was already used at the MIR lowering stage
(`pipeline_host.rb:730,796`) - just never wired into the annotator's
argument-checking stage. That single-source-of-truth split (lowering uses
the correct accessor, the annotator's type-check uses the lossy one) is why
this compiled: the ANNOTATOR never saw the `?`, but codegen did, producing a
correct-but-mismatched-with-what-was-checked Zig signature.

Fix: in each of `pipeline_source_fact`'s four stream branches (inf, open,
dynamic, bounded), prefer `source_type.canonical_stream_item_type`, falling
back to the original accessor only when it returns `nil` (the legacy `~?T[]`
/ `~?T[N]` alias spelling, which is not a `StreamTypeExpression` and so
`canonical_stream_item_type` correctly declines to handle it - preserving
100% of existing legacy-alias behavior unchanged).

Verified directly against all four stream cardinalities, both the buggy
(optional-element, now a clean `ARGUMENT_TYPE_ERROR` at the exact call site)
and positive (plain element, still compiles+builds) case for each:
`[~]?T`/`[~]T` (dynamic), `[~N]?T`/`[~N]T` (bounded), `[~INF]?T`/`[~INF]T`
(inf) - six isolated `.clear` repros, all six behaving correctly. Added an
end-to-end spec pair (`compiler/spec/error_emission_coverage_spec.rb`, the
`:ARGUMENT_TYPE_ERROR` describe block) covering the bad/good pair for the
dynamic case. Full `compiler/spec/` suite: 7848/0. `./clear test
transpile-tests/`: 659/659, 0 leaks.

### Follow-on work not done here

`tools/fuzz/templates/call_ownership_contract_matrix.rb`'s `:pipeline_call`
cells still have no optional-element dimension (confirmed absent from the
current 179 generated cells - the `fuzz_call_ownership_contract_matrix_
6813d4e281` cell name recorded in `docs/agents/self-host.md`'s "Known red"
note does not match any cell the current template can regenerate). Adding
that dimension and running it through the mutation-kill gate is the natural
next step to lock this fix in permanently, but is a separate, non-blocking
unit of work from the compiler-side fix itself.

## Cross-file constructor keyword-argument resolution (real architectural gap, deferred - needs new infrastructure, not a surgical fix)

### Trigger

`SomeClass.new(kw: value, ...)` where `SomeClass` is defined in a
DIFFERENT file than the call site. Confirmed real corpus cases: `Edit.new(
span:, replacement:)` (`ast/fixable_error.rb`'s `Edit`, called from `ast/
parser/state.rb`), `ParsedExternEffects.new` and `CapabilityParseResult.new`
(same-shape, different files). Combined, this is the actual scope of BOTH
the "5x Keyword arguments are not supported for this constructor" AND at
least 2 of the "3x Constructor call needs known field names" verifier
fingerprints - they are the same root cause, not two separate bugs. (The
third `Constructor call needs known field names` instance, `::Set.new`, is
unrelated - a Ruby stdlib `Set` construction shape, not cross-file
resolution.)

### Root cause

`constructor_call_from_keywords` (`gems/ruby-to-clear/lib/ruby_to_clear/
transpiler/constructor_lowerer.rb:216`) depends entirely on
`constructor_parameter_info`, which only reads `@constructor_params[name]`
- metadata populated by scanning the CURRENT file's own AST during this
one transpile invocation. When the target class's `initialize` is defined
in a file the current unit does not itself parse (even if it's a real,
resolvable `require_relative` dependency), `@constructor_params` has
nothing for it, and the translator gives up rather than guessing at
argument order.

### Why this needs new infrastructure, not a surgical fix

Unlike the class-method-prefixing bug fixed earlier this session (where
"always prefix, matching the already-established instance_function_name
convention" made the fix collision-independent and eliminated the need for
any cross-file knowledge at all), there is no such shortcut here: CLEAR has
no keyword-call syntax (confirmed absent - see `self-host-plan.md`'s "Work
that should not block the next phase" list, "named call arguments"), so a
keyword constructor call MUST be lowered to either a struct literal (field
order does not matter) or a positional `class__new(pos1, pos2, ...)` call
(order matters and must exactly match the target `initialize`'s declared
parameter sequence). Ruby's keyword-argument call syntax lets a caller
write `span:`/`replacement:` in any order regardless of `initialize`'s own
declaration order, so the translator cannot safely guess a positional
mapping without knowing the real signature.

The typed-IR report already ingested per-unit (`--typed-ir-report`,
consulted elsewhere this session for the pipeline-argument fix) was
checked and does NOT contain this information - its `functions` section is
FactMine/SlopCop CFG-coverage-mapping metadata (`"reason": "CFG facts were
not supplied"`), unrelated to constructor signatures. No existing
cross-file lookup mechanism can be reused here the way `canonical_stream_
item_type` was reused for the pipeline fix.

### Recommended approach for the next attempt

A real fix needs one of:
1. A corpus-wide pre-scan pass (run once before per-file transpilation
   begins) that builds `class_name -> ordered initialize parameter list`
   for every class in the corpus, consulted as a fallback when
   `@constructor_params[name]` is empty. This is real, non-trivial
   infrastructure (a new caching/orchestration layer in the verifier or
   `ruby-to-clear` CLI), not a one-off code change - matches the same
   "corpus-wide pre-scan cache" option previously scoped (and passed over
   in favor of a simpler fix that turned out to exist) for the class-method-
   prefixing bug.
2. A lazy per-class lookup: when `constructor_parameter_info` misses
   locally, resolve the class's defining file via the same require-
   resolution machinery already used for `generated_dependencies` tracking,
   parse just that file's `initialize` signature, and cache the result.
   Bounded to only the classes actually referenced this way, cheaper than
   a full pre-scan, but still new code, not a tweak to existing logic.

Either approach is real engineering, not a quick patch - correctly scoped
as a deferred item rather than attempted under time pressure.

## Missing `;` before ELSE_IF inside a nested value-block/pipeline shape (real bug, still open, NOT investigated in depth - do not confuse with the fixed END; bug)

### Trigger

The corpus's #2 fingerprint after the WITH+CATCH placement fix landed
(34 files, same package group `scc_annotator_34` as before - this is a
NEW symptom on the SAME already-failing group, not a new set of files).
Real case: `compiler/ruby/mir/lower/pipeline/pipeline_concurrent_lowerer.rb`'s
`assignment_targets_placeholder?`, generated CLEAR
(`mir/lower/pipeline/pipeline_concurrent_lowerer.clear:910-923`):

```clear
RETURN struct.members() |> ANY (IF ([:token, :location]).contains?(_) THEN FALSE ELSE { MUTABLE rtoc_value_block_marker = 0; MUTABLE value = COPY struct[_];     IF value IS_A []@multiowned Any THEN
      value |> ANY (_ IS_A Struct AND pipelineConcurrentLowerer__assignment_targets_placeholder?(self, _))
    ELSE_IF value IS_A Struct THEN
      pipelineConcurrentLowerer__assignment_targets_placeholder?(self, value)
    ELSE
      FALSE
    END } END);
```

### Current diagnostic

`Parser Error: Expected ; at end of line <n>; got 'ELSE_IF' on line <n+1>`,
pointing at the `ELSE_IF value IS_A Struct THEN` line.

### Why this is NOT the same bug as the fixed `END;`/`block_statement_output?` issue

That fix (commit `dd080f2422`, this file's earlier section) was about
`block_statement_output?` failing to recognize a multi-line PRECEDING
DECLARATION before a trailing block keyword, causing a stray `;` to be
APPENDED after a block's closing `END`. This is different: the missing
`;` is BEFORE an `ELSE_IF`, inside a deeply nested shape - a pipeline
`ANY` lambda argument, containing a value block (`{ MUTABLE rtoc_value_
block_marker = 0; ...}`), containing an inner `IF...ELSE_IF...ELSE...END`
chain, all nested inside an OUTER `IF (...).contains?(_) THEN FALSE ELSE
{ ... } END`. The zero-regression per-file diff after the `END;` fix
landed (see the FIXED section above) already proves the two are
unrelated - the `END;` fix touched zero files at the gate level, and
this fingerprint's TEXT changed but its FILE COUNT (34) stayed exactly
the same across that fix, meaning this was already the actual failure
underneath the WITH+CATCH-nesting symptom the whole time, not something
the WITH+CATCH fix introduced.

### Why this is not investigated further here

This shape is far denser than the `END;` bug's trigger (multiple levels
of nesting: pipeline lambda -> value block -> nested if-chain -> outer
if-chain), and per this project's own hard-won lesson from the `END;`
bug's first (reverted) fix attempt, `block_statement_output?`/
`statement_code`-adjacent semicolon-placement logic has proven to have
wide, easy-to-miss blast radius. Diagnosing this correctly needs the
same discipline as that fix's eventual correct approach: isolate the
minimal reproducing shape first (probably: does a pipeline `ANY` lambda
whose body is an `IF...ELSE...END` returning a value-block, itself
containing another `IF...ELSE_IF...END`, ever get its semicolon
placement right in ANY simpler variant - e.g. without the outer pipeline
wrapping?), build a spec matrix, then fix - not a guess based on one
complex real-world instance.

### Recommended approach for the next attempt

1. Reduce the real corpus trigger to the smallest CLEAR (not Ruby) shape
   that reproduces the exact parser error, by hand-simplifying the
   generated code above until the error disappears, to isolate exactly
   which nesting combination is required.
2. Check whether `statement_code`/`block_statement_output?` is even the
   right place - the missing `;` appears to belong AFTER the pipeline
   `ANY` lambda's OWN nested IF/ELSE_IF/END chain's inner arm (`value |>
   ANY (...)`), which is itself inside a value block, which is itself an
   ELSE-branch value of a different outer IF - trace which specific
   `statement_code`/lambda-body-rendering call site is responsible for
   that inner line before assuming it is the same function already fixed
   for the `END;` bug.
3. Once a candidate fix exists, follow the exact same protocol as the
   `END;` fix: build a wide shape-matrix spec first, land the fix, then
   do a full clean per-file verifier diff (not a scoped `--only` run)
   before trusting it.

## SELECT applied to a misinferred Tuple instead of an Array (new #1 fingerprint, 57 files, not yet root-caused)

### Trigger

Newly exposed by the `RETURN`-ownership-upgrade fix (same 57 files,
one layer deeper - the fingerprint fully churned from `RETURN_MISMATCH`
to this, zero file-count change, confirmed via the clean per-file
diff). Real case (`compiler/ruby/annotator/helpers/function_signature.rb:477`):

```ruby
GenericBounds = T.type_alias { T::Hash[Symbol, T::Array[Type]] }
...
@generic_bounds = T.let(
  generic_bounds.transform_values { |bounds| bounds.map { |bound| Type.new(bound) } },
  GenericBounds,
)
```

### Current diagnostic

`[Compiler Error] [SELECT_NEEDS_LIST] Cannot SELECT from non-list type
Tuple<String@symbol,Type[]>`, at the generated `bounds |> SELECT
type__new(_)` inside the `transform_values` block lowering.

### What's confirmed, what's not

`bounds.map { |bound| Type.new(bound) }` - a plain `Array#map` inside a
`Hash#transform_values` block - lowers to a pipeline `SELECT`, which is
correct for an Array. But the translator infers `bounds`'s (the block
parameter's) type as `Tuple<String@symbol, []Type>` - a two-element
tuple pairing a symbol and an array - not `[]Type`/`T::Array[Type]` as
the `GenericBounds` alias declares. This looks like the translator is
inferring `bounds` as if it were a `[key, value]` pair from `Hash#each`
rather than the lone value `Hash#transform_values` actually yields to
its block - but this is a hypothesis, not confirmed by reading the
`transform_values`-lowering code yet. Not investigated further this
session - flagging as the clear next target (57 files, single root
cause per the same-package-group pattern already seen twice this
session) rather than guessing at a fix under time pressure.

### Recommended approach for the next attempt

1. Find where `Hash#transform_values` block parameters get their type
   inferred/stamped in the translator (likely near wherever `each_pair`/
   `transform_values`/`map` block-parameter typing lives - grep for
   "transform_values" in gems/ruby-to-clear/lib).
2. Confirm or refute the "yields as if each_pair's [key, value] pair"
   hypothesis with a minimal isolated repro (`{a: [1,2]}.transform_values
   { |v| v.map { |x| x } }`) before touching any code.
3. Fix at the inference site, add a spec proving the correct block-
   parameter type for `transform_values` specifically (distinct from
   `each_pair`/`each`), then the standard full-suite + clean verifier
   diff protocol.

### Update: block-parameter type fixed (commit 05fc2f1350); a real, separate gap remains - `transform_values` has no native CLEAR lowering at all

The block-parameter mistyping above (steps 1-3) is fixed and verified.
That was necessary but not sufficient: `transform_values` is not a real
CLEAR HashMap method (`./clear build` on `h.transform_values(...)`
standalone: `TYPO_SUGGESTION_REJECTED: Unknown method 'transform_values'
on HashMap<...>. Available: put, delete, contains?, count, length, keys,
empty?, any?, values`). Unlike `each_pair`/`each_value`/`map`/`select`
(each has a `register("...")` entry in `gems/ruby-to-clear/lib/
ruby_to_clear/method_registry.rb` lowering to native CLEAR iteration -
`hash_each_effect_stage`, `hash_map_value_stage`, `hash_select_keys_
stage`), `transform_values`/`transform_keys` have no registration at
all and fall through to a generic "emit the Ruby method name verbatim"
path - which only worked as CLEAR *source text* by coincidence (the
generated text looked plausible) until something tried to actually
build it. The corpus's #1 fingerprint (still the same 57 files) is now
`ARGUMENT_TYPE_ERROR: Function '_' argument <n> expects
TypeConstructionInput, got Type` - a symptom of the SELECT downstream
of the (still-unregistered) `transform_values` call receiving a value
of the WRONG type for ITS OWN destination, one more layer of the same
underlying gap.

### Design sketch for the next attempt (not implemented - needs validation against more than one real trigger before landing)

Model closely on `hash_each_effect_stage`'s `nonlocal_return` branch
(`method_registry.rb:642-644`, the `FOR rtoc_key IN X.keys() DO ... END`
shape) but produce a value instead of Void - iteratively build a NEW
HashMap rather than mutate in place, since Ruby's `transform_values`
returns a new Hash (non-mutating; `transform_values!` is the mutating
sibling and would need its own, simpler in-place-mutation lowering):

```
{ MUTABLE rtoc_value_block_marker = 0;
  MUTABLE <result>: {<KeyType>}<NewValueType> = {};
  FOR rtoc_key IN <receiver>.keys() DO
    <result>[rtoc_key] = <block value, with the param renamed to
      "(<receiver>[rtoc_key] OR_ELSE <fallback>)">;
  END
  <result> }
```

The one real subtlety `hash_map_value_stage`/`hash_each_effect_stage`
don't need to solve: the NEW value type is NOT necessarily the same as
the ORIGINAL value type (`bounds.map { |bound| Type.new(bound) }` turns
`T::Array[String]`-shaped bounds into `Type` instances - the real
corpus case's outer Hash's value type changes from `T::Array[String]`
to `T::Array[Type]`). `hash_map_value_stage` sidesteps this because
`.map` returns an Array, whose element type is just "whatever the
block returns" with no separate declared container-type slot to keep
in sync; a HashMap literal's declared value type has to be resolved
from the block's OWN inferred return type (likely via `lowering.
value_code`'s type, the same signal `hash_map_value_stage` reads for
its tuple-cast special case), not copied from the original Hash's type.

Only one real corpus trigger exists to validate against
(`function_signature.rb`'s `generic_bounds.transform_values`) - land
this with at least one more constructed case exercising a DIFFERENT
value-type transformation before trusting it, matching this project's
own test-before-fix discipline for anything touching hash/collection
lowering.

## "Complex exception handling (rescue) is not supported" - a real language gap, not a translator bug (8 files, do not widen the existing check)

### Trigger

Any `rescue` clause more expressive than CLEAR's single supported
shape - catch-all (`rescue` / `rescue => e` / `rescue StandardError` /
`rescue Exception`), no reference-carrying logic beyond an `OR_ELSE`
value fallback, no chained `rescue`, no `ensure`, no `else`. 8 real
corpus files hit this (`raise_unsupported` in `visit_begin_node`,
`gems/ruby-to-clear/lib/ruby_to_clear/transpiler.rb:7309`):
`ast/parser.rb`, `backends/transpiler.rb`, `lsp/analyzer.rb`,
`lsp/rpc.rb`, `mir/fsm_transform/recursive_splitter.rb`,
`tools/c_ffi_generator.rb`, `tools/fmt_verifier.rb`,
`tools/formatter.rb`.

### Why this is not a translator bug

`static_exception_name?` (transpiler.rb:7087) intentionally restricts
the catch-all lowering to `StandardError`/`Exception` only, with an
explicit comment explaining why: "Only exception classes that mean
'any error' may lower to CLEAR's full CATCH taxonomy. A typed rescue
(rescue ParseError) carries a dispatch filter that the catch-all would
silently widen away." Verified this is a REAL semantic concern, not
overcaution: CLEAR's fallible-call model (`!Type` return + `TRY` +
`panic`) is untyped - a fallible call signals "did this fail," not
"did this fail with exception class X." Widening the catch-all
lowering to accept `rescue SomeSpecificClass` (2 of the 8 files -
`backends/transpiler.rb`'s `rescue RuntimeError` and
`mir/fsm_transform/recursive_splitter.rb`'s `rescue UnsupportedShape`
- would ALREADY pass if this were the only restriction) would silently
swallow failures Ruby's real semantics would let propagate past that
`rescue`, since CLEAR has no way to check "was this specific failure
an instance of X" at the point `OR_ELSE`/catch-all lowering runs. This
is a genuine, deliberate correctness boundary, not an arbitrary check
worth loosening.

### Full shape survey (all 8 files, confirmed via the real translator)

Only 3 of 8 share one shape (`rescue SomeClass => e; raise Other,
"...#{e.message}"` - reference-bind, re-raise a DIFFERENT type using
only `.message`): `lsp/rpc.rb`, and two independent sites in
`tools/c_ffi_generator.rb`. `tools/formatter.rb` and
`tools/fmt_verifier.rb` use the same `.message`-only re-raise/build
pattern but with a bare (implicit-`StandardError`) rescue - so for
those two the class-matching side is already fine; only the reference
binding is new. `ast/parser.rb` needs CUSTOM STRUCTURED FIELDS on the
caught error (`e.kind`, `e.limit`), not just `.message`. `lsp/
analyzer.rb` is the worst case: two chained rescue clauses (one multi-
class `rescue CompilerError, ParserError => e`, one bare catch-all),
PLUS an `ensure` alongside rescue, PLUS the caught value gets handed
whole into a helper (`synthetic_finding_from(e)`) that itself calls
`e.token`, `e.original_message`, and `e.is_a?(ParserError)` - runtime
type dispatch on the caught value, not reducible to any fixed field
set. `backends/transpiler.rb` and `mir/fsm_transform/
recursive_splitter.rb` have no binding at all - they fail purely on
the named-class restriction above.

### What CLEAR would need to support any of this for real

At minimum: some notion of a typed/structured error VALUE that
`TRY`/`panic`'s failure path can carry (so a caught failure exposes
`.message`, and ideally arbitrary named fields, not just a bare
signal), plus a way to narrow/dispatch on that value's type in a
`rescue`-equivalent construct. This is squarely a language-design gap
per this project's own contributing guidance ("If you ever find a
limitation in the language that you have to work around, stop,
identify the problem, and suggest how the language needs to be
improved") - not attempted here. If a future design lands a typed-
error-value primitive, the `.message`-only subset (5 of 8 files) would
likely become tractable as a translator lowering without further
language work; `ast/parser.rb`'s custom fields and `lsp/analyzer.rb`'s
chained-rescue-plus-ensure-plus-type-dispatch would still need
additional design (structured field access on the error value; a
multi-clause dispatch construct).

## RETRACTED: "Cannot infer `copy` from a fallible value" was misdiagnosed as a self-hosted compiler bug - it was a real ruby-to-clear bug, now fixed

The entry originally here concluded this 97-file `FunctionSignature#dup`
crash was "squarely inside the self-hosted CLEAR compiler's own whole-class
fallibility inference... a different subsystem from the `gems/ruby-to-clear`
translator... not something a translator-side change should route around."
**That conclusion was wrong.** Deeper investigation (prompted by a direct
request to fix it) found the real root cause back in `gems/ruby-to-clear`
and fixed it there - see the "propagate fallibility through
receiver-qualified constant calls" commit.

Actual root cause: `FunctionSignature#new` (the RUBY compiler class - this
whole file is itself part of the self-hosting corpus) generates a Ruby-side
`initialize` that calls `FunctionSignature.copy_requires_for_import(...)`
and `IntrinsicArgSpec.list_from_registry(...)` directly - both raise, so
`initialize` is genuinely fallible, and the translator's OWN body-lowering
for `initialize` correctly detects this and wraps those calls in `TRY`.
But `metadata_collector.rb`'s `propagate_transitive_fallibility!` - which
builds the `@inherently_fallible_methods` registry that EXTERNAL call sites
consult before deciding whether to wrap a call in `TRY` - only walked
**no-receiver** calls when building its fixpoint call-graph edges (a
deliberate scoping choice to avoid needing receiver-type inference, per its
own comment). `FunctionSignature.copy_requires_for_import(...)` and
`IntrinsicArgSpec.list_from_registry(...)` are both receiver-qualified, so
neither ever became an edge, and `initialize`/`new` never joined
`@inherently_fallible_methods` - even though the live, per-statement
`known_fallible_method?` check (used while lowering `initialize`'s own
body) correctly saw the same fallibility via a different, direct path.
Net effect: `FunctionSignature#dup`'s `FunctionSignature.new(...)` call
site - transpiled independently, consulting only the pre-built registry -
never got wrapped in `TRY`, producing exactly the "Cannot infer `copy` from
a fallible value" crash once other unrelated methods on the class (the
`intrinsic_contract` dispatch fix, elsewhere in this log) let the group
compile far enough to reach that line.

The false conclusion came from a real, correctly-executed experiment
(reverting the `intrinsic_contract` dispatch and confirming the crash
disappeared) that correctly proved WHICH change exposed the bug, but never
tested whether the bug's ROOT CAUSE lived in the translator or the compiler
core - it stopped at "not obviously the translator" instead of finding the
actual defect. The lesson: "isolated to the change that exposed a latent
bug" and "root-caused to the right subsystem" are different claims: proving
the former is not sufficient to conclude the latter, and the search should
have continued past the exposing change to the actual defect before
concluding a compiler-core cause and stopping investigation.

## Ruby `Mutex`/`Thread.new` has no CLEAR translation target (real corpus, `lsp/server.rb`, needs language-level concurrency design, not a stdlib call)

### Trigger

`lsp/server.rb` holds three `Mutex.new`-typed fields (`@analyze_mutex`,
`@output_mutex`, `@timer_mutex`, lines 38/41/46) guarding real shared
state across real OS threads it spawns itself
(`@timers[uri] = Thread.new do ... end`, line 303), synchronized via
`.synchronize { }` blocks (lines 77, 128, 270, 301, 321).

### Why this is not a quick stdlib addition

CLEAR's own concurrency model is fiber-based, not raw-OS-thread-based
(confirmed in `zig/lib/observable.zig:1121` - "`ParkingMutex` is
fiber-aware", not `std.Thread.Mutex`), with locking expressed as an
ownership-capability sigil on a value (`@locked`/`@writeLocked`) plus
a `WITH EXCLUSIVE c { ... }` block at the use site (`CLAUDE.md`'s
"Ownership / capabilities" section) - not a standalone `Mutex` object
type. Wrapping `Mutex`/`Thread.new` as a literal stdlib class (the way
`Digest::SHA256` below is scoped) would just re-introduce a
foreign, un-CLEAR-idiomatic concurrency primitive alongside the real
one. Getting this right needs: (1) confirming/designing what raw OS
thread spawning (as opposed to `BG`/fiber-based cooperative
concurrency) means in CLEAR at all, (2) a translator rule that lowers
a `Mutex`-typed ivar + `.synchronize { block }` into a `@locked` field
+ `WITH EXCLUSIVE`, and (3) per `CLAUDE.md`'s Concurrency Review
Requirements, a Hammer test under TSan/ASan for whatever thread
primitive backs it, since this is a genuine lock/thread introduction.
That is real language and runtime design work, not "call a Zig
function" - not attempted here.

## Ruby `String.new(encoding: 'ASCII-8BIT')` needs a byte-buffer type CLEAR doesn't have yet (real corpus, `tools/pprof.rb`)

### Trigger

`tools/pprof.rb` builds raw binary output (a profiling data format)
by allocating `String.new(encoding: 'ASCII-8BIT')` buffers (lines 30,
185, 227, 244) and writing arbitrary bytes into them, including via
`StringIO.new(...).set_encoding('ASCII-8BIT')` (line 227-228) -
using Ruby's `String` purely as a growable byte array, never as UTF-8
text.

### Why this is not a quick stdlib addition

This is the same underlying gap as the already-known
`force_encoding` limitation (`transpiler.rb`'s existing "force_encoding
is only translatable for Encoding::UTF_8; CLEAR strings do not carry
mutable encoding tags" message) - CLEAR's `String` is UTF-8 text, and
`docs/stdlib/strings-and-bytes.md:11-14` confirms a distinct byte-buffer
type is a known, still-open design item ("planned, self-host
required"), not something already available to route this call to.
Fixing just the `String.new(encoding:)` constructor call in isolation
wouldn't make `pprof.rb` translatable anyway - the whole file's approach
(byte-level binary writing through what Ruby treats as a String) would
need to target CLEAR's eventual byte-buffer type throughout, once one
exists. Deferred pending that design landing, not attempted here.

## EXTERN FN dot-call method with a literal argument fails to compile (real CLEAR compiler bug, root-caused, not fixed here)

### Trigger

Any `EXTERN FN TypeName.method(self: TypeName, param: SomeType) ...`
declaration (the `docs/agents/ffi.md:222-233` "Method Calls on EXTERN
Structs" feature - e.g. its own `Dir.makePath` example), called with an
untyped integer literal argument. Minimal repro (confirmed via a scratch
probe, not added as a transpile-test):

```
EXTERN STRUCT Counter { value: Int64 } FROM "probe";
EXTERN FN Counter.bumped(self: Counter, by: Int64) RETURNS Counter FROM "probe";
FN main() RETURNS Void ->
  MUTABLE c = Counter{ value: 0 };
  c = c.bumped(5);   -- fails to compile
  RETURN;
END
```

fails Zig compilation with `unable to resolve comptime value` / `initializer
of comptime-only struct '...__ExtM2' must be comptime-known`. Passing a
`by: Int64`-typed local variable instead of the literal `5` compiles and
runs correctly - confirmed by direct A/B test, isolating the literal itself
as the trigger.

### Root cause

`compiler/ruby/backends/mir_emitter.rb:829-832`, building the g0-trampoline
frame struct's field list for each runtime arg:
```ruby
field_type = arg.field_zig_type || arg.field_type&.zig_type(is_param: true)
fields << "a#{index}: #{field_type || "@TypeOf(#{args_tuple_name}[#{index}])"}"
```
only falls back to `@TypeOf(#{args_tuple_name}[#{index}])` when BOTH
`arg.field_zig_type` and `arg.field_type` are nil - i.e. this line is not
itself wrong, it's a legitimate fallback for when the argument's type isn't
known. For an `EXTERN FN`, the parameter's type IS statically known (it's
declared right there in the `EXTERN FN` signature), so this fallback should
never be needed at an extern-trampoline call site - meaning whatever MIR
lowering pass constructs `MIR::ExternTrampoline` nodes (not yet located -
the emitter only consumes `node.runtime_args`, doesn't build them) is not
populating `field_type`/`field_zig_type` on the runtime arg entries from the
EXTERN FN's own declared parameter types. When the un-typed fallback fires
AND the argument is an untyped literal, Zig infers `comptime_int` for that
tuple slot (`__extm2_args = .{ 5 }`), which makes the whole generated frame
struct "comptime-only" - incompatible with the trampoline's `var
__extm2_frame = ...` runtime instantiation. A typed local variable doesn't
trigger this because `@TypeOf(local_var)` resolves to that variable's
concrete runtime type regardless of the missing field_type - only a bare
untyped literal is affected.

### Why not fixed here

Found while scoping an unrelated stdlib addition (a `Digest::SHA256`
wrapper, see below) via a scratch probe test, not part of the `ruby-to-
clear` translator work this whole log otherwise documents. Fixing it
requires locating and correcting the MIR lowering pass that builds
`MIR::ExternTrampoline.runtime_args` (a different subsystem than anything
touched this session) so it threads the EXTERN FN's declared parameter type
through per this project's own INV-12 pattern - out of scope for the
current pass but the root cause above should make it a same-day fix once
picked up, with a transpile-test reproducing the exact minimal repro above
before the fix lands. Worked around for the SHA256 addition by using plain
(non dot-call) `EXTERN FN` functions instead, matching `stdlib/regex/src/
lib.clear`'s own existing convention (every `compilerRegex*` EXTERN FN
there is a free function taking the receiver as an ordinary first
positional argument, never `Type.method(self, ...)` dot-call syntax) -
this is not a workaround for a broken parser, it's simply not exercising
the one call shape that's broken.

## A control-flow-driven `.each` block (containing `next`/`break`) has its own, separate block-param type-inference gap (real corpus, one layer still open under the fixed `match`-field bug)

### Trigger

`ast/syntax_typo_scanner.rb`'s `RULES.each do |r| pat = r.match; next unless
...; ... end` - `RULES` a module-level `T.let([...].freeze, T::Array[
TypoRule])` constant, `TypoRule#match` a real struct field, and the block
body contains `next unless ...`.

### What's already fixed vs what's still open

Two real, general, verified bugs on this exact fingerprint were fixed
(`gems/ruby_to_clear/lib/ruby_to_clear/method_registry.rb`):
1. `array_element_type_for_receiver` only recognized the SUFFIX array-type
   convention (`T[]`, used by declared parameter types); a constant's own
   inferred type is stored in CLEAR's PREFIX convention (`[]T` / `[N]T` for
   a literal CLEAR infers a fixed length for) - so `.each`'s block param
   never got an element type at all when iterating a constant array. Fixed
   to recognize both.
2. `register("match")` unconditionally required exactly 1 argument and
   raised "match expects 1 argument" for anything else, including 0 args -
   but a 0-arg `.match` can never be a valid `String#match`/`Regexp#match`
   call (both require the pattern), so it can only be a same-named struct
   field this generic entry was shadowing. Fixed to decline (return nil,
   falling through to field resolution) specifically for the 0-arg case.

Both fixes are verified correct and general (gem spec suite green, new
regression tests added, real corpus dry-run confirmed for the SIMPLE case:
`RULES.each { |r| puts r.match }` now correctly emits `puts(_.match)`).

But the ACTUAL real corpus file still doesn't fully compile - it hits a
DIFFERENT error now (`[UNKNOWN_INHERENT_METHOD] Type TypoRule has no
inherent METHOD named 'match'`) at the CLEAR-frontend stage, because its
`.each` block contains `next unless ...`, which routes through a DIFFERENT
lowering strategy than the simple pipeline-`_` form (an indexed while-loop,
matching the shape `MUTABLE rtoc_idx = 0; WHILE ... DO items[rtoc_idx]...;
rtoc_idx = rtoc_idx + 1; END` already used for `each_with_index` blocks
with control flow - confirmed via direct dry-run: the real file emits
`rules[rtoc_idx].match()`, METHOD-CALL syntax with parens, instead of the
correct bare field access `rules[rtoc_idx].match`). This indexed-loop
lowering path does NOT go through `array_element_type_for_receiver`/
`block_effect_lowering` at all (confirmed: only one caller of the sibling
`for_each_effect_loop`, for `each_value`, unrelated) - it's a separate code
path with its own, independent element-type/field-resolution gap that
would need its own investigation to root-cause precisely.

### Why not fixed here

Same underlying CLASS of bug (constant-array element type not reaching a
block param's type in some lowering path), but a genuinely separate code
path from the two fixes above, and this session had already spent
significant effort tracing the SIMPLE-block-shape version of this bug
before finding it. Deferred as a distinct, still-open follow-up rather than
attempted under further time pressure - the two general fixes already
landed are real, independent progress regardless of when this piece gets
picked up.

## `Tuple#last` has no CLEAR overload (real corpus, `ast/error_registry.rb`, unmasked by the tuple-return-type fix, not caused by it)

### Trigger

`ast/error_registry.rb`'s `enum_entries` pipeline: `error_types.keys() |>
EACH { ... } |> ORDER_BY _.last()` over a `Tuple<String@symbol, Int64>`-
element collection, sorting by the tuple's second slot via `.last()`.

### Why this is not a regression from the tuple-return-type fix

Confirmed via the mandatory per-file verifier diff after landing the
tuple-return-type fix above: this file's classification shifted from
`g2-known-error` to `g2-unknown`, which looked like a regression at first
glance. Root-caused with the same method used for the `FunctionSignature#
dup` fallibility-inference case earlier in this log: the file's BASELINE
(pre-fix) error was the exact `[RETURN_MISMATCH] ... expected 'Tuple<Bool,
?(...)>', but returned 'Tuple<Bool,Void>'` bug the fix above targets and
resolves. With that fixed, the frontend compile proceeds further into the
SAME file and now hits this separate, pre-existing
`[INTRINSIC_NO_OVERLOAD] No overload for 'last' matches arguments (Tuple<
String@symbol,Int64>)` error - unmasked, not introduced. Net effect: this
file was already failing to compile before the fix and still is, just on a
different, later error; not a real regression.

### Assessment

Not investigated further - out of scope for this pass. Likely needs a
`Tuple#last`/`Tuple#first` intrinsic overload (or the translator lowering
`.last()` on a Tuple-typed pipeline element to positional field access,
`_._1`, instead of a method call) in whichever registry backs
`INTRINSIC_NO_OVERLOAD` diagnostics.

## Remaining real-corpus fingerprints that are genuine language/runtime limitations, not translator bugs (surveyed, not attempted)

Five real corpus fingerprints, root-caused against the actual triggering
source, are all cases where CLEAR (deliberately or by current scope) has no
target construct to translate to - matching the existing `is_a?`/`Regexp.
new`/Mutex precedents already in this log. None of these should be
"fixed" by loosening a check; each needs either a real language feature or
is out of CLEAR's translation scope entirely.

- **`is_a?` with a runtime class value** (`mir/mir_lowering.rb:907`,
  `semantic/escape_analysis.rb:138`): both pass a class *value* held in a
  local/parameter (`mir_class`, `klass`) to `is_a?`, i.e. genuinely dynamic
  type dispatch chosen at runtime. `IS_A` needs a compile-time-constant type
  name; `method_registry.rb`'s `static_first_argument_name` correctly
  rejects a `LocalVariableReadNode` argument. No compile-time type name
  exists here to substitute.
- **`Regexp.last_match`** (`tools/pprof_converter.rb:190`, `tools/
  clear_fix_support.rb:94`): both read Ruby's implicit `$~` state set by a
  *previous, separate* `=~`/match call - there is no CLEAR analogue of an
  ambient mutable match-state global. Same root cause as 2 of the 3 `gsub`-
  with-block sites already documented above (`ffi/c_header_importer.rb`,
  `incremental/program_artifact.rb`, both reading `Regexp.last_match(N)`
  inside a `gsub` block for capture groups).
- **`InterpolatedXStringNode`** (`tools/doctor.rb:311`, `tools/
  stack_verifier.rb:45`): Ruby backtick/`` `cmd` `` shell-exec syntax
  (`` `perf report ...` ``, `` `objdump -d ...` ``) - literally shelling out
  to an external process. CLEAR has no language concept for this at all,
  and both occurrences are host-side dev-tooling scripts (profiler/stack
  verifier), not logic that needs to run as compiled CLEAR.
- **`force_encoding` with a non-literal argument** (`incremental/
  source_catalog.rb:172`): `bytes.pack("C*").force_encoding(source.
  encoding)` - the existing `force_encoding` support only accepts a literal
  `Encoding::UTF_8` argument; here the argument is the dynamic expression
  `source.encoding`. CLEAR strings carry no runtime encoding tag to read
  back dynamically at all, so there's nothing a smarter literal-matcher
  could substitute - this is the same "no byte-buffer/encoding model" gap
  as the `String.new(encoding: 'ASCII-8BIT')` case documented above.
- **`Regexp.new` with a runtime-built pattern** (`lsp/diagnostics.rb:169`):
  `Regexp.new('\A' + body + '[.!?\s]*\z', Regexp::MULTILINE)`, where `body`
  is itself built from string concatenation of a caller-supplied template.
  `register("new", receiver: "Regexp")`'s rejection is deliberate (its own
  comment: static literals only) - this is exactly the dynamically-
  constructed-pattern shape the check exists to reject, not an
  overly-narrow case of an otherwise-static one.

## Next layer after the fallibility-propagation fix: two more distinct errors in the same 187-file package group (not yet investigated)

### Trigger

With the fallibility-propagation fix above landed, `scc_function_
signature_9` (the same 187-file group) now proceeds further and hits new,
distinct errors depending on scope:
- Whole-group compile: `[Compiler Error] SELECT expression returns !Type.
  Preserve that effect explicitly with SELECT:!, or consume it inside the
  SELECT expression.`
- A narrower `--only` scoped rerun (fewer files in the group): `[Compiler
  Error] [UNKNOWN_INHERENT_METHOD] Type TypeExpression has no inherent
  METHOD named 'capabilities'.`

### Status

Not investigated. Given this session's own recent lesson (the RETRACTED
entry above), do NOT assume either is a self-hosted-compiler-core bug
without isolating causality and finding the actual defect first - it could
equally be a `gems/ruby-to-clear` translator gap. Confirmed via the
mandatory per-file verifier diff that landing the fallibility fix is zero-
regression forward progress regardless (all 97 previously-`unknown`-crash
files now hit this next, classified error instead) - this note exists so
whoever picks up this thread starts from "not yet root-caused" rather than
re-doing the isolation work from scratch.

## Burn-down loop: next blocker is field access on an indexed array element (97 files, narrowly scoped, NOT yet fixed)

### Trigger

`IF params[rtoc_idx].takes THEN` - a FIELD read on an indexed array
element. Since an indexed read is optional in CLEAR (see the "indexed array
read is optional" fix), the frontend requires safe navigation: "Cannot
access field 'takes' on optional '?Param' without safe navigation."

### Scoping - the obvious fix is too broad, verified

The tempting fix is to unwrap at the each_with_index block-parameter alias
(`element_expr` in `each_with_index_effect_loop`), since the loop bound
`i < receiver.length()` already guarantees the element is present. That was
tried and REVERTED: a bare indexed read is perfectly valid in most
positions - `print(items[rtoc_idx])` compiles and runs (verified directly) -
so unwrapping at the alias changes 6 existing, passing behaviours to force
an unwrap they do not need.

The correct scope is the FIELD-ACCESS site only: when the receiver of a
field read is an indexed array element, emit the unwrap (or `?.`) there,
leaving every other use of the element alone. Not attempted here rather
than landing a broad change whose CLEAR-level correctness had not been
verified case by case.

### Field-access-on-indexed-element: second attempt also reverted (hangs the frontend)

A second, narrower attempt at the blocker above - unwrapping at the FIELD
ACCESS site only (`(UNWRAP (xs[i])).field`, with the outer parens that CLEAR
requires because UNWRAP binds looser than `.`) - was also reverted.

The emitted shape is correct in isolation: a hand-written probe of exactly
that form compiles and runs. But applying it across the corpus made the
whole `scc_annotator_34` group (97 files) go from a classified error to
`H0` - a TIMEOUT with no diagnostic - in a clean verifier run with nothing
else on the machine. So the change does not produce a bad program; it makes
the frontend hang or blow up super-linearly on the resulting code.

That is worth chasing on its own: it is a compiler-side scalability or
non-termination bug triggered by many `(UNWRAP (...)).field` sites, not a
translator bug. Whoever picks this up should reproduce with the two-line
change to `indexed_field_receiver_code` in call_lowerer.rb and profile the
frontend on the generated annotator group, rather than assuming the
translator output is wrong.

### Third attempt: `?.` is the right operator, but the frontend hang is NOT the operator

Per the language's own design, `arr[i].field` should lower to `arr[i]?.field`
- `?.` is built for exactly this. Confirmed against the frontend:
- `?.` works on an indexed receiver, bare or parenthesized;
- `!.` is TENSE navigation, and the frontend rejects it here with
  "Tense navigation `!.` does not match receiver type `?P`; use `?.`";
- `?.` yields an optional, so a boolean condition still needs it consumed:
  `IF (ps[i]?.takes OR_ELSE FALSE) THEN` compiles and runs.

The translator change was implemented and the gem suite went green. But the
frontend hang RECURS IDENTICALLY with `?.` (97 x H0 timeout), so the hang was
never about UNWRAP:

    annotator SCC group frontend compile:  33.7s  ->  >600s (timeout)

### Profile of the hang (stackprof, wall, 12020 samples)

`Type#contains_linear_resource?` accounted for 9876/12020 total samples
(~82%). Self time was dominated by allocation and sorbet-runtime prop
checking underneath it (`Class#new`, `T::Props::WeakConstructor#initialize`,
`T::Utils::Private.coerce_and_check_module_types`, `T::Private::Casts.cast`)
plus GC (`(sweeping)` + `(marking)`).

Two real defects were found and the first is fixed (see the commit touching
`compiler/ruby/ast/type.rb`):
1. FIXED - the visited set was COPIED at every node (`seen.dup.add(key)`), so
   sibling branches never shared it and a diamond-shaped type graph (the
   normal shape for struct schemas referencing common types) was re-walked
   once per PATH instead of once per node. Now one shared push/pop stack plus
   a within-call memo, memoizing only results not truncated by a cycle.
2. OPEN - the schema branches allocate fresh `Type` objects per visit
   (`Type.from_input` / `from_variant_input` / `substitute_generic_schema_
   field_type`), and the method is called once per type-check with no reuse
   across calls, so the graph is re-walked from scratch every time.

**The fix in (1) is committed and spec-clean but does NOT resolve the hang** -
the compile still exceeds 600s. A cross-call cache keyed on schema-lookup
identity was tried and also did not resolve it, so it was NOT landed (it
carries a staleness assumption and bought nothing measurable). Whoever picks
this up should re-profile with the current code rather than assume (1) or (2)
is the whole story - the remaining cost may be elsewhere entirely, since the
call-chain profile bottomed out in `ResolutionPhase.run` rather than in a
single leaf.

Reproduce: apply the two-line `?.` change (an `indexed_receiver_access`
helper used at the two field-access sites in `call_lowerer.rb`), regenerate,
and compile the `scc_annotator_34` group.

### Fourth attempt: memoization is NOT the fix either (two false signals, recorded so nobody repeats them)

`?.` was implemented and the perf theory was pursued to its end. It did not
work. What was tried, and what actually happened:

1. Shared visited-set + within-call memo in `contains_linear_resource?`
   (COMMITTED separately - a real algorithmic fix, spec-clean). Hang unchanged.
2. Cross-call memo keyed on `schema_lookup.object_id`. Hang unchanged - and
   the reason it could never have worked is worth knowing: the callers build
   a FRESH lambda per call (`resolver = ->(name) { lookup_type_schema(name) }`
   in `annotator/domains/lifetimes.rb`, per COPY node), so the key was unique
   every time.
3. Memoizing those resolvers so the key is stable, plus the cross-call memo.
   Hang unchanged (240s timeout, 97 x H0).

**Two false "it's fixed!" signals to watch for when re-testing this:**
- A run that finishes in ~0.8s because the artifact tree was deleted by a
  killed verifier - check for `No such file or directory ... .clear` in
  stderr.
- A run that finishes in ~5s with a pile of new `C0` parse errors, because
  the generated CLEAR now fails to PARSE and never reaches the expensive
  phase. (Here that was self-inflicted: `store[key] ||= {...}` in the
  compiler's own Ruby lowers to an assignment-used-as-an-expression, which
  CLEAR does not have. compiler/ruby is itself corpus - write
  `x = h[k]; if x.nil? ... end` instead.)
  Always confirm `timed_out=false` AND that the failure-code histogram did
  not shift before believing a speedup.

### Where this actually stands

The profile that showed `contains_linear_resource?` at ~82% of samples was
taken BEFORE fix (1). It is genuinely hot, but making it cheaper does not
resolve the hang - so either the cost is spread across many callers of it
(and the real problem is how often the annotator asks the question), or the
dominant cost has moved elsewhere and has not been re-profiled.

NEXT STEP: re-profile with `?.` applied and fix (1) in place - which has not
been done, because every profiling attempt so far either hit a stale dump or
was killed. Get a valid post-fix profile FIRST, then act on it. Do not
attempt another memoization variant without that profile.

### RESOLVED: the `?.` frontend hang was a reachability bug in contains_linear_resource?

Fixed. `contains_linear_resource?` answers "is any type reachable from here a
linear resource?" - plain graph reachability - but threaded `seen` with STACK
semantics (originally `seen.dup.add(key)` per node, later a push/pop stack).
Either way a node explored in one branch was explored again in every sibling
branch, so a diamond-shaped type graph was walked once per PATH.

Instrumented counts on the annotator group settled it:

    1,334 top-level calls -> 3,734,651 walks (~2,800 each) -> 767,065 Type allocs

Fix: `seen` is a monotone visited set, never unwound. Cycles then need no
special handling - re-entering an in-progress node yields false for that EDGE
while its own frame finishes its remaining children - and no memo is needed
at all. 33.7s/timeout -> 24.9s, and `?.` now lands with zero regressions.

Two earlier theories were WRONG and are recorded so they are not retried:
memoizing the walk (the cycle-guard made the memo dead), and eliminating the
defensive Type copy in the schema branch (real, 51% of samples, but only a
constant factor - the walk count was the problem). Note also that the profile
pointed at allocation (Class#new, sorbet prop checks) rather than at the walk,
because the cost was smeared across allocation sites; the COUNTS, not the
profile, identified the actual defect.

### Missing diagnostic: `${int}` interpolation emits invalid Zig

`print("n=${n}")` with `n: Int64` passes the frontend and then fails in Zig
with `expected type '[]const u8', found 'i64'`. Same for Bool. The working
idiom is `${n.toString()}` (transpile-tests/106, /197, /200 all use it), so
the frontend should either coerce or reject - emitting unchecked Zig is the
one thing it must not do. Same shape as the MATCH-on-optional bug below.

### Missing diagnostic: value-pattern MATCH on an optional subject

`PARTIAL MATCH dim START :ownership -> ...` where `dim: ?String@symbol`
passes the frontend and emits `if ((dim == __clear_symbol_0))` - invalid
Zig, `operator == not allowed for type '?[]const u8'`. The standalone `==`
lowering handles this correctly (classify_optional_binary_comparison emits
`if (dim) |cap| (cap == x) else false`), but equality_match_condition in
mir/lowering/control_flow.rb builds `MIR::BinOp.new("==", subject, ...)`
directly, bypassing that classification. Single-source-of-truth violation:
MATCH re-derives a comparison instead of routing through the one comparison
lowering. Not currently hit by the corpus (the translator narrows the
subject with `EXISTS AS` first), which is why it survived.

### Nested `each` loops emit wrong code (translator, pre-existing)

`each_with_index_effect_loop` hardcodes `index_name = "rtoc_idx"` and then
rewrites the block body with

    effect_code.gsub("CONTINUE;", "rtoc_idx = rtoc_idx + 1;\nCONTINUE;")

Two defects compose when one each loop nests inside another:

1. Both loops drive the SAME counter. Real corpus output from
   annotator/helpers/with_match_check.rb reads
   `call_sites[rtoc_idx]?.args[rtoc_idx]` - one index used for two
   different collections.
2. The outer gsub also rewrites CONTINUEs belonging to the INNER loop,
   which already had their increment substituted, so those paths increment
   twice. Visible in the same file as a doubled
   `rtoc_idx = rtoc_idx + 1;` before every CONTINUE.

Fixing (1) alone is not enough - a unique name per loop still leaves the
outer gsub descending into the inner body. Both need the substitution to
stop at a nested loop boundary. `reverse_each_effect_loop` already takes
the unique-name half of this (`next_generated_local("reverse_i")`).

Six specs pin the literal `rtoc_idx` text and will need updating with it.
Not currently the top corpus blocker, but it makes generated code wrong,
so it will surface again at G3/G4.
