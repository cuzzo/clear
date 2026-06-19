# Architectural Issues in `ast.rb`

This is a gap analysis of the current `gems/decomplex/lib/decomplex/ast.rb`
Tree-sitter normalization layer. Line references below refer to the current
file state at the time of this analysis.

## Executive Summary

`ast.rb` is not only an AST facade. It currently blends three separate jobs:

1. Tree-sitter grammar adaptation.
2. Cross-language semantic normalization.
3. Ruby AST compatibility and Ruby-specific scope semantics.

That mix defeats the intended architecture. If Decomplex has a parser facade,
a Tree-sitter normalizer, and per-language adapters, then grammar-specific
quirks must be owned by the adapters. The shared normalizer should consume
already-classified semantic facts, not mine native grammar tokens for every
language.

The current design still centralizes language knowledge in one giant shared
normalizer. Adding a language means editing shared dispatch tables, shared
punctuation checks, and Ruby-shaped AST output logic. That is brittle, hard to
test, and likely to regress existing languages.

## Quantitative Signals

Current `ast.rb` size:

- `gems/decomplex/lib/decomplex/ast.rb`: 4,023 lines.
- Rough static scan: 439 method definitions.
- Rough static scan: 129 methods contain `rescue StandardError`.
- Rough static scan: at least 10 trivial hook methods return only `false`,
  `nil`, or `true`.

The trivial hooks found by the scan are:

- `TreeSitterNormalizationAdapter#ruby?` at line 145 returns `false`.
- `TreeSitterNormalizationAdapter#super_statement?` at line 156 returns `false`.
- `TreeSitterNormalizationAdapter#member_assignment_target?` at line 222 returns `false`.
- `TreeSitterNormalizationAdapter#identifier_text_node?` at line 226 returns `false`.
- `TreeSitterNormalizationAdapter#case_argument_list?` at line 266 returns `false`.
- `TreeSitterNormalizationAdapter#case_else_arm?` at line 293 returns `false`.
- `TreeSitterNormalizationAdapter#ensure_clause_body` at line 489 returns `nil`.
- `TreeSitterNormalizationAdapter#heredoc_call_for_body?` at line 612 returns `false`.
- `TreeSitterNormalizationAdapter#zero_child_identifier_call?` at line 642 returns `false`.
- `RubyTreeSitterNormalizationAdapter#ruby?` at line 838 returns `true`.

Some no-op hooks are reasonable when they are an explicit adapter contract.
Here they are mixed into a large base adapter that also contains many concrete
language heuristics, so it is not clear which methods are deliberate extension
points and which are unimplemented behavior.

## Primary Architectural Gaps

### 1. Shared Normalizer Owns Language Dispatch

`TreeSitterNormalizationAdapter.for` selects an adapter at lines 128-135, but
the selected adapter does not actually own the language boundary. The base
adapter above it still contains cross-language constants and grammar knowledge:

- Function/class kinds at lines 49 and 70-73.
- Assignment operator tables at lines 50-56.
- Case/when/else grammar tables at lines 64-69.
- Wrapper and statement shape tables throughout lines 82-125.

Then `TreeSitterNormalizer#normalize_node` at lines 1524-1658 performs one
large global dispatch across all languages. It checks assignment, infix,
dotted calls, unary operators, functions, classes, modules, loops, cases,
hashes, arrays, element references, rescue, ensure, calls, identifiers, nil,
strings, and symbols in one ordering-dependent chain.

This makes the adapter layer incomplete. A new grammar still has to be wired
into shared lists and shared branch ordering. That is the exact direction the
architecture was supposed to avoid.

Expected direction:

- Each language adapter should classify native Tree-sitter nodes into a small
  canonical set of semantic categories.
- Shared code should normalize canonical facts, not native grammar nodes.
- Adding a language should mostly mean adding or updating one adapter/profile,
  plus tests for that language.

### 2. Ruby AST Vocabulary Is Treated as Language-Neutral

The comment at lines 1436-1441 says the target is "portable structural facts,
not Ruby semantics", but the output vocabulary is heavily Ruby-shaped:

