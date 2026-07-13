# Nil-kill: find `nil`s and type ambiguity at the source.

![Nil-kill](docs/assets/nil-kill.png)

 * Nil-kill helps you eliminate `nil`s and strongly type your codebase by showing where the pressure originates.
 * It combines *static analysis* with *runtime observations*. It has
   cross-language support via [Tree-Sitter](https://github.com/tree-sitter/tree-sitter).
 * Nil-kill emits evidence and action plans. Source rewriting lives in [Auto-type](../auto-type/README.md).

## What is *pressure*?

You can often times resolve one `nil` or type ambiguity and remove hundreds nil guards (`&.`, `.present?`) and type checks: `x.is_a?(MyType)`.

Nil-kill helps you prioritize your efforts by *pressure*.

### Nil-kill's Four Types of Pressure

1. Nil pressure: where `nil` originates and how many nil guards it
   causes.
2. Union type pressure: when code occasionally assigns a symbol to a
   string, an int to a float, or otherwise mixes unrelated value shapes.
3. Enum pressure: when code uses a symbol, string, or integer as an
   ad hoc enum.
4. Primitive pressure: when code uses a hashmap as an ad hoc struct or
   an array as an ad hoc tuple.

## How well does it work?

Nil-kill was introduced when the CLEAR compiler was ~50k lines of Ruby
(production code, not counting test code). It helped automatically type
most of the Ruby code in preparation for self-hosting / translating to
CLEAR.

 * ~50% of T.nilable() removed, ~50% of `&.` and `.present?` removed.
 * ~70% of signature parameters could be inferred automatically combining runtime and static analysis.
 * ~80% of signature returns could be inferred automatically.

Nil-kill generates an overall report of your codebase. The top of the
report lists the metrics you need to determine how well it *might* help
you before you invest more into using it fully.

### The long tail problem

After hundreds of prioritized triage commits, thousands of untyped slots
still remain in the Ruby compiler for CLEAR. Nil-kill keeps these
outstanding items prioritized by highest impact.

 * If you resolve the type for `x[:name]` -> that will unlock N signature param slots, M signature returns, L class/struct fields, K hashmap/array types.
 * LLMs have responded well to this input to type the codebase slowly in the background.

## How do I use it?

In short, Nil-kill has 6 analyzer uses, but the 4 major ones are:

 1. `nil-kill infer`: this mainly outsources to Sorbet and z3 to do static analysis and type your codebase as much as possible without runtime analysis.
 2. `nil-kill collect -- <command>`: this does runtime data collection. The `<command>` could be just `bundle exec rspec` -> but you'll get much better results if you run it on your production code on *REAL* replay logs.
 3. `nil-kill report`: generates a report of action items by priority. You can use this to prioritize efforts manually, or - like CLEAR - feed this to an LLM to do it for you.
 4. `nil-kill espalier-evidence`: generates fast static evidence for architecture tooling.

> [!NOTE]
> [Espalier](../espalier/README.md) is a tool CLEAR uses to minimize
> architectural complexity. It consumes Nil-kill data.

[Auto-Type](../auto-type/README.md) uses Nil-kill output to
automatically type Ruby codebases. Like Nil-kill, it's designed to be
cross-language, but only Python support is preliminary. It consumes
Nil-kill evidence/actions and currently supports Ruby/Sorbet rewrites.
Its provider interface is designed so other language rewriters can be
added without changing Nil-kill's analyzer.

> [!WARNING]
> `nil-kill collect -- <command>` is a deliberately expensive, one-time
> evidence-gathering pass, not a steady-state test runner. On the 95%+ typed
> CLEAR Ruby compiler (6,413 examples), the test command takes about **61.5s**
> normally and **329.5s** under collection: **5.4x total**, or approximately
> **4m28s added**. Trace planning plus source rewriting accounts for about
> **12.6s** of that total (4.6s planning, 8.0s rewriting); the traced workload
> dominates the rest. Smaller, less collection-heavy suites can be closer to
> 3.5x. Run `nil-kill infer` and apply its changes with
> [Auto-Type](../auto-type/README.md) before collecting again, then prefer a
> representative production replay or focused tests over repeatedly collecting
> an entire suite.

Nil-Kill's trace plan omits method boundaries, T.let sites, and state fields
whose contracts are already strong. Unknown and weak slots are retained
conservatively, including weak generic payloads such as
`T::Array[T.untyped]`. See [Resolved Runtime Trace Elision](docs/agents/resolved-trace-elision.md)
for the safety boundary and CLEAR compiler measurements.

For the CLEAR compiler, planning elides 5,799 of 5,931 methods (97.8%) and 373
of 1,055 indexed state-write sites. Further annotations only reduce collection
time when they resolve the *hot remaining slots*. The current residual is
concentrated in deliberately heterogeneous `T.untyped` AST collection walkers;
adding types to cold, already-pruned APIs will not materially change the 5.4x
measurement.

> SUBPROCESSES: `nil-kill collect` instruments your target source **in place** for the duration of the collect (the pristine tree is snapshotted and restored automatically, including after a crash). There is exactly one copy of every target file, at its real path, and it is always instrumented -- so the wrapped code runs regardless of how it is loaded: `require`, `require_relative`, `Kernel#load`, autoload, an absolute-path require, a bare `ruby file.rb` entrypoint, a re-exec, or any Ruby subprocess your tests/runner spawn. Subprocess collection is therefore **in scope and guaranteed**: a method body that executes is recorded, whatever process or load path reached it. (Non-Ruby subprocesses still execute no Ruby and so produce no Ruby evidence -- there is nothing to record there.)

### How do I know how much it might help?

```
nil-kill report --with-links --output-to=<my-path>
```

You can see a [demo](report.md) of what it looks like.

To determine how much it could help you automatically, the key things you might want to consider are:

### Control Shape

Example:

```
Control shape: branchless: 1086 (50.2%); typed 1034 (95.2%); untyped 52 (4.8%)
```

The higher your branchless control shape is for returns, the more likely you are to be able to *easily* type your codebase.  If this is high, you can expect much of it to be automated.

### Hash Shapes That May Want Data/Struct

Example:

```
- {category, severity, summary, template} appears 274 time(s); first site src/ast/diagnostic_registry.rb:60
  - local hash record `category` at src/tools/doctor.rb: total pressure 87; return 0, param 20, ivar 0, collection 67
```

If you have a lot of these types of recrods, and their keys have high pressure, under Sorbet today - those will be `T.untyped`.

Nil-kill prioritizes these for manual resolution or for an Auto-type provider.

### Full details:

Here's a list of options for nil-kill:

```
Usage:
  bundle exec tools/nil-kill collect -- <command...>
  bundle exec tools/nil-kill collect --commands runtime-commands.txt
  bundle exec tools/nil-kill collect --cmd "bundle exec rspec" --cmd "./clear test transpile-tests"
  bundle exec tools/nil-kill collect --glob "lib/**/*.rb" --template "ruby {file}"
  bundle exec tools/nil-kill collect --append-runtime --commands more-runtime-commands.txt
  bundle exec tools/nil-kill collect --instrument-source -- <command...>
  bundle exec tools/nil-kill collect --no-instrument-source -- <command...>
  bundle exec tools/nil-kill infer [--no-sorbet]
  bundle exec tools/nil-kill report
  bundle exec tools/nil-kill struct-rbi [--complete] [--output sorbet/rbi/nil-kill-structs.rbi]
  bundle exec tools/nil-kill doctor

  # Source rewriting is in Auto-type:
  bundle exec auto-type apply [--dry-run]
  bundle exec auto-type review [--kind replace_nil_with_default]
  bundle exec auto-type loop [--defaults] [--try-levenshtein] -- <verify command...>
  bundle exec auto-type guarded-autocorrect [--max-iterations N]

Config:
  FACT_MINE_FACTS_FILE=facts.json   path to pre-computed fact-mine JSON, bypassing fact-mine-rust runs
  NIL_KILL_TARGETS=src[:other_dir]   target Ruby source roots
  NIL_KILL_EXCLUDE_TARGETS=src/tools  exclude Ruby source roots
  NIL_KILL_MIN_CALLS=20              runtime confidence threshold
  NIL_KILL_UNION_POLICY=untyped|any  default: untyped
  NIL_KILL_LEVENSHTEIN_DISTANCE=2    max param-name/class-name distance for speculative narrowing
  NIL_KILL_LEVENSHTEIN_LIMIT=50      max speculative actions per loop iteration; 0 = unlimited
  NIL_KILL_PRESSURE_SORT=priority|slots|hotness
  NIL_KILL_ELEMENT_SAMPLE=20          container elements sampled by runtime tracing
  NIL_KILL_TRACE_PLAN=0               disable trace-plan pruning during collect
  NIL_KILL_TRACE_METHODS=0            disable TracePoint method collection
```

## FAQ

 1. But what if I'm not on Sorbet?
     * You don't need to be.  Nil-kill copies your code, rewrites it for Sorbet, and runs Sorbet on the copied code.
 2. But what if I like my Ruby code to be "clean" and not have `sig {}` and `T.let()` polution?
     * See above.  CLEAR / Nil-kill think that `sig {}` is very useful, but that `T.let()` is polution.
     * It defaults to generating `sig {}` if you have Sorbet installed in your main repository, and keeping `T.let()` out.
     * You can include `T.let()`s if you want to, and you can exclude `sig {}` if you want to.
         * Though we're not sure why you would have Sorbet installed and not want `sig {}`.

## Links

 * [How Does Nil-kill Work](docs/how-it-works.md).
 * [Comparison to Existing Tools](docs/comparison.md)
