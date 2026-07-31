# Big-O completion in inference languages

Go reaches ~93% complete bounds on a corpus whose non-project calls are all
stdlib. Rust, TypeScript and Python did not, and the reason is one design
decision applied unevenly, not a property of type inference.

## Measured

Each corpus is production code only, its own SCIP index attached, measured with
`script/diagnose_big_o_gaps.rb`.

| Corpus | Language | Indexer | Functions | Was | Now |
| --- | --- | --- | ---: | ---: | ---: |
| `gems/decomplex` | Rust | rust-analyzer | 1144 | 75.2% | 81.3% |
| `gems/decomplex` + dependency index and summary | Rust | rust-analyzer | 1144 | 76.3% | 82.7% |
| zod `src/v4/{core,classic}` | TypeScript | scip-typescript | 1305 | 48.2% | 73.0% |
| rich `rich/` | Python | scip-python | 877 | 28.7% | 30.0% |
| unslop | Go | scip-go | 145 | 93.1% | 93.1% |
| gremlins | Go | scip-go | 200 | 60.5% | 60.5% |

`complete` above means the bound closed, which the diagnostic reports as
`big_o_complete` and which **folds the parametric tier in with the complete
one**. Split three ways, decomplex with its dependency artifacts attached is
59.7% complete, 23.1% parametric - a bound whose shape is closed but which
still names an open callback `C` or reflective `R` - and 17.3% incomplete.
Quote the three-way split when the question is how much is actually proven.

Function-level completion understates the operator work, because a function
usually carries several blockers and clearing one class rarely flips it. The
operator call facts themselves:

| Corpus | Priced before | Priced now |
| --- | ---: | ---: |
| rich | 7/701 (1.0%) | 292/699 (41.8%) |
| zod | 160/788 (20.3%) | 695/788 (88.2%) |
| decomplex | 397/550 (72.2%) | 494/550 (89.8%) |
| unslop | 661/661 (100%) | 661/661 (100%) |

Reproduce:

```
rust-analyzer scip . --output <crate>.scip          # Rust
scip-go --output <repo>.scip                        # Go
scip-typescript index --cwd . --output <repo>.scip  # TypeScript
scip-python index --project-name <n> --output <repo>.scip .
fact-mine-rust profile espalier --output p.json --scip-index <repo>.scip FILE...
ruby script/diagnose_big_o_gaps.rb --source-root R --repository N p.json
```

Two Go corpora are listed deliberately. unslop calls its own code and the
stdlib; gremlins calls third-party packages, and lands at 60.5%. The gap between
them is the dependency cost model, not the language - quoting one number for
"Go" hides which of the two a comparison is really about.

## Where it originates

An operator is emitted as a call fact in every language. Whether it is ever
priced is decided per adapter, and the adapters disagree:

| Adapter | How an operator was priced |
| --- | --- |
| Go | a hardcoded operator list, type-blind: `==`, `<`, `+` are O(1) |
| Rust, TypeScript, C++, Ruby | a hand-rolled copy of the shared rule, each with its own names |
| C# | the shared rule, via `scalar_type_names` |
| Java, Kotlin, Python, JavaScript, Swift, PHP, Lua, C, Zig | not at all |

No language configures operators in `config/stdlib_complexity/*.yml`; the shared
`scalar_operator_complexity` in `normalized_behavior.rs` was dead code for every
adapter but C#, since `scalar_type_names` defaults to empty and the four
adapters that did price operators had each overridden the rule rather than
feeding it.

Fixed. There is now one rule and no override of it. An adapter contributes
exactly two things - which names are its machine scalars, and which operators it
dispatches differently - and the shared rule owns everything structural: a
nilable scalar is a scalar, alternatives price as the worst of them, a type
spelled as a literal holds what the spelling fixes. Nine adapters that priced no
operator at all now do.