- `DEFN`, `DEFS`, `SCOPE`, `VCALL`, `FCALL`, `ITER`, `DASGN`, `DVAR`.
- `IASGN`, `GASGN`, `GVAR`, `NTH_REF`.
- `ATTRASGN`, `OP_ASGN1`, `OP_ASGN2`, `OP_ASGN_OR`, `OP_ASGN_AND`.
- `MATCH3`, `BLOCK_PASS`, `RESBODY`, `SCLASS`.

Those are not neutral structural facts. They encode Ruby parser concepts and
Ruby name-resolution semantics. Forcing Python, Lua, TypeScript, Rust, C, Zig,
Swift, Kotlin, and Java into that vocabulary will either lose information or
invent false equivalences.

Expected direction:

- Decide whether this layer is a Ruby AST compatibility layer or a
  language-neutral Decomplex IR.
- If Ruby compatibility is still required, keep it as a Ruby-specific output
  adapter.
- Detectors should consume language-neutral concepts such as function, call,
  assignment, branch, loop, literal, member access, block, return, and scope.

### 3. `ruby?` Branches in Shared Code Prove the Normalizer Is Not Shared

`TreeSitterNormalizer` delegates `ruby?` to the adapter at lines 2688-2690,
then uses it throughout shared normalization:

- Root normalization enters Ruby scope tracking at lines 1512-1518.
- Ruby `yield` identifier handling appears at lines 1638-1643.
- Ruby `=~` handling appears at lines 1811-1815 and 2019-2023.
- Ruby `self[]` call rewriting appears at lines 1824-1826 and 3397-3399.
- Ruby hash key shorthand handling appears at lines 1915-1918.
- Ruby argument-list call normalization is gated at lines 2050-2073.
- Ruby argument-list element references are gated at lines 2168-2173.
- Ruby logical assignment lowering is gated at lines 2799-2808.
- Ruby local/vcall scope tracking lives at lines 2659-2686 and 2820-2910.
- Ruby parameter normalization is gated at lines 3024-3050.
- Ruby inline `def` handling lives at lines 3726-3793.
- Ruby tail return and implicit nil elision live at lines 3804-3858.
- Ruby inline parameter marker handling lives at lines 3860-3896.

This is adapter logic living in the shared normalizer. It also means the base
normalizer cannot be reasoned about independently from Ruby.

Expected direction:

- Remove language predicates from shared normalization.
- Move Ruby scope, vcall/fcall, inline def, tail-return elision, implicit nil,
  and Ruby-specific assignment lowering into a Ruby adapter or Ruby normalizer.
- Other languages should have their own scope/name-resolution rules or should
  explicitly opt out of name-resolution at this layer.

### 4. Broad `rescue StandardError` Masks Contract Failures

The file repeatedly uses `rescue StandardError` to return `false`, `nil`, or
empty arrays. The base adapter alone has many examples in the first few hundred
lines, including:

- `yield_statement?` at lines 149-153.
- `lambda_expression?` at lines 190-193.
- `literal_fragment_assignment_context?` at lines 230-239.
- `named_field` at lines 246-249.
- `safe_navigation_call?` at lines 252-255.
- `case_else_node` at lines 276-290.
- `leading_owner_statement?` at lines 319-327.
- `leading_if_statement?` at lines 336-346.

Later helper methods do the same for sibling and parent access at lines
3177-3198, and for shape detection such as `infix_statement_parts` at
2545-2566.

This hides missing optional values, wrong node shapes, facade bugs, and adapter
contract violations. A parser shape that should fail a test instead degrades
into "not this construct", which looks like partial language support rather
than a bug.

Expected direction:

- Provide safe node access helpers with explicit nil behavior.
- Rescue only known parser/facade exceptions at the parser boundary.
- Make adapter contracts explicit: a method should either return a documented
  optional value or raise a meaningful unsupported-shape error in tests.

### 5. Raw Token and Source-Text Mining Is Used for Semantic Decisions

Many semantic decisions are made by checking token text or raw node source:

- Safe navigation checks raw `&.` at lines 252-255.
- Leading function detection checks the first child kind against `"def"` at
  lines 303-305 and 722-726.
