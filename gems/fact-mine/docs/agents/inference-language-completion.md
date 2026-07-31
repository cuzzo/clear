# Big-O completion in inference languages

Go reaches ~93% complete bounds on a corpus whose non-project calls are all
stdlib. Rust, TypeScript and Python did not, and the reason is one design
decision applied unevenly, not a property of type inference.

## Measured

Each corpus is production code only, its own SCIP index attached, measured with
`script/diagnose_big_o_gaps.rb`.

| Corpus | Language | Indexer | Functions | Was | Now |
| --- | --- | --- | ---: | ---: | ---: |
| `gems/decomplex` | Rust | rust-analyzer | 1144 | 75.2% | 77.3% |
| `gems/decomplex` + dependency indexes | Rust | rust-analyzer | 1144 | 76.3% | 78.1% |
| zod `src/v4/{core,classic}` | TypeScript | scip-typescript | 1305 | 48.2% | 72.5% |
| rich `rich/` | Python | scip-python | 877 | 28.7% | 29.0% |
| unslop | Go | scip-go | 145 | 93.1% | 93.1% |
| gremlins | Go | scip-go | 200 | 60.5% | 60.5% |

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

| Adapter | How an operator is priced |
| --- | --- |
| Go | a hardcoded operator list, type-blind: `==`, `<`, `+` are O(1) |
| Rust, TypeScript, C++, Ruby | only against an operand type proven to be a scalar |
| C# | the shared rule, via `scalar_type_names` |
| Java, Kotlin, Python, JavaScript, Swift, PHP, Lua, C, Zig | not at all |

No language configures operators in `config/stdlib_complexity/*.yml`; the shared
`scalar_operator_complexity` in `normalized_behavior.rs` was dead code for every
adapter but C#, since `scalar_type_names` defaults to empty and only C#
overrides it.

So the languages that demand an operand type are exactly the ones where a hole
in type resolution shows up as an unpriced operator, and Go's advantage is that
it asks no question it cannot answer. Measured ceiling, pricing every operator
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

### Rust - `gems/decomplex`, 77.3%

- `dependency_cost_model_missing`, 111 functions. Dominated by sibling workspace
  crates (`fact-mine-rust`, `hazard-contract`) plus serde_json and regex. The
  declarations are recoverable - indexing fact-mine and attaching it as
  `--scip-dependency-index` is worth +2.4 points on its own - but the *costs*
  are not: attaching declarations moved this category by zero. A dependency
  needs a complexity summary, the same artifact the bundled stdlib summaries
  are.
- `stdlib_cost_model_missing`, 82 functions. Concrete and small:
  `PartialOrd::partial_cmp` / `Ord::cmp` on `f64`/`i64`/`isize` (17 functions),
  `HashMap::values`, `HashMap::into_iter`, `Entry::and_modify`,
  `Entry::or_insert_with`, `BTreeSet::union`, `Command::{arg,args,output}`,
  `ExitStatus::success`, `thread::Scope::spawn`, `ScopedJoinHandle::join`.
- Record shapes for dependency types are absent, so a comparison or copy of one
  cannot be priced by its fields. Verified: `SimilarityFinding`,
  `CloneCandidate`, `SemanticEffectSite` carry no symbol in decomplex's index
  because they are declared in fact-mine.

Attaching the whole Rust stdlib index is worth +1.1 points, not the dominant
lever [`rust-completion.md`](rust-completion.md) took it for.

### TypeScript - zod, 72.5%

- `semantic_identity_missing`, 158 functions: `project_lexical_binding_missing`
  36, `reflection_or_dynamic_dispatch` 21,
  `receiver_identity_missing_no_project_candidate` 21.
- `stdlib_cost_model_missing`, 109 functions. `config/stdlib_complexity/typescript.yml`
  is 105 lines against Go's 735: no `Promise` at all (`Promise#then` alone
  blocks 29 functions, `Promise.all` 11), no `String#replace`, no `Number`, no
  `BigInt`, no `Object` statics.
- Remaining operand types that resolve but do not price: a union (73 sites), a
  nilable scalar (42), a string-literal type (30), `typeof e` (the operand
  resolves to the type of `e`, when what `typeof` yields is a string).

### Python - rich, 29.0%

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

## Plan

Ordered by measured yield per unit of work. Each step is verifiable against the
table above; re-measure all six corpora after each, since a fix that helps one
language must not move Go.

1. **Give every adapter the shared operator rule.** Populate `scalar_type_names`
   for Java, Kotlin, Python, JavaScript, Swift, PHP, C and Zig, and collapse the
   Rust/TypeScript/C++/Ruby overrides onto it so there is one rule and a list of
   names per language. Java and Kotlin cannot overload arithmetic on primitives,
   so they price like Go once the names exist.
2. **Price an operator over a wrapped or alternative type.** Reduce `Nilable(T)`
   to `T`, and price a `Union` as the worst of its alternatives, unknown if any
   alternative is unknown. Treat a literal type as what it is: fixed size.
   Measured 145 further sites in zod alone.
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