The languages that demand an operand type are exactly the ones where a hole in
type resolution shows up as an unpriced operator, and Go's advantage was that it
asks no question it cannot answer - at the cost of pricing `s1 + s2` on two Go
strings as O(1), which is wrong and is why the shared rule does not copy it. Measured ceiling, pricing every operator
unconditionally: Rust 75.2 -> 79.5%, TypeScript 48.2 -> **74.1%**, Python
28.7 -> 30.0%. TypeScript's whole deficit against Go was operators.

## The pattern behind the type gaps

Every operand that failed to resolve was a compound expression whose result type
differs from its head's type, and `operator_operand_type` answers with the head:
its last fallback takes any local named anywhere in the operand and returns that
local's type. `common.len() as f64 / (total as f64)` resolved to
`Array(Primitive("String"))`; `row.union_width + row.nested_union_width` to the
record that holds them. A wrong answer is worse than none, because it silences
the rules that would otherwise fire.

Three defects fed it, each fixed:

- `[T; N]` parsed as an array of `T; N`, a name no scalar rule matches, so
  `span[0] < span[2]` stayed unpriced although the index resolved `span`
  exactly. (`Read a fixed-length array as the element it holds`)
- scip-typescript leads every member and parameter with what kind of declaration
  it is - `(property) code: string`. That parenthesis read as a call signature,
  so the type was discarded: 322 of the 403 operand declarations available in
  zod. (`Read a declaration past the kind the indexer names it by`)
- a comparison against a literal, a constant, or a variant built from parts no
  input grows needs no operand type at all: it reads at most what the fixed side
  holds. This is what types the largest class of comparison in every language -
  a value from an external call checked against a spelling the source states -
  and it is why zod moved 24 points. (`Price a comparison by the side that holds
  a fixed amount`)

## What each language is blocked on now

Ranked by the diagnostic's primary root-cause partition.

### Rust - `gems/decomplex`, 81.3%

Of 198 incomplete, 100 are purely transitive - no blocker of their own, they
resolve as their callees do. The leaf work is ~160 roots and it is a long tail:
the top 5 unblock 46, the top 20 unblock 94, the top 40 unblock 126.

- `dependency_cost_model_missing`, 123 functions - 62% of what is left.
  Declarations are recoverable by indexing the dependency, but the *costs* are
  not: attaching declarations alone moved this category by zero. A dependency
  needs a complexity summary, the artifact the bundled stdlib summaries already
  are, and generating one now works (see below). Its yield is bounded by the
  dependency's own completion: fact-mine closes 1002 of 8588 methods, so the
  calls decomplex leans on most are ones fact-mine has not closed either. This
  improves as the dependency does.
- `stdlib_cost_model_missing`, 18 functions, down from 82.
- `allocation_bound_unproven`, 16 primary / 43 direct. 445 of 499 allocations
  have unknown cardinality and 327 of those are `clone`. A scalar clone now
  prices; the remainder are mostly `String` clones, honestly O(len) of an
  element whose size is not any named domain. Closing them needs a per-element
  size domain, which is a modelling extension rather than a defect.
- `recursive_progress_unproven`, 11. `semantic_identity_missing`, 5.

Attaching the whole Rust stdlib index is worth +1.1 points, not the dominant
lever [`rust-completion.md`](rust-completion.md) took it for.

Producing a dependency summary:

```
rust-analyzer scip . --output dep.scip                 # in the dependency
fact-mine-rust profile espalier --output dep.json --scip-index dep.scip FILE...
ruby script/export_complexity_summary.rb --corpus <id> --source-revision <rev> \
  --indexer rust-analyzer@1.96.0 --consumer-indexer rust-analyzer@1.96.0 \
  dep.json dep-summary.json
fact-mine-rust profile espalier ... --scip-dependency-index dep.scip \
  --complexity-summary dep-summary.json
```

### TypeScript - zod, 73.0%