- Ternary detection checks raw `?` and `:` tokens at lines 709-718.
- Dotted calls check raw `.` and `&.` at lines 3254-3262.
- Argument-list element reference checks raw `[` and `]` at lines 2160-2165.
- Hash pairs check raw `=>` at lines 1907-1912.
- Operator assignment parses raw token text at lines 2785-2790 and 3629-3647.
- Inline def handling checks source text for `"def "` at lines 3726-3737.
- Hidden match detection checks `node.text` for `"match "` at lines 3969-3973.

This is not portable. Tree-sitter grammars expose punctuation and keywords
differently. Some grammars make punctuation anonymous, some name it, some hide
it behind fields, and some represent a construct as a dedicated node. Source
text also fails as soon as whitespace, comments, macro syntax, generated
facade text, or language-specific tokenization changes.

Expected direction:

- Adapters should use grammar fields and native node kinds to identify
  language constructs.
- Shared normalization should receive facts such as `safe_navigation_call`,
  `function_decl`, `ternary`, `member_access`, and `subscript`, not discover
  them with punctuation scans.

### 6. `safe_navigation_call?` Is in the Wrong Layer

The base implementation at lines 252-255 checks for Ruby's `&.` token. The
TypeScript override at lines 1304-1308 adds `optional_chain`/`?.` checks and
recursive call-expression scanning.

This should not be a shared base behavior. It is inherently grammar-specific:

- Ruby uses `&.`.
- TypeScript and JavaScript use `?.`.
- C# and Swift have their own optional chaining syntax.
- Kotlin has `?.` but a different grammar.
- Python has no equivalent built-in operator.
- Rust, C, C++, Zig, Go, Java, and Lua do not have the same concept in the
  same form.

Expected direction:

- Each adapter should expose optional-call/member-access semantics for its
  grammar.
- Languages without this feature should explicitly return "unsupported" or
  "not applicable", not inherit a Ruby token scan.

### 7. Leading Statement Helpers Assume Keyword Tokens

`leading_function_statement?` defaults to `def` at lines 303-305, and the
generic helper checks `node.children.first&.kind.to_s == keyword` at lines
722-726. Python overrides with another `"def"` check; Lua overrides with
`"function"`.

That is still keyword-token mining. It cannot scale to languages where
function declarations are identified by node kind, declarator shape, receiver,
macro item, annotations/modifiers, or field names rather than a first keyword
token.

Expected direction:

- Adapter methods should answer "this wrapper contains a leading function
  declaration" by using that grammar's function node and field structure.
- The shared normalizer should not know the keyword string.

### 8. Assignment and Operator Tables Are Global, Incomplete, and Unsafe

The base adapter defines assignment operators for Ruby, Python, Lua, and
TypeScript at lines 50-56. The fallback `assignment_operators` method returns
only `COMMON_ASSIGNMENT_OPERATORS` at lines 671-674.

That silently misclassifies or ignores languages with different assignment
forms or operators:

- Rust: `=`, `+=`, `-=`, `*=`, `/=`, `%=` plus bitwise/shift variants.
- C/C++/Java/C#/Go/Zig/Kotlin/Swift: overlapping but not identical augmented
  assignment sets.
- Languages with declaration assignment, walrus-like operators, or pattern
  assignment need grammar-specific handling.

Expected direction:

- Assignment/operator classification belongs in the language adapter/profile.
- Shared code should ask the adapter for an assignment semantic object, not
  infer assignment by checking sibling punctuation.

### 9. Scope and Local Resolution Are Ruby-Only but Central

The normalizer tracks Ruby locals with `@local_stack`, `with_ruby_scope`,
`ruby_scope_locals`, `collect_ruby_scope_locals`, `ruby_assignment_node?`, and
related helpers at lines 2820-2910. It uses that to decide whether identifiers
become `LVAR`, `DVAR`, `VCALL`, or `FCALL`.

That logic is Ruby-specific. Other languages have different scoping rules:

- Python has local/global/nonlocal behavior and lexical scopes.
- JavaScript/TypeScript have `var`, `let`, `const`, function scope, block
  scope, imports, and destructuring.
- Lua has globals by default and `local`.
- Rust, C, C++, Java, Kotlin, Swift, Zig, and Go have declaration forms and
  block/module scopes unlike Ruby.

Expected direction:

- Either remove name-resolution from this normalization layer, or delegate it
  to per-language scope adapters.
- The shared normalizer should not decide call-vs-local from Ruby local rules.

### 10. Parameter Normalization Is Ruby-Gated

`normalize_parameters` returns `nil` unless `ruby?` at lines 3024-3037.
`normalize_block_parameters` also returns `nil` unless `ruby?` at lines
3039-3050.

That means non-Ruby function parameters, defaults, destructuring, and block or
lambda parameters are mostly unavailable through this AST contract. This is a
large parity gap because many Decomplex detectors need parameters to
distinguish state, local data flow, receiver conventions, and trivial wrappers.

Expected direction:

- Language adapters should emit canonical parameter facts.
- Parameter normalization should exist for every supported language with
  explicit capability gaps.

### 11. Control-Flow Semantics Are Flattened Into Ruby Names

`RETURN_KINDS` at lines 1488-1497 maps `"continue_statement"` to `:NEXT` and
Ruby `next` also to `:NEXT`. `LOOP_KINDS` at lines 1454-1462 maps native loop
kinds into Ruby-ish symbols. Rescue/ensure normalization maps Python and
TypeScript exception constructs into `RESCUE`, `RESBODY`, and `ENSURE` shapes.

This may be acceptable for a Ruby compatibility mode, but it is not a neutral
model. `continue`, Ruby `next`, `break`, `return`, `throw`, `raise`, `panic`,
and exception/finally constructs do not have identical semantics across
languages.

Expected direction:

- Use neutral control-flow facts: `return`, `break`, `continue`,
  `exception_handler`, `finally`, `throw`, and language-specific termination
  signals where needed.
- Only convert to Ruby names at the Ruby compatibility boundary.

### 12. Literal Semantics Are Conflated Across Languages

`NIL_KINDS` at line 1487 conflates `nil`, `none`, and `null`. Terminal
statement handling at lines 3557-3575 hard-codes Ruby spellings such as
`nil`, `true`, `false`, symbols, instance variables, globals, and `[]`.
Scalar argument handling repeats similar text matching at lines 3910-3927.

That loses important distinctions:

- Python `None`, JavaScript `null`, JavaScript `undefined`, Ruby `nil`, Swift
  `nil`, Zig `null`, and Go `nil` are not always equivalent in analysis.
- Ruby symbols do not exist in most target languages.
- Ruby globals and numbered captures are not portable.

Expected direction:

- Adapters should classify literals into canonical literal facts with original
  language and spelling preserved.
- Detectors should decide which literal classes are equivalent for a specific
  metric.

### 13. Member Access and Calls Are Guessed by Shared Heuristics

`MEMBER_KINDS`, `CALL_KINDS`, `IDENTIFIER_KINDS`, and `CONST_KINDS` live in the
shared normalizer at lines 1474-1482. Member parsing is then guessed in
`member_parts` at lines 2912-2929 by trying several field names and falling
back to child order.

That is unsafe across languages. Member access differs for:

- Ruby calls without parentheses.
- JavaScript optional chaining and private fields.
- C/C++ pointer member access.
- Rust paths, method calls, and associated functions.
- Go selectors.
- Swift/Kotlin null-safe access.
- Python attributes and calls.

Expected direction:

- Each adapter should expose a canonical call/member/subscript shape.
- Shared code should not infer receiver and method name by trying a long list
  of field names from unrelated grammars.

### 14. Unsupported Languages Silently Use the Generic Adapter

`TreeSitterNormalizationAdapter.for` falls back to `new(document)` at line
134. That means unsupported languages appear to work using generic heuristics.
The result is worse than a clean unsupported error because detectors can
publish partial, misleading findings.

This is especially risky because `syntax.rb` already has `LANGUAGE_PROFILES`
for many languages at lines 2510-2598, while `ast.rb` only selects dedicated
normalization adapters for Ruby, Python, Lua, TypeScript, and JavaScript at
lines 128-135.

Expected direction:

- Require an explicit normalization adapter/profile for every language that
  flows through `Ast.parse`.
- If a language is only partially supported, expose a capability matrix and
  skip unsupported detector paths explicitly.