- `semantic_identity_missing`, 158 functions: `project_lexical_binding_missing`
  36, `reflection_or_dynamic_dispatch` 21,
  `receiver_identity_missing_no_project_candidate` 21.
- `stdlib_cost_model_missing`, 109 functions. `config/stdlib_complexity/typescript.yml`
  is 105 lines against Go's 735: no `Promise` at all (`Promise#then` alone
  blocks 29 functions, `Promise.all` 11), no `String#replace`, no `Number`, no
  `BigInt`, no `Object` statics.
- `typeof e` still resolves to the type of `e`, when what `typeof` yields is a
  string; 196 sites. Unions, nilable scalars and literal types now price.

### Python - rich, 30.0%

Python is not blocked on operators, and the operator ceiling is worth 1.3
points. It is blocked before that:

- `semantic_identity_missing`, 350 functions, of which
  `project_receiver_known_member_absent` is 358 call sites: the receiver's type
  is known and the member is not found among project declarations.
- `external_cost_model_missing`, 233 functions. Two distinct causes in one
  bucket. A project class used as a constructor - ``rich.text`/Text#``, 47
  functions; `Measurement#` 19; `Segment#` 18 - names the class, not a method,
  and does not resolve to the project. And `python.yml` gaps: `str#join` (28
  functions), `list#append` (20), `next()` (20), `iter()` (18), `getattr()`
  (17), `dict#get` (17).
- Python has no `SemanticSymbol` section in its registry and never calls
  `configured_semantic_symbol_call_complexity`, so an exactly resolved symbol
  such as `builtins/list#append().` has no path to a cost at all. Nine
  languages have that channel; python, typescript, php, swift, c and zig do not.
- Annotation spellings survive into the type: `Primitive("\"ConsoleOptions\"")`
  from a quoted forward reference, `Primitive("int:")` from a trailing colon.

Two adapter gaps found along the way, neither an operator-pricing problem:
Swift emits no call fact for an operator at all, so there is nothing to price;
JavaScript and Lua spell no declared scalar in source, so their names only take
effect where a flow hint or annotation supplies one.

## Plan

Ordered by measured yield per unit of work. Each step is verifiable against the
table above; re-measure all six corpora after each, since a fix that helps one
language must not move Go.

1. ~~Give every adapter the shared operator rule.~~ Done.
2. ~~Price an operator over a wrapped or alternative type.~~ Done, in the same
   rule.
3. **Resolve an operand by its form, not by a local it mentions.** Replace the
   base-local fallback in `operator_operand_type` with a recursion over the
   expression: literal, cast, index, member read, call, parenthesised, unary.
   Fall back to a bare name's type only when the operand *is* that name. This is
   the defect that produced the wrong answers above; the rest of the operand
   work is downstream of it.
4. **Fill `typescript.yml` and `python.yml` from the measured symbol tallies**,
   not from imagination. The diagnostic already ranks exactly which symbols
   block how many functions.
5. **Resolve a constructor to the class it constructs.** A symbol ending at
   `Owner#` names a type; a call on it is that type's initializer. This is the
   single largest Python bucket and it recurs wherever a language spells
   construction as a call.
6. **Give Python the symbol-keyed cost channel** every other indexed language
   has, then the same for typescript, php, swift, c, zig.
7. **Summarize dependencies, not just index them.** Declarations alone moved
   `dependency_cost_model_missing` by zero. The bundled stdlib summaries are the
   existing mechanism; a dependency needs the same artifact, produced by
   `script/export_complexity_summary.rb`. Note the exporter currently aborts on
   a registry/analysis conflict rather than preferring one, which has to be
   settled first.
8. **Close the Rust stdlib registry gaps** listed above. Small, bounded, and it
   is 82 functions in one corpus.

Not on this list: attaching more dependency indexes for their declarations. It
is measured at +1.1 points for the whole Rust stdlib and +2.4 for one sibling
crate, and it is strictly cheaper to reach the same functions through steps 1-3.