### 15. There Are Two Adapter Systems That Can Drift

`syntax.rb` already defines `TreeSitterLanguageAdapter` and language profiles
starting at lines 271 and 2510. Those profiles contain language lexicons,
function extraction, owner extraction, state reads/writes, call targets,
parameters, and branch facts.

`ast.rb` defines a separate `TreeSitterNormalizationAdapter` starting at line
45 with its own function kinds, owner kinds, assignment operators, branch
heuristics, safe navigation logic, parameters, rescue/ensure handling, and
language subclasses.

That is duplicated ownership. A language feature can be fixed in one adapter
layer and remain broken in the other. This is likely why language-specific
logic keeps reappearing in the wrong file.

Expected direction:

- Unify adapter ownership, or make one adapter explicitly depend on the other.
- There should be one place where language grammar knowledge is defined.
- `ast.rb` should not maintain its own parallel language universe.

### 16. Source Span Utilities Are Mixed With Semantic Rewrites

`wrap`, `source_before_child`, `source_from_nodes`, and
`source_from_normalized_nodes` at lines 3087-3171 construct spans and source
text while the same class performs semantic rewrites.

This increases coupling. Transform code has to know how spans are rebuilt,
and span code has to handle both Tree-sitter nodes and already-normalized
nodes.

Expected direction:

- Move span/source helpers behind a small source mapping utility.
- Keep semantic normalization focused on semantic shape.

### 17. Dispatch Ordering Is an Implicit Contract

`normalize_node` at lines 1524-1658 and `normalize_body` at lines 2316-2359
both contain long, order-sensitive dispatch chains. The same conceptual
constructs are checked in several places: leading functions, leading branches,
rescue/ensure bodies, calls with blocks, infix statements, unary operations,
element references, arrays, hashes, and terminal statements.

Adding a new language or construct requires knowing exactly where it belongs
in two large branch chains. A new check can shadow an older one globally.

Expected direction:

- Classify once into a semantic category.
- Dispatch on that category with a small table or polymorphic handler.
- Keep body normalization and expression normalization separate where the
  language actually distinguishes statements and expressions.

## Cross-Language Incompatibilities

These are representative examples of logic that cannot be correct across
languages while living in shared code.

| Current behavior | Why it is not portable | Better owner |
|---|---|---|
| `safe_navigation_call?` checks `&.` in the base adapter. | Optional chaining is language-specific and absent in many languages. | Per-language adapter. |
| `leading_function_statement?` searches for `"def"` or `"function"` keyword tokens. | Function declarations are grammar-specific and often declarator-based. | Per-language adapter. |
| `ruby?` gates shared normalization. | Shared code changes behavior by language instead of using polymorphism. | Ruby normalizer or adapter. |
| `NIL_KINDS = %w[nil none null]`. | Nil/null/None/undefined have different semantics. | Literal classifier per language. |
| `RETURN_KINDS` maps `continue_statement` to `NEXT`. | Ruby `next` and non-Ruby `continue` are not the same abstraction. | Neutral control-flow IR. |
| `self_node?` maps `self` and `this` together. | `self`, `this`, receiver, class/static context, and module context differ. | Language scope/receiver adapter. |
| `member_parts` guesses receiver/member from many possible field names. | Member grammar differs widely and includes pointer, path, optional, private, and static forms. | Per-language call/member adapter. |
| `assignment_lhs?` checks sibling token text. | Assignment shape is not reliably represented by adjacent punctuation. | Per-language assignment classifier. |
| `normalize_parameters` is Ruby-only. | Non-Ruby functions lose parameter facts. | Per-language parameter adapter. |
| `normalize_pair` assumes Ruby hash semantics and symbol shorthand. | Object literals, dictionaries, tables, maps, and hashes differ. | Per-language literal/container adapter. |
| `vcall_identifier?` and `ruby_vcall_identifier?` decide local vs call. | Bare identifier semantics differ by language. | Per-language scope adapter or detector layer. |
| Rescue/ensure are normalized as Ruby `RESCUE`/`ENSURE`. | Exceptions/finally/defer/panic/error returns differ substantially. | Neutral exception/control-flow IR. |

## Recommended Remediation Plan

### P0: Stop the Architectural Bleeding

- Do not add new language support by extending shared constants in `ast.rb`.
- Remove or isolate `ruby?` checks from `TreeSitterNormalizer`.
- Stop silent fallback to the generic normalization adapter for unsupported
  languages.
- Replace broad `rescue StandardError` in hot-path shape checks with explicit
  nil-safe accessors and documented adapter contracts.
- Move Ruby-only behavior out of the shared normalizer first: local/vcall
  scope, inline def, implicit nil, tail return elision, Ruby argument-list
  calls, Ruby hash shorthand, and Ruby `=~`.

### P1: Define the Adapter Contract

- Define the canonical facts a language adapter must provide:
  function declaration, class/owner declaration, call, member access,
  assignment, parameter, branch, loop, case arm, return/break/continue,
  literal, string interpolation, exception handler, finally/ensure, and block.
- Make capability gaps explicit. A language should say "I do not support this
  fact yet" rather than returning `false` from inherited generic heuristics.
- Pull punctuation and keyword-token checks into language adapters.
- Add adapter-level fixture tests per language that assert canonical facts,
  not Ruby AST node names.

### P2: Separate Ruby Compatibility From Decomplex Semantics

- Introduce a language-neutral semantic IR for detector input.
- Keep Ruby AST-compatible node names only as a compatibility adapter for
  legacy Ruby detector code.
- Migrate detectors toward semantic facts and away from Ruby parser node names.
- Preserve source spans as a separate utility so semantic normalization is not
  responsible for source reconstruction.

### P3: Unify `syntax.rb` and `ast.rb` Language Ownership

- `syntax.rb` already has language profiles and structural fact extraction.
- `ast.rb` should either consume those profiles or be refactored so profile
  ownership lives in one place.
- Avoid parallel adapter hierarchies with overlapping function, owner, branch,
  assignment, call, and state semantics.

## Desired End State

The ideal architecture should look like this:

1. `Syntax.parse` produces a Tree-sitter document with a known language
   profile.
2. The language adapter owns grammar-specific queries and token quirks.
3. The adapter emits canonical semantic facts or canonical syntax nodes.
4. The shared normalizer only maps canonical facts into Decomplex's detector
   model.
5. Ruby AST compatibility, where still required, is a Ruby-specific adapter,
   not the shared representation.

In that design, adding Rust, Zig, Go, C, C++, Java, Swift, Kotlin, or any other
language does not require stuffing more native grammar names into
`TreeSitterNormalizer#normalize_node`. It requires implementing that language's
adapter contract and proving it with language-specific fixtures.

## Current Remediation Notes

The Ruby production detector path has moved in this direction:

- `FalseSimplicity` now consumes `Syntax::SemanticEffectSite` facts and owner /
  function facts. Ruby-specific effect lexicons and grammar quirks live under
  `lib/decomplex/syntax/ruby_effects.rb`.
- `OrderedProtocolMine` now consumes `Syntax::ProtocolMethodEffect` and
  `Syntax::ProtocolMethodPath` facts. Ruby branch/case/lambda path semantics and
  state-effect extraction live under `lib/decomplex/syntax/ruby_protocols.rb`.
- `SequenceMine` and `OversizedPredicate` now consume `Syntax` call and decision
  facts directly instead of `Ast.parse_semantic`.
- `Syntax` no longer requires the `Ast` facade; the dependency now points from
  compatibility parsing toward `Syntax`, not from Syntax back into Ast.
- Ruby structural/local/path helper behavior has been split out of `syntax.rb`
  into `lib/decomplex/syntax/ruby.rb`; Ruby effect and protocol quirks live in
  `ruby_effects.rb` and `ruby_protocols.rb`.
- A production detector grep no longer finds `Ast.parse`, `Ast.parse_semantic`,
  or legacy Ruby AST node names outside the `ast.rb` compatibility facade.

Remaining architectural debt:

- `ast/legacy_normalizer.rb` still exists as a Ruby-shaped compatibility layer.
- Non-Ruby profile behavior in `syntax.rb` should continue moving into
  language-specific profile files as those languages are made first-class.
- Rust still needs to mirror the Ruby architecture with minimal changes after
  Ruby verification is complete.
