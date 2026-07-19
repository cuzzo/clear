# CLEAR Semantic Program Generator

## Status

Full bounded system completed and remeasured on 2026-07-19. The generator is
permanent fuzz infrastructure: all seven enabled value families meet the
1,000-case target, all reviewed capability combinations are enabled, the
bounded whole-program lane is implemented, all fixed compiler gaps have active
positive witnesses, and the 54 addressable historical matrices are registered
through the semantic migration layer with parity checks. The ordered SELECT
tense expansion below has three explicit outstanding executable-lowering gaps.

## Decision

There is a real test gap worth prototyping, but the useful system is not simply
"ANTLR in reverse."

The useful system is a bounded, typed, attributed grammar that generates many
observationally equivalent CLEAR expressions, places them into selected program
contexts, and checks that they retain the same type, payload, ownership outcome,
and runtime value. In testing terminology this combines:

- Csmith-style valid-program generation;
- property-based recursive generators and structural shrinking;
- an attribute grammar carrying type, effects, ownership, and capability facts;
- metamorphic testing, where many syntactically different programs must have the
  same observable result.

Call the prototype `csmith` for now, but its most precise description is a
"type-directed metamorphic expression generator."

The initial implementation proceeded as a narrow prototype and was expanded
only after demonstrating unique mutation kills and compiler coverage. The final
system remains bounded and type-directed rather than attempting to generate
arbitrary grammar-valid programs with undefined ownership semantics.

## Why this is a real gap

The source fuzz suite was already large and valuable at the proposal baseline:

- `tools/fuzz/` registered 81 templates and 3,459 active cells.
- The matrices cover explicit high-risk cross-products such as ownership shape
  by escape sink, capability by execution boundary, and cleanup shape by control
  flow.
- Each template supplies a complete source program and an explicit pass or
  compile-error expectation.
- Positive cases compile, run, and use leak detection. Negative cases must fail
  compilation.
- The fuzz coverage model reports no missing pair among the high-risk dimensions
  it currently knows about.

That last result does not close the proposed gap. The coverage model does not
represent:

- recursive expression derivation depth;
- combinations of expression productions inside one another;
- the number of distinct AST shapes producing the same typed value;
- equivalent values passing through different parser, annotator, MIR, and
  emitter paths;
- capability suffixes crossed with those equivalent expression shapes.

The current matrices mostly enumerate a deliberately chosen outer shape and a
small number of hand-written expressions. For example,
`access_path_expression_matrix` covers 7 access paths in 5 contexts, and
`binary_op_matrix` covers the known operator dispatch arms. Neither recursively
substitutes all valid `Int64`-producing expressions into all compatible child
positions.

The missing dimension is therefore semantic expression composition, not another
ordinary feature matrix. Bugs caused by combinations such as pipeline result ->
field access -> arithmetic -> function argument can escape even when every
individual feature and every registered high-risk pair has a test.

## What kind of system this is

### Nearest existing models

#### Csmith-style generation

[Csmith](https://users.cs.utah.edu/~regehr/papers/pldi11-preprint.pdf)
generates random C programs constrained to have defined behavior, then uses
differential execution to find compiler defects. The relevant lesson is that a
compiler generator needs semantic constraints and a strong oracle; a context-free
grammar alone mostly generates invalid or uninteresting programs.

CLEAR differs because there is currently one production compiler and ownership
and capability legality are central. The initial oracle should therefore be a
known semantic value plus the compiler's static invariants, rather than output
agreement among several CLEAR compilers.

#### Property-based generation

The recursive recipe model is similar to QuickCheck/Hypothesis generators:
productions are composable, generation has a size budget, failures retain a
seed, and shrinking replaces a complex derivation with a smaller derivation of
the same semantic class.

#### Attribute grammars

An ordinary grammar can say that `a + b` is an expression. An attributed grammar
can additionally say:

- both children must have compatible numeric types;
- the result type is `Int64`;
- the result value is known;
- the expression is pure and infallible;
- the result is copyable and has no cleanup obligation;
- only a legal capability wrapper may be attached.

Those attributes are what make generation useful for CLEAR.

#### Metamorphic compiler testing

The central property is:

```text
observe(compile(E1)) == observe(compile(E2)) == expected_value
```

where `E1` and `E2` are different derivations belonging to the same semantic
class. This is metamorphic testing: the generator supplies a relation among
multiple tests when there is no external reference compiler.

### What it is not

It is not initially:

- a generated production parser;
- random token fuzzing;
- a formatter round-trip test;
- a full evaluator for arbitrary CLEAR;
- a proof that two effectful programs are equivalent;
- a replacement for the existing fuzz matrices.

## Relationship to the Menhir grammar proposal

`docs/agents/menhir.md` proposes a static syntax manifest with production IDs,
FIRST sets, precedence, contexts, and named contextual decisions. That manifest
would be a useful future source of syntactic production data, but it does not yet
exist as executable repository infrastructure.

The semantic generator needs information beyond that proposal:

- result type and canonical value;
- required bindings and declarations;
- effects and fallibility;
- ownership and cleanup behavior;
- legal capability attachment sites;
- an observation expression;
- a same-class shrink rule.

Do not create a second complete syntax grammar under `tools/csmith/`. Give every
semantic recipe a stable syntax-production ID compatible with the future
manifest. When the manifest becomes real, validate those IDs and consume its
terminal/sequence data where practical.

The prototype can use a deliberately small hand-authored syntax fragment. This
tests whether semantic generation is valuable without paying the Menhir plan's
estimated multi-week full-manifest cost first.

## Complementarity with current tests

| Test layer | Existing strength | Semantic generator contribution | Replacement? |
| --- | --- | --- | --- |
| Parser specs | Exact AST shape and diagnostics for one source | Recursive valid combinations and production-depth coverage | No |
| Transpile tests | Stable end-to-end regression programs | Large families generated from a small semantic specification | No |
| Fuzz matrices | Reviewed high-risk feature cross-products | Expression substitution and nesting within each compatible position | No |
| MIR checker | Structural ownership invariants on every build | More valid MIR shapes presented to the checker | No |
| Mutant suites | Demonstrate whether tests detect known bad behavior | Objective validation that generated families add sensitivity | No |
| Loom/VOPR/Hammer | Runtime concurrency behavior | Nothing; this generator is not a scheduler/interleaving oracle | No |

The prototype is complementary when it does all of the following:

1. Generates a type-correct expression from a semantic class.
2. Recursively substitutes compatible expressions into child positions.
3. Places the result in multiple contexts or sinks.
4. Checks a concrete value or structural observation.
5. Retains the existing compiler, runtime, and leak oracles.

It becomes mostly redundant if it only emits grammar-valid programs and treats
"compiled successfully" as the property. The current parser, transpile corpus,
hostile frontend tests, and fuzz templates already provide strong coverage for
that weaker goal.

## Existing fuzz migration audit

The new system should not permanently sit beside every existing fuzz template
and generate the same cases twice. Some current templates are hand-written
versions of abstractions the semantic generator should own. Others contain a
valuable risk-specific matrix but repeatedly implement value construction,
type spelling, setup, and observation. Those should become clients of the new
system.

This preliminary audit classifies all 81 baseline templates and 3,459 cells:

| Disposition | Templates | Cells | Positive cells | Meaning |
| --- | ---: | ---: | ---: | --- |
| Full migration | 11 (13.6%) | 393 (11.4%) | 391 | Recipe/context model can own the test directly |
| Hybrid refactor | 43 (53.1%) | 1,844 (53.3%) | 1,691 | Preserve the explicit risk matrix; obtain values, types, setup, and observers from semantic recipes |
| Keep explicit | 27 (33.3%) | 1,222 (35.3%) | 911 | Oracle is not primarily value equivalence, or the case is a curated regression |
| Addressable total | 54 (66.7%) | 2,237 (64.7%) | 2,082 | Full migration plus hybrid refactoring |

The addressable 2,082 cases are 69.6% of all 2,993 positive fuzz cells. Only 155
of the 466 negative cells are in the addressable set. This is expected: the
semantic system fits positive, known-value generation much better than
diagnostic and rejection-policy testing.

An 80% wholesale migration is not defensible from the current template designs.
Approximately two thirds is a credible design target. Reaching 80% by forcing
diagnostic, FSM, concurrency, lifetime, and curated-regression tests through a
value-equivalence abstraction would make those tests less direct rather than
simpler.

### Full-migration candidates

These templates mostly define value/expression shapes and ordinary contexts
that are natural first-class recipes:

| Template | Why it fits |
| --- | --- |
| `access_path_expression_matrix` | Field/index/optional access expressions producing known values |
| `binary_op_matrix` | Pure typed expression recipes with direct expected values |
| `builtin_emit_matrix` | Known-value builtin expressions and pipeline terminals |
| `cast_lowering_matrix` | Typed conversion recipes with known observations |
| `collection_shape_smoke` | Canonical constructors and observers by collection shape |
| `managed_payload_capability_matrix` | Payload-preserving capability applications |
| `mir_lowering_shape_matrix` | Repeats literal/value families across ordinary expression contexts |
| `pipeline_source_shape_matrix` | Pipeline recipes from deterministic sources to known terminals |
| `rc_generic_value_matrix` | Same payload under the two refcount capability families |
| `return_value_modality` | Canonical value shapes placed in return contexts |
| `tuple_collection_composition_matrix` | Recursive typed aggregate construction and observation |

"Full migration" does not mean losing the matrix dimensions or stable test IDs.
It means expressing those dimensions as semantic recipes and contexts, then
removing the parallel hand-written renderer after parity is proven.

### Hybrid-refactor candidates

The largest simplification opportunity is in templates whose risk-specific
outer matrix is valuable but whose value machinery is duplicated.

For example, `owned_sink_destination_matrix` correctly owns the cross-product:

```text
source form x ownership-bearing shape x destination sink
```

It should continue to own that matrix. It currently also owns parallel helper
tables/functions for each shape's prelude, type, construction, return expression,
and observer. Similar shape machinery appears in `or_heap_destination_matrix`,
`return_value_modality`, `cleanup_classifier_shapes`, and other templates. A
shared `ValueSpec` should replace that repetition:

```ruby
shape = ValueRegistry.fetch(cell[:shape])
program = sink_context.render(
  setup: shape.setup,
  expression: source_context.render(shape),
  type: shape.clear_type,
  assertion: shape.observe("result")
)
```

The context/sink remains explicit and reviewable. The structured system owns
the value facts.

The preliminary hybrid set is:

- Ownership, cleanup, and destinations: `bind_capture_cleanup`,
  `branch_cleanup`, `call_ownership_contract_matrix`, `catch_allocator_matrix`,
  `catch_reassign_matrix`, `cleanup_classifier_shapes`, `cleanup_control_matrix`,
  `collection_sink_escape_matrix`, `error_cleanup`, `escape_mechanism_matrix`,
  `escape_via_return`, `heap_ownership_transfer`, `hoist_edge_matrix`,
  `list_append_modality`, `lowering_boundary_matrix`, `or_heap_destination_matrix`,
  `or_positional`, `owned_sink_destination_matrix`, `ownership_surface_smoke`,
  `struct_field_store_modality`, `takes_move_modality`, and
  `union_lowering_cleanup_matrix`.
- Collections and mutation contexts: `collection_iteration_storage_matrix`,
  `indexed_assignment_matrix`, `loop_carry_collection`, `loop_cleanup`,
  `loop_local_cleanup_alloc`, `loop_local_method_temp`,
  `mutable_collection_param`, `nested_loop_escape`, `rc_generic_collection_matrix`,
  and `stateful_container_matrix`.
- Control/expression contexts: `cond_or_fallback`,
  `destructuring_assignment_matrix`, `indirect_recursive_union`, `match_matrix`,
  `match_payload_cleanup`, `pipeline_gap_matrix`, and
  `pipeline_value_block_matrix`.
- Capability and boundary payloads: `bg_capture_transfer_matrix`,
  `capability_wrap_matrix`, `cross_fiber_consumer`, and `link_resolve_matrix`.

Some hybrid templates will shrink substantially; others will only lose their
shape helper layer. Migration should require a net reduction in template code
or a measurable increase in generated coverage. Using a framework without
simplifying the owner template is not a win.

### Templates that should stay explicit

These templates primarily test rejection policy, specialized control flow,
protocols, lifetimes, concurrency boundaries, or preserved regressions:

- `access_gate`
- `auto_inference_matrix`
- `auto_ownership_transport_matrix`
- `bg_capture_typing`
- `bg_copy_param_reentrant`
- `c_ffi_type_matrix`
- `curated_gap_corpus`
- `diagnostic_policy_matrix`
- `execution_boundary`
- `extern_boundary_matrix`
- `fsm_edge_matrix`
- `fsm_suspension_matrix`
- `generic_map_protocol_matrix`
- `generic_shared_map_capability_matrix`
- `infallible_signature`
- `inherent_method_matrix`
- `lifetimed_return`
- `mir_checker_negative_matrix`
- `node_graph_matrix`
- `polymorphic_sync_admission`
- `promise_handle_capture`
- `recursive_execution_boundary_matrix`
- `shared_node_graph_matrix`
- `stream_into_boundary`
- `tense_predicate_matrix`
- `test_framework_matrix`
- `thunk_recursion_matrix`

This is not a statement that these templates can never consume a generated
operand. It means doing so is unlikely to simplify their primary matrix enough
to justify migration. In particular, the 486-cell `curated_gap_corpus` consists
of permanent historical regression programs and should never be regenerated or
replaced by an abstract recipe.

### Migration safety rules

Do not delete an existing template merely because the new generator can produce
similar-looking source. For each migrated or hybridized template:

1. Preserve its stable matrix dimensions and pass/compile-error expectations.
2. Compare old and new cell manifests by semantic test ID, not source filename.
3. Run both versions temporarily and prove coverage and mutant-kill parity.
4. Retain explicit negative cells unless the new negative recipe asserts the
   same rejection property or diagnostic category.
5. Remove the old renderer only after the structured version is the sole owner
   of the requirement.
6. Record the migration in `tools/fuzz/coverage_model.rb` so the coverage report
   does not double-count one requirement through two generators.

Overlap is therefore a transition concern, not a long-term architectural cost.
The desired end state is one shared value/recipe system plus explicit context
matrices, not two independent fuzz suites exercising the same requirements.

## Proposed semantic model

### Separate syntax categories from semantic classes

`statement` is a syntax category, but most statements do not produce values.
The generator should model two related layers:

```text
ExprSpec       produces a typed, observable value
ContextSpec    embeds an ExprSpec in a statement/program position
```

Examples of contexts are:

- local variable initializer;
- return value;
- normal function argument;
- TAKES/GIVE argument where legal;
- struct field initializer;
- list or map element;
- branch result;
- loop-carried value;
- pipeline source or pipeline operand;
- capability-wrapped binding followed by the required access operation.

This avoids pretending that every grammar nonterminal has a value while still
testing statement-level productions.

### Expression attributes

Each expression recipe should declare at least:

```ruby
ExprRecipe.new(
  id: :int_struct_field,
  result_type: :int64,
  semantic_value: 1,
  purity: :pure,
  fallibility: :infallible,
  ownership: :copy,
  required_context: [],
  children: [:int64],
  cost: 3,
  renderer: ...,
  observer: ...,
  shrink_to: [:int_literal]
)
```

The real representation should use small typed value objects rather than open
hashes. Required fields are:

- stable recipe/production ID;
- result shape and full CLEAR type;
- canonical semantic value;
- purity/effect set;
- optional/fallible/future state;
- ownership and copy/move behavior;
- declarations, helper functions, and imports required by rendering;
- legal child semantic classes;
- source rendering function;
- observation function;
- size/cost contribution;
- same-class shrink targets;
- capability applicability and access protocol;
- exclusions with reasons.

### Initial value classes

Use a few deliberately boring values. Small expected values make generated
assertions, reduction, and failure review straightforward.

| Shape | Canonical payload | Safe observations |
| --- | --- | --- |
| `Int64` | `1_i64` | equality |
| `String` | `"one"` | equality and length |
| Struct | `Box{ v: 1_i64 }` | `value.v == 1_i64` |
| List | `[1_i64]` | length and index 0 |
| HashMap | one known key mapped to `1_i64` | length and lookup by key, never iteration order |
| Tuple | fixed tuple containing `1_i64` and `"one"` | arity and positional fields |

Struct, list, map, and tuple equivalence means equal observable payload, not
pointer identity or identical allocation behavior.

### Initial Int64 recipes

The first vertical slice should support forms equivalent to `1_i64`, such as:

```text
1_i64
identity(1_i64)
0_i64 + 1_i64
Box{ v: 1_i64 }.v
([1_i64] |> SELECT _ + 1_i64 |> SUM _) - 1_i64
```

Each child `1_i64` may itself be replaced recursively by another compatible
derivation, subject to a size and depth budget. Setup-producing recipes such as
the struct field or helper call contribute their declarations exactly once to
the containing generated program.

Avoid algebraic rewrites whose safety depends on overflow, floating-point
rounding, iteration order, time, or scheduling in the prototype.

## Capability generation

Capability coverage must be modeled as a transformation of a completed payload,
not as arbitrary token suffixing.

For a value expression `E` with payload `v`, a capability recipe produces a
binding whose payload still observes as `v`, but whose representation and legal
access protocol may differ:

```text
E
E @local
E @multiowned
E @shared
E @locked
E @writeLocked
E @versioned
E @shared:locked
E @shared:writeLocked
E @shared:versioned
primitive E @shared:atomic
aggregate E @boxed:atomic
```

This is payload equivalence, not complete semantic equivalence. Locking,
refcounting, allocation, mutability, and thread-transfer properties intentionally
change. The observer must use the access operation required by the final
capability:

- direct read where permitted;
- `WITH EXCLUSIVE` for exclusive locked access;
- `WITH SNAPSHOT` for versioned or atomic aggregate access;
- `WITH VIEW` for observable values;
- `NEXT` or materialization only when the generated value class explicitly
  includes stream/observable behavior.

The generator must not duplicate the compiler's entire capability checker as an
independent pile of conditionals. Start with a reviewed allowlist of known-valid
`value_shape x capability x observer` recipes taken from
`capability_wrap_matrix` and `TypeCapabilities`. Illegal combinations belong in
separate negative recipes with an expected diagnostic category; they must not
be included in a positive equivalence class.

Capabilities can attach at multiple structural layers. The prototype should
first cover the outer completed value. A later phase may generate nested sites,
such as a local list containing shared map values, with the three-site limit and
access rules represented explicitly.

## Generation strategy

### Bounded derivation, not full Cartesian expansion

Unrestricted enumeration grows exponentially and rapidly produces thousands of
near-duplicates. Use both deterministic coverage and seeded sampling:

1. Enumerate every recipe once at depth 0/1.
2. Enumerate every parent-child recipe pair that satisfies the attributes.
3. Sample deeper derivation trees with a deterministic seed and size budget.
4. Cover each context and capability recipe at least once per value shape.
5. Deduplicate normalized source or derivation hashes.

Track coverage over recipe IDs and edges:

```text
recipe coverage:       recipe used at least once
derivation-edge cover: parent recipe -> child recipe
context cover:         value class -> context
capability cover:      value shape -> capability -> observer
depth histogram:       maximum recursive derivation depth
```

Pairwise edge coverage is a useful finite CI gate. Deeper seeded samples can run
in a slower lane without making an unbounded Cartesian product mandatory.

### Package many cases into fewer programs

"Thousands of codes" should mean thousands of generated expression cases, not
necessarily thousands of independent compiler processes.

Emit batches containing approximately 50-200 assertions and unique helper names.
The existing fuzz runner can bundle resulting positive CLEAR programs into one
Zig test artifact. Keep batches small enough that a parser or annotation failure
can be bisected cheaply.

### Structural shrinking

Retain the derivation tree for every case. A failing expression can be reduced by:

- replacing a recipe with a declared same-class child;
- lowering recursion depth;
- removing unrelated contexts/capabilities;
- replacing setup-producing recipes with literals;
- reducing a batch to the failing assertion.

Because every replacement remains in the same semantic class, shrinking need not
guess whether the expected value changed.

## Oracles

Every positive generated case should pass all applicable oracles:

1. The parser accepts it.
2. Annotation resolves the expected full type and capability facts.
3. MIR lowering and the MIR checker accept it.
4. Zig compilation succeeds.
5. Runtime observation equals the canonical payload.
6. Leak detection remains clean.
7. Every peer derivation in the semantic class produces the same observation.

The prototype should add a small unit-level hook for oracle 2 rather than rely
only on runtime values. A compiler could accidentally coerce two expressions to
the same final value while assigning one the wrong ownership or capability facts.

Negative generation is useful but separate. A negative recipe must name the
specific rejection property or diagnostic category. "Any compilation failure"
is too weak because it lets an unrelated generator bug look like success.

## Prototype plan

### Phase 0: establish the baseline - 0.5 to 1 day

- Record current fuzz template/cell counts and generation coverage.
- Record current compiler coverage for a normal full fuzz run if local
  dependencies are available.
- Select a small set of relevant existing mutants or add 2-3 temporary seeded
  faults in expression lowering, field access, and capability wrapping.
- Define the exact prototype acceptance measurements before implementation.

The current checkout can inspect the 81-template/3,459-cell model, but a local
full run is presently blocked by missing bundled gems. That environment issue
must be fixed before measuring runtime and compiler coverage deltas.

### Phase 1: Int64 vertical slice - 2 to 3 days

Implement under a separate `tools/csmith/` directory:

```text
tools/csmith/
  value_spec.rb
  expr_recipe.rb
  derivation.rb
  registry.rb
  generator.rb
  renderer.rb
  shrinker.rb
  run.rb
  recipes/
    int64.rb
    contexts.rb
```

Scope:

- one canonical `Int64` value;
- 10-15 expression recipes;
- 5 contexts;
- deterministic depth 0-3 generation;
- seeded deeper sampling;
- derivation provenance and deduplication;
- embedded runtime assertions;
- parser/annotator type assertions for a sample of cases;
- integration with the existing positive fuzz execution path.

Target output: at least 1,000 distinct `Int64 == 1` cases without manually
writing 1,000 templates.

Use `binary_op_matrix` and `access_path_expression_matrix` as the first migration
trial. The prototype is incomplete if it only adds new cases; it must show that
these existing tests can be represented with fewer per-template rendering rules
while retaining their stable requirements.

### Phase 2: managed values and capabilities - 3 to 5 days

Add:

- String, struct, list, map, and tuple payloads;
- setup dependency merging and collision-free generated names;
- payload observers for each shape;
- outer capability attachment and the correct access context;
- COPY/GIVE/TAKES only where the semantic attributes make the operation legal;
- automatic same-class shrinking;
- generation coverage report.

Target output: at least 1,000 distinct cases for each enabled value family and
complete pair coverage for the selected `shape x capability x observer` set.

As a hybrid migration trial, refactor `return_value_modality` and one of
`owned_sink_destination_matrix` or `or_heap_destination_matrix` to consume the
new `ValueSpec` registry. Keep their context/sink cross-products unchanged. This
tests the expected consolidation benefit on the repository's largest repeated
shape-rendering pattern.

### Phase 3: prove incremental value - 1 to 2 days

Compare four suites:

```text
transpile tests alone
existing fuzz matrices
semantic generator alone
existing fuzz matrices + semantic generator
```

Measure:

- compiler line/branch coverage delta by phase;
- parser production and derivation-edge coverage;
- relevant mutant kills unique to the semantic generator;
- unexpected compiler failures found;
- generated-case throughput and total CI cost;
- median and worst reduced reproducer size;
- production and test LoC removed from migrated template renderers;
- old/new cell-manifest and mutant-kill parity for migration candidates.

Do not justify expansion using generated-case count alone.

## Acceptance gates

Continue beyond the prototype only if all correctness gates and at least one
incremental-value gate pass.

### Correctness gates

- Every generated positive case has a derivation and explicit oracle.
- A seed reproduces byte-identical generated sources.
- Shrinking preserves the value/type class.
- No expected-pass case is silently reclassified as a negative case.
- Capability tests verify both payload and resolved capability/access facts.
- The generator never uses the production compiler to calculate its expected
  runtime value.

### Incremental-value gates

At least one of:

- finds and minimizes a real previously unknown compiler bug;
- kills a relevant mutant that all existing fuzz templates survive;
- reaches meaningful parser/annotator/MIR/emitter branches not reached by the
  existing fuzz suite;
- exposes a missing composition edge that is accepted as a permanent coverage
  requirement.

If it only repeats existing coverage and mutant sensitivity, keep a few useful
recipes as ordinary fuzz templates and stop the general framework.

### Cost gates

- A deterministic CI tier finishes within a configurable budget.
- Deep/random campaigns are shardable by derivation hash.
- Failure output includes the seed, derivation tree, expected value/type, and a
  standalone reduced CLEAR program.
- Adding a recipe requires substantially less code than hand-authoring all of
  the equivalent matrix cells it replaces.

## Effort estimate

| Result | Effort | Confidence |
| --- | ---: | --- |
| Minimal Int64 proof of concept | 3-5 engineer-days | High |
| Valuable prototype with managed shapes, capabilities, shrinking, and measurements | 1-2 engineer-weeks | Medium |
| Migrate the 11 full-migration candidates after a successful prototype | 1-2 additional engineer-weeks | Medium |
| Hybridize the 43 addressable context matrices | 2-5 additional engineer-weeks | Low-Medium |
| Broad generator plus the 54-template consolidation | 4-8 engineer-weeks total | Medium-Low |
| Full grammar-derived whole-program Csmith equivalent | 2-4 engineer-months | Low |

The one-to-two-week prototype is realistic because it can reuse the existing
fuzz runner, transpilation path, leak checking, batching, and failure-promotion
workflow. The full system is much larger because scope, declarations, generic
constraints, effects, ownership movement, control flow, concurrency, and
diagnostic-quality negative generation all require semantic modeling.

## Primary risks and controls

### Generator duplicates compiler bugs

If expected values or legality are derived by calling the compiler under test,
the generator can agree with the same bug. Keep the initial evaluator closed and
obvious: literal values plus reviewed semantics-preserving recipes.

### Combinatorial explosion

Use cost budgets, edge coverage, seeded sampling, and source deduplication. Do
not require all trees up to depth N.

### Invalid-program noise

Positive recipes carry semantic preconditions and must generate valid programs
by construction. Negative testing is an explicit separate registry.

### Shadow grammar drift

Use stable production IDs and later validate them against the Menhir manifest.
Do not transcribe the complete parser into the prototype.

### False equivalence

Limit the first recipes to pure, deterministic observations. Treat ownership
and capability wrapping as payload equivalence with additional static assertions,
not as proof of identical operational behavior.

### Expensive failures

Store derivation trees and shrink structurally. Promote confirmed minimized bugs
to `transpile-tests/` exactly as the current fuzz workflow requires.

## Recommendation

Build the Phase 1 vertical slice and require Phase 3 evidence before expanding
the framework.

The gap is real: current tests enumerate reviewed feature matrices but do not
systematically enumerate recursive, type-correct, value-equivalent expression
derivations. The proposed system is likely to be complementary because it adds
a different generation axis and a stronger metamorphic oracle.

The uncertainty is economic, not conceptual. CLEAR's existing 3,459 fuzz cells
may already kill most defects that shallow semantic generation would find. A
one-to-two-week measured prototype is enough to learn whether recursive
composition finds unique bugs or coverage. A full grammar project is not
justified until that experiment succeeds.

## Historical MVP implementation and measured result (2026-07-18)

The vertical slice now exists in `tools/fuzz/semantic_equivalence.rb` and is
registered as the ordinary `semantic_equivalence_matrix` fuzz template. It is
not a second runner.

The default deterministic tier declares:

- 10 typed semantic productions;
- 2 canonical goals (`Int64 == 1` and `Bool == TRUE`);
- 11 distinct depth-1 derivations;
- 13 local, return, call, aggregate, and pipeline consumers;
- 91 active production/consumer obligations;
- 2 visible blocked nested-pipeline obligations;
- a closed audit of all 26 parser pipeline actions: 8 generated and 18
  explicitly classified as requiring other attributes or manual coverage.

The production set includes literals, grouping, identity calls, addition by
zero, struct-field reads, typed NIL plus `OR_ELSE`, singleton `SUM`, and an
integer comparison. The consumer set includes initializer, return, function
argument, struct field, list element, SELECT, SUM, WHERE, FIND, ANY, ALL, COUNT,
and TAKE_WHILE slots. Pipeline consumers declare the additional requirement
that the slot consume its `_` binding.

Measured commands and results:

```text
bundle exec rspec compiler/spec/semantic_equivalence_generator_spec.rb \
  compiler/spec/fuzz_coverage_model_spec.rb
18 examples, 0 failures

bundle exec ruby tools/fuzz/run.rb --matrix \
  --templates semantic_equivalence_matrix ...
91 run, 91 ok, 0 fail, 0 leak, 0 mir-error
pass bundle: 91 cells in 2.11s
```

Generation scales before compiler execution becomes expensive:

| Depth | Derivations | Active cases | Blocked obligations |
| ---: | ---: | ---: | ---: |
| 1 | 11 | 91 | 2 |
| 2 | 112 | 814 | 50 |
| 3 | 673 | 5,143 | 260 |

Depth 3 generation itself takes less than a second on this machine. The
limiting problem is semantic validity and current compiler composition bugs,
not producing thousands of trees.

### Compiler gaps exposed by the MVP

End-to-end validation exposed five distinct composition boundaries:

1. Bare `NIL OR_ELSE 1_i64` is parsed but NIL is not contextually typed through
   OR_ELSE, even when the destination supplies Int64.
2. A field read directly from a struct literal is accepted as CLEAR, but the
   emitted Zig drops required parentheses around the struct literal.
3. A pipeline expression which does not use `_` emits an unused Zig loop
   capture. The active consumer contract uses a semantics-preserving `_` use.
4. MIN/MAX with a derived Int64 projection emits a Float64 accumulator and then
   compares it to Int64. Those routes remain classified but are not active MVP
   consumers.
5. Nested pipeline expressions can infer a Float64 SUM accumulator or bind the
   wrong pipeline item. The exact incompatible pairs remain counted as blocked
   obligations rather than being converted into permanent negative tests.

The depth-2 run generated 814 active cases and rejected 47 before execution
when one production's optional-type precondition was too broad. Tightening the
declaration removed those invalid trees; the remaining depth-2 failures were
instances of the already recorded nested-pipeline compiler gap. This is direct
evidence that attributed production preconditions are necessary.

### Assessment after the MVP

#### 1. Likelihood of reaching the intended system

For pure scalar expressions and ordinary pipeline predicate/projection slots,
the likelihood is high (about 85 percent). The prototype already demonstrates
recursive closure, deterministic IDs, automatic consumer multiplication,
parser-route drift detection, and thousands of bounded derivations.

For Strings, structs, lists, hashes, tuples, ownership capabilities, and all
legal attachment/access combinations, confidence is medium (about 65 percent).
Nothing in the architecture blocks them, but they require richer attributes:
ownership, mutability, fallibility, optionality, setup dependencies, observer,
binding use, effect, cardinality, and capability access mode. The depth-2
invalid-tree result shows that missing one precondition produces noise quickly.

It can provide strong completeness only relative to a closed registry. The
pipeline route audit proves that every parser pipeline action is generated or
explicitly classified. Equivalent audits are still needed for value shapes,
capabilities, sinks, and selected expression production families. Generating
the parser from this grammar is unnecessary; closed manifests and drift tests
are sufficient.

#### 2. Likelihood of actual value

The likelihood of useful composition coverage is high. A very small scalar MVP
immediately found five compiler/generator boundaries that the existing fuzz
matrices did not prevent. That is stronger evidence than generated-case count
or a small line-coverage increase.

The likelihood of a significant unique mutant-kill increase is medium-high
(about 70 percent) after managed values and capabilities are modeled, but the
scalar MVP does not yet provide one. A direct experiment ran its 91 cases under
all 40 currently registered fuzz mutants. Thirty-five patch fixtures applied
cleanly and all 35 survived this matrix; five fixtures were unviable against
the branch. This is expected because that registry primarily mutates ownership,
cleanup, lifetime, and concurrency rules, while this MVP intentionally models
scalar values. It also confirms that the MVP is complementary rather than a
smaller duplicate of those safety matrices.

The five compiler gaps exposed while building the MVP are five plausible new
targeted-mutant families, but they cannot be counted as killed mutants while
the unmutated compiler still contains the defects. The correct sequence is:
fix a defect, activate its currently blocked or adapted raw witness, add a
reverse-fix mutant, and demonstrate that existing fuzz survives while semantic
generation kills it. If all five prove independent, the targeted registry
would grow from 40 to 45 with five additive kills. Until that experiment, the
MVP checkpoint's measured additive count was zero and its unique-mutant gate
remained open. The completion experiment below supersedes that result.

The likelihood of reducing fuzz maintenance is high for shared value setup,
observers, and producer/sink cross-products, and low for replacing every fuzz
template. The prior audit found 54 of 81 templates and 2,237 of 3,459 cells
addressable by full or hybrid migration. The likely win is one declarative
`ValueSpec`/capability registry reused by those matrices, while concurrency,
diagnostic, MIR-negative, and protocol-specific templates remain specialized.
The MVP itself is about 400 lines, so it is not yet a LoC reduction; the
reduction must be demonstrated by migrating two existing matrices before broad
adoption.

#### 3. Remaining effort

The next decision-quality milestone is about 1-2 engineer-weeks:

- 2-4 days for explicit fragment attributes, structural shrinking, known-gap
  promotion, and bounded edge selection;
- 3-5 days for String/struct/list/map/tuple shapes, observers, and setup-name
  hygiene;
- 2-3 days for capability legality/access attributes, two real template
  migrations, and a four-way mutation/coverage comparison.

If that milestone kills unique mutants and makes the migrated templates
materially smaller, a useful hybrid completion is about 4-8 engineer-weeks in
total. Migrating every addressable historical matrix is the long part. A full
whole-program Csmith analogue with declarations, control flow, generics,
effects, concurrency, and negative diagnostic generation remains a multi-month
project and is not recommended now.

### Historical recommendation after the MVP

Continue to the managed-value/capability trial, but keep the investment gated.
The MVP has already delivered real composition signal and demonstrates the
automatic-coverage property the design needed. The next gate must be unique
mutant kills plus measurable renderer deletion in two migrated templates. If
that gate fails, retain this as a compact scalar/pipeline composition matrix
and stop expanding the framework.

## Historical prototype result (superseded on 2026-07-18)

This section records the narrow prototype measurement that authorized the full
build. Its counts and scope exclusions are historical, not the current system.
The managed-value and Phase 3 experiment cleared the
incremental-value gate decisively: the semantic integration kills 68 parser
mutants that survive the baseline specs. It also contributes three compiler
lines and four compiler branches not reached by the existing 3,459-cell fuzz
suite. The framework should therefore remain part of the test architecture.

The implementation lives under `tools/fuzz/`, rather than the originally
sketched parallel `tools/csmith/` tree, so generated cases retain the existing
compiler, MIR, Zig, runtime, and leak gates:

- `semantic_equivalence.rb` owns typed attributes, values, productions,
  derivations, consumers, deterministic campaigns, sharding, and shrinking;
- `semantic_equivalence_matrix.rb` and `semantic_capability_matrix.rb` register
  ordinary fuzz templates;
- `semantic.rb` reports campaigns and reproduces or reduces a case from its
  stable ID;
- `semantic_equivalence_integration_spec.rb` supplies the end-to-end runtime,
  static full-type, and capability-fact oracles;
- `semantic_mutant.rb` runs the paired baseline/semantic mutation experiment,
  rejects timeout or test-selection failures, and writes machine-readable
  `semantic-mutant-delta/v1` facts.

### Final generated model

The deterministic depth-1 lane now contains:

| Dimension | Final result |
| --- | ---: |
| Typed productions | 15/15 used |
| Value families | 7 |
| Derivations | 21 |
| Ordinary consumers | 13 |
| Equivalence cases | 139 |
| Capability/access cases | 9 |
| Total active semantic cases | 148 |
| Visible blocked obligations | 4 |
| Unique derivation edges | 15 |
| Parser pipeline actions classified | 26/26 |

The value registry covers `Int64`, `Bool`, `String`, a struct, list, map, and
tuple with canonical payloads declared independently of the compiler. Every
case retains its production tree, full expected type, expected payload, setup
dependencies, cost, depth, stable fingerprint, and semantic seed.

The reviewed capability allowlist covers direct, exclusive, and snapshot
access across `@multiowned`, `@shared`, `@locked`, `@writeLocked`, `@versioned`,
the three shared synchronization forms, and primitive `@shared:atomic`. Static
integration assertions verify the resolved ownership and synchronization facts,
not only the runtime payload. Rc/Arc observation for String, list, map, and tuple
remains excluded with a named reason because those wrapper access protocols do
not currently lower correctly; unsupported pairs are not presented as positive
coverage.

Depth remains configurable rather than making the default lane exhaustive:

| Depth | Derivations | Active cases | Blocked obligations | Unique edges |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 21 | 139 | 4 | 15 |
| 2 | 127 | 780 | 159 | 60 |
| 3 | 693 | 4,270 | 1,233 | 60 |

The larger blocked counts are intentional visibility into two compiler gaps:
nested pipeline expressions and maps nested in managed lists. A campaign limit
first preserves production, consumer, and derivation-edge representatives and
now fails explicitly if the requested limit is too small to do so. Remaining
cases are selected by a stable seed, and shards partition stable case hashes.

The Phase 2 proposal used 1,000 cases per managed family as an expansion target.
The experiment does not inflate managed-family counts with repeated parentheses
to meet that number. Fourteen shallow derivations cover all seven canonical
families, while deeper sampling is concentrated on real recursive production
edges. This follows the document's stronger rule that generated-case count is
not evidence of value; mutation and compiler coverage are the acceptance
measurements.

### Reproduction and reduction

For a failure, the generated source header and `semantic.rb --json` output carry
the semantic seed, stable case ID, expected full type and payload, derivation
tree, cost, depth, and standalone CLEAR source. `--shrink` replaces the failing
fragment only with a cheaper derivation in the same goal and attribute class.
Unit tests prove deterministic selection, byte-identical case sources,
disjoint/exhaustive sharding, same-class reduction, and complete failure
context. Median reduction size is not applicable to this final pass because all
enabled positive cases succeed; the six discovered compiler gaps remain explicit
blocked obligations or exclusions instead of being mislabeled negative tests.

### Four-suite compiler coverage comparison

Ruby line and branch coverage was measured with isolated SimpleCov workers over
the compiler sources:

| Suite | Covered lines | Line coverage | Covered branches |
| --- | ---: | ---: | ---: |
| Transpile tests alone (493 files) | 47,542 / 54,889 | 86.615% | 14,176 / 22,431 |
| Existing fuzz matrices (3,459 cells) | 48,836 / 54,889 | 88.972% | 15,102 / 22,431 |
| Semantic generator alone (148 cells) | 30,899 / 54,519 | 56.676% | 5,373 / 22,323 |
| Existing fuzz plus semantic generator | 48,839 / 54,889 | 88.978% | 15,106 / 22,431 |

The additive lines are tuple generic substitution in
`generic_analysis.rb` and root-receiver lowering in `mir_lowering.rb`. The four
additive branches occur in tuple generic substitution, binding classification,
control-flow lowering, and root-receiver lowering. The absolute delta is small,
which is expected beside a mature 3,459-cell suite, but it is non-zero and is
paired with much stronger mutation evidence.

### Differential mutation result

The permanent command is:

```text
bundle exec ruby gems/lineage/tools/mutant-converters/semantic_mutant.rb \
  --out /tmp/clear-semantic-mutants --jobs 32 --timeout 60 --min-new-kills 1
```

For `ClearParser#parse_binary_op`, both sides selected the same 369 mutants and
completed with zero timeouts:

| Run | Selected specs | Killed | Alive | Kill rate |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 51 | 86 | 283 | 23.30% |
| Baseline plus semantic integration | 52 | 154 | 215 | 41.73% |
| Additive semantic result | — | **68** | -68 | +18.43 points |

The facts artifact records all 68 stable mutant identities. The runner also
guards the validity of this comparison: unequal mutation populations, any
timeout, or failure to select the semantic spec makes the experiment fail.
This closes the incremental mutation gate that the scalar MVP originally left
open.

### Migration and execution evidence

`return_value_modality` now derives String, list, and map setup/type/literal
facts from the shared `ValueRegistry`; its per-shape renderer is seven lines
smaller than the prior version. `owned_sink_destination_matrix` consumes the
same canonical String value while retaining its source-by-sink risk matrix.
Together the two templates have a net three-line renderer reduction, with their
stable matrix dimensions and expectations preserved.

The migration parity run executed 304 cells: 273 positives and 31 expected
compile failures, all correct. The complete registry now reports 83 templates,
3,607 cells, 3,141 positives, 466 negatives, and no modeled fuzz coverage gaps.

Final execution measurements on this machine:

| Gate | Result |
| --- | --- |
| Default semantic + capability lane | 148/148 pass in 3.39s |
| Seed 42, depth 2, bounded to 200 | 200/200 pass in 4.88s |
| Semantic coverage compile lane | 148/148 pass in 1.97s |
| Two migrated matrices | 304/304 correct |
| Focused framework/compiler specs | 50/50 pass |
| Fuzz coverage registry | 83 templates, no gaps |

No enabled run produced a runtime failure, leak, MIR checker error, timeout, or
unexpected pass.

### Acceptance decision

All correctness gates pass. The generator owns explicit non-compiler oracles,
stable provenance, deterministic seeds, same-class shrinking, static type and
capability checks, and explicit blocked obligations. All cost gates pass through
the bounded deterministic tier, stable sharding, standalone failure output, and
the demonstrated registry reuse in two existing matrices.

Both measured incremental gates passed: 68 uniquely killed mutants and four
compiler branches not reached by the existing fuzz suite. The prototype was
accepted for its stated narrow scope. The work described as future expansion
here was subsequently performed; the authoritative completion result follows.

## Historical completion claim (2026-07-19; superseded)

This section records an earlier completion claim and its measurements. It is
not the current acceptance status: later executable admission work found that
advanced capability transport, runtime-forced scheduling, allocation faults,
and generic constraint cross-products were not fully covered. The current
status and executable release requirements are in “Advanced-oracle
implementation” below; do not use the counts in this historical section to
claim zero gaps.

### Final executable model

| Dimension | Final result |
| --- | ---: |
| Value families | 7 |
| Typed productions | 18/18 active |
| Ordinary consumers | 18 |
| Depth-1 derivations | 45 |
| Depth-1 equivalence cases | 390 |
| Active raw defect witnesses | 21 |
| Reviewed capability/access cases | 17 |
| Whole-program scopes | 5 |
| Whole-program carriers | 5 |
| Whole-program topologies | 25 |
| Cases per enabled family | 1,000 |
| Full whole-program cases | 7,000 |
| Visible blocked obligations | 0 |
| Outstanding compiler gaps | 0 |

The families are `Int64`, `Bool`, `String`, struct, list, map, and
`Tuple<Int64,String>`. COPY is generated for every managed family, direct
rvalues and GIVE are passed to TAKES, and the whole-program selector balances
every family over every topology. Consequently the final 7,000 cases include
exactly 1,000 managed COPY cases and 1,000 GIVE-to-TAKES cases rather than
depending on a random sample to reach those operations.

The deterministic CI tier remains bounded: `semantic_equivalence_matrix` runs
390 recursive expression/context cases, `semantic_gap_matrix` runs all 21 raw
witnesses, `semantic_capability_matrix` runs 17 reviewed combinations, and
`semantic_full_matrix` runs a balanced 250-case whole-program tier. Setting
`SEMANTIC_FULL_LIMIT=0` executes the complete 7,000-case campaign. Stable hashes
make the full campaign reproducible and shardable without overlap.

### Defect ledger

The completed campaign discovered 21 compiler defects and fixed all 21:

| Phase | Fixed | Remaining |
| --- | ---: | ---: |
| Original scalar/managed expansion | 6 | 0 |
| Capability expansion | 4 | 0 |
| Ownership and whole-program expansion | 7 | 0 |
| Migration-completion execution | 3 | 0 |
| Whole-program allocator execution | 1 | 0 |
| Total | 21 | 0 |

The original set is contextual typing of bare `NIL OR_ELSE`, direct struct
literal field emission, unused constant pipeline captures, typed MIN/MAX
accumulators, nested pipeline scope/typing, and allocator compatibility for a
map nested in a managed list. Capability expansion fixed String, list, map, and
tuple refcount wrapping/observation. The final expansion fixed direct list
literals passed to TAKES, tuple fallback transfer, COPY of a temporary managed
tuple, list fallback into a loop-local field, nested owned-sink allocator
transport, nested-list contextual shape, and COPY lifetime for an owned
optional fallback.

Executing all 54 migrated matrices, rather than accepting source-digest parity
alone, exposed three final defects: contextual type information for `List[]`
was lost inside a declared tuple field; heap-owned values (including COPY
strings and `OR_ELSE` results) embedded in a frame-owned collection bypassed
per-child allocator transport; and an owned optional branch plus its `OR_ELSE`
fallback could be merged with incompatible cleanup ownership. The full
whole-program campaign then exposed tuple temporary cleanup inheriting a child
frame allocator while being cleaned with the heap allocator. All four are fixed
and retained as raw witnesses.

`SemanticGaps.validate!` is the executable inventory. Every entry carries its
unreduced positive CLEAR witness, and `semantic_gap_matrix` executes all 21
through transpilation, MIR verification, Zig execution, and leak checking. A
fixed bug cannot disappear into prose or be relabeled as an expected compiler
failure. The final witness run is 21/21 with no leak or MIR failure.

### Whole-program and reduction evidence

`SemanticFull::Suite` embeds derivations in five scopes (`direct`, `if_true`,
one-iteration `while`, one-iteration `foreach`, and a helper function) crossed
with five carriers (local, mutable/COPY, struct field, list element, and
GIVE-to-TAKES). This supplies bounded declarations, aggregates, control flow,
calls, ownership movement, observation, and cleanup without generating programs
whose behavior the independent evaluator cannot define.

The final balanced campaign ran as 14 deterministic hash shards: 7,000/7,000
programs passed, with zero compile failures, leaks, MIR failures, or unexpected
passes. The 2026-07-19 revalidation repeated all 14 shards after the final
allocator fixes with the same 7,000/7,000 clean result.

At depth 3 the expression generator contains 3,394 fragments. Same-class
shrinking reduces 3,387 of them; the median reduced expression is 5 bytes, the
largest minimal expression is 33 bytes, and the maximum derivation cost falls
from 12 to 1. The reducer preserves goal type, expected value, ownership facts,
and the consumer harness, so a reduced result remains a standalone positive
program with the same oracle.

### Migration completion

The migration inventory remains exactly the audited 81-template partition:

| Disposition | Templates | Historical cells | Execution model |
| --- | ---: | ---: | --- |
| Full migration | 11 | 393 | `ContextSpec` is the sole active renderer; sources and expectations are materialized by stable semantic cell identity |
| Hybrid refactor | 43 | 1,844 | Risk-specific outer matrices remain active and share the seven-family `ValueRegistry` |
| Keep explicit | 27 | 1,222 | Specialized diagnostics, protocols, concurrency, lifetimes, and curated regressions remain direct |

`SemanticMigration.validate!` checks all 54 addressable templates, all 2,237
cells, stable semantic IDs, pass/compile-error expectations, and rendered-source
digests. All 11 full migrations have their legacy renderer removed from active
execution; all 43 hybrids deliberately retain their reviewable outer matrix.
The coverage model treats this as one requirement owner rather than counting
the semantic adapter and historical template as independent coverage.

### Final mutation experiment

The permanent differential command is:

```text
bundle exec ruby gems/lineage/tools/mutant-converters/semantic_mutant.rb \
  --out /tmp/clear-semantic-mutants-final-148 \
  --jobs 32 --timeout 60 --min-new-kills 1
```

Both sides selected the same 369 `ClearParser#parse_binary_op` mutants. The
baseline selected 51 specs and killed 86 mutants; adding the semantic integration
selected 52 specs and killed 136. Therefore the finished semantic framework
uniquely kills 50 stable mutant identities, raising the kill rate from 23.30%
to 36.85%, with zero timeouts. The facts artifact records every identity.

Mutation uses a deterministic 148-case representative set that preserves all
production, consumer, and derivation-edge witnesses. The ordinary fuzz lanes
still execute all 390 depth-1 cases. An attempted 390-case-per-mutant experiment
produced seven timeouts and was correctly rejected by the differential runner;
timeout results are never counted as kills.

### Acceptance decision

All Phase 1-3 correctness, incremental-value, and cost gates pass. The system
meets the 1,000-case target independently for every enabled family; activates
COPY/GIVE/TAKES, reviewed capability combinations, structural reduction, and
bounded whole-program generation; owns a zero-outstanding executable gap
ledger; preserves migration parity; and demonstrates unique mutation kills.

There are no known gaps within this bounded semantic system. Extending it to
arbitrary grammar-derived programs with unconstrained concurrency, generics,
effects, or negative diagnostics would be a different project and must add an
independent legality/oracle model before those constructs can be enabled.

## Next expansion plan: oracle-bearing advanced-language generation

This is the quality plan for the language surfaces intentionally left outside
the completed bounded system. The goal is not to turn every existing explicit
matrix into random source generation. A surface may enter semantic generation
only after it has both (1) a legality model that refuses invalid trees before
emission and (2) an independent, deterministic oracle for its observable
behavior. Until then its existing explicit matrix remains the requirement
owner.

### Scope, oracle, and completion gates

| Workstream | What to generate | Independent oracle | Quality gate before admission |
| --- | --- | --- | --- |
| Capability cross-products | Every legality-approved managed value family × capability/access mode × ownership operation × storage carrier | Expected value plus ownership/refcount/liveness outcome; MIR allocator and transfer facts | 100% of approved pairwise combinations; every high-risk three-way combination (capability × COPY/GIVE/TAKES × nested carrier); at least 100 cases per enabled family; zero leaks/MIR failures |
| Deeper/larger whole programs | Depth 4–6 expressions; 2–6 declarations; nested aggregate, branch, loop, call, return, and ownership paths | Existing typed value evaluator extended to an ordered observation trace: return value, assertions, owned-result disposition, and cleanup outcome | Exhaustive derivation coverage through depth 4; 10 deterministic seed campaigns of 1,000 cases at depths 5–6; every failure shrinks to a standalone source witness; bounded CI tier finishes within 10 minutes |
| Concurrency | Two fibers initially, then up to four; shared/local capability values; spawn, join, channel/stream handoff, cancellation, and bounded producer/consumer shapes | Deterministic scheduler plus normalized event trace. Exhaustively enumerate schedules for two actors with at most six yield points; use partial-order reduction above that bound | Every generated program has a declared allowed trace set; all reduced schedules are explored; no race is accepted merely because one schedule passed; leak, deadlock, and timeout are distinct failures |
| Effects/fallibility | Whitelisted deterministic effects, state updates, fallible calls, `OR_ELSE`, cleanup, and rollback/commit paths | Small reference state machine returning `(value/error, state, event trace)`; generated CLEAR must match all three | Full transition and error-edge coverage for each effect model; fault-injection run for every allocation/effect boundary; no effectful form is admitted without a model transition table |
| Generics | Constrained generic functions, associated types, collection/capability substitutions, monomorphization, and generic returns | Independent substitution/constraint checker plus the instantiated concrete-program oracle | Cover every declared constraint and associated-type projection; pairwise type-argument coverage plus all ownership-bearing substitutions; accept/reject parity for generated positive and negative cases |
| Diagnostics | Intentionally invalid programs around the above surfaces | Expected diagnostic code, primary span class, and recovery/termination property—not message text | Each invalid production has a deterministic code/span oracle; no negative case is counted as passing solely because compilation failed |

“Legality-approved” is an executable registry, not prose: each tuple records
its required capabilities, permitted storage/access modes, valid operations,
oracle kind, and the explicit matrix that owns it before semantic admission.
The generator must report both the enabled and rejected tuple counts so omitted
combinations cannot become invisible.

### Delivery order

1. Build the shared machinery first: legality registry, observation-trace
   format, deterministic seed/shard manifest, reducer support, and a result
   classifier that separates compiler rejection, wrong trace, leak, deadlock,
   timeout, and MIR failure.
2. Expand capability cross-products and depth 4 whole programs. These reuse
   the existing evaluator and should establish the generator/oracle contract
   before adding nondeterminism.
3. Add deterministic effects/fallibility state machines, including allocation
   fault injection and rollback/error paths.
4. Add generics by generating a concrete instantiation alongside each generic
   program; compare legality and runtime observation after substitution.
5. Add concurrency last, with exhaustive bounded schedule exploration before
   any randomized schedule campaign. Increase actor/yield bounds only after
   partial-order reduction is validated against exhaustive smaller bounds.
6. Add generated negative diagnostics only after positive semantics are stable;
   diagnostics use their own code/span oracle and never share the positive
   runtime pass criterion.

### Campaign and release criteria

Each workstream has a small PR gate, a nightly exhaustive/bounded gate, and a
weekly seed-expansion gate. A workstream is complete only when all of the
following are true:

- its legality registry has no unexplained excluded combination;
- every generated case has stable seed, provenance, and same-class shrinking;
- the full campaign is repeatable on two consecutive clean runs with zero
  leaks, deadlocks, timeouts, MIR failures, and unexpected passes;
- every discovered defect becomes an enabled raw witness in `SemanticGaps`;
- mutation testing shows either new stable kills or a documented coverage
  plateau, and no mutant result is accepted when baseline/spec selection or
  timeout behavior differs; and
- the existing explicit matrix remains in place until generated coverage has
  equal or stronger requirement-level coverage and a reviewed migration plan.

### Genuine remaining gap

The remaining gap is therefore specific: there is not yet an independent,
bounded legality-and-semantic oracle for advanced capability cross-products,
larger programs, concurrency, effects, generics, or generated diagnostics.
Those surfaces are tested elsewhere today, but not yet by the same generated
equivalence framework. This plan makes their admission measurable rather than
claiming coverage from random syntax alone.

## Advanced-oracle implementation (2026-07-19)

The implementation is in progress in `tools/fuzz/semantic_advanced.rb` and
`semantic_advanced_matrix`.  `SemanticAdvanced::Registry` is the executable
admission record: every entry has a stable identity, owning renderer,
legality expectation, provenance, and normalized trace (`return` with ordered
events or `reject`).  It currently contains 421 entries:

| Workstream | Entries | Oracle/admission rule |
| --- | ---: | --- |
| Capability | 43 | capability/access trace plus ownership-cleanup path |
| Depth 4–6 | 18 | contextually typed depth provenance, asserted value, cleanup |
| Concurrency | 245 | existing boundary/transfer cases plus all 20 two-actor, six-yield schedule witnesses |
| Effects/fallibility | 68 | signature legality plus an independent commit/rollback state machine |
| Generics | 35 | protocol/capability cases plus concrete generic identity monomorphizations |
| Diagnostics | 12 | structured registered code and primary token span, not merely compilation failure |

The normal concurrency PR lane is a deterministic 24-case round-robin subset
that retains both execution-boundary and transfer families because asynchronous
tests are isolated for leak/deadlock attribution.  Set
`SEMANTIC_ADVANCED_CONCURRENCY_LIMIT=0` for the complete 225-case nightly
admission campaign.  The full registry stays visible in the report regardless
of that execution limit; no combination is silently removed.

`FuzzGenerator` now carries `diagnostic_code_required`, and `tools/fuzz/run.rb`
fails a negative cell when its declared code is absent. `SourceError` preserves
the diagnostic code and prints it in CLI output; `SemanticAdvanced` then probes
the compiler frontend directly to check the exact code and a non-EOF primary
token span. This replaced a false “any rejection is enough” criterion and
exposed a stale expected code for the generic Map wrong-key witness
(`TYPE_MISMATCH_ASSIGN` -> `GENERIC_MAP_KEY_MISMATCH`), which is fixed and
retained in the advanced gap ledger.

Focused execution is clean for the recorded lanes: capability 43/43,
signature effects 60/60, generated effect state machines 8/8, generic protocol
cases 28/28, generated monomorphizations 7/7, structured diagnostics 12/12,
and generated-schedule concurrency smoke 2/2. The full retained whole-program
campaign is clean: depth 4 seed 1 and depths 5/6 seeds 1–10, 147,000 programs
in total.
The normal concurrency PR lane
is a deterministic 24-case round-robin subset; set
`SEMANTIC_ADVANCED_CONCURRENCY_LIMIT=0` for the full 245-case nightly lane.

The planned executable advanced quality gates are complete. The full
100-per-approved-pair capability runtime campaign is clean: 1,700/1,700
generated cases, with zero runtime failures,
leaks, MIR errors, or unexpected passes. Allocation-fault execution is now an
active deterministic oracle: generated list-growth recovery cases run with
`CLEAR_OOM_AFTER=20` and assert both `OR_ELSE PASS` rollback and
`OR_ELSE <value>` fallback. The advanced ledger records all twelve discovered
witnesses as fixed, with no expected outstanding language gaps. `SELECT`
preserves tenseness through parsing, annotation, executable lowering,
ownership verification, and runtime cleanup for open, bounded, and infinite
streams.
`generic_identity_owned_return` is now fixed and active
for String, list, map, and tuple substitutions: generic returns materialize
owned payloads with the runtime allocator, and generic map/list calls preserve
their value ABI. The managed `COPY`/`GIVE` plain-`TAKES` witness is also fixed:
lowering materializes an owned payload for the callee and retains normal
source-handle cleanup. `allocation_fault_or_else_value` is fixed: hidden
allocation FAULT now selects error `catch` lowering rather than optional
`orelse`. The historical `SemanticGaps` ledger is not evidence of
advanced-system completion and must not be used to claim zero outstanding
compiler gaps.

### Ordered SELECT tense assignment matrix

`select_tense_assignment_matrix` is an exhaustive independent-oracle matrix for
the SELECT rules introduced by the Inline Pivot stream syntax. It owns 56
cells: 48 positive assignments (`4 source shapes x 12 legal ordered modifier
sequences`), one executable direct `(range) |> future-returning-function` cell,
and seven negative syntax cells. The source shapes are `[]T`,
`[~]T`, `[~2]T`, and `[~INF]T`. The legal ordered modifiers are plain, `!`, `?`,
`!?`, `~`, `~!`, `~?`, `~!?`, `!~`, `!~!`, `!~?`, and `!~!?`; the negative
set includes `?!`, `?~`, `!?~`, `~?!`, and `~~`.

The oracle is implemented independently in
`tools/fuzz/select_tense_semantics.rb`. It splits a selector wrapper order at
the tense boundary, preserves the source cardinality for an existing stream,
uses finite `[~]` for list-to-stream projection, places the prefix outside the
stream, and places the suffix on each yielded item. Thus `!~?T` selected over a
list produces `![~]?T`, while `[~]?T` is legal and `?[~]T` is rejected.

The expansion found eight distinct compiler gaps. All eight are fixed and retained:

- exact SELECT modifier ordering and invalid-order rejection;
- parsing `!~T`, `!~!T`, and `!~?T` without normalizing wrapper order;
- `[~]`, `[~N]`, and `[~INF]` result-cardinality inference;
- mandatory `SELECT:~` for a list selector returning `~T`; and
- rejection of obsolete `~T[?]` and invalid outer-optional `?[~]T` while
  accepting `[~]?T`;
- executable cardinality-preserving stream producers rather than `ArrayList`
  materialization, including generator-backed `[~N]T`;
- ownership-safe outer-fallible `SELECT:!~*` cleanup; and
- nested `~!T`/`~!?T` Promise payload ABI preservation.

The complete executable SELECT run is green and fail-complete: all 56 cells
pass their independent oracle (48 positive assignments, the direct
range-to-future pipe, and seven syntax rejections), with zero runtime failures,
leaks, MIR errors, or unexpected passes.

### Deep whole-program campaign manifest

`SemanticFull::AdvancedCampaign` is now the executable depth manifest. It has
one depth-4 configuration and twenty deep configurations: seeds 1 through 10
at each of depths 5 and 6. Every deep configuration requests 1,000 cases for
each of seven value families (7,000 programs total). The generator now uses a
deterministic bounded Cartesian walk rather than materializing the exponential
product before applying its per-goal cap; depth-4/5/6 typed derivations build
in bounded time while retaining seed variation.

The following retained runtime checks are clean:

```text
depth 4, seed 1; depths 5 and 6, seeds 1–10: 147,000 programs
each configuration: 7 families x 1,000; COPY 1,000; GIVE/TAKES 1,000
all: 0 runtime failures, leaks, MIR errors, or unexpected passes
```

Run a configuration through the ordinary full matrix with:

```text
SEMANTIC_FULL_DEPTH=5 SEMANTIC_FULL_SEED=1 \
SEMANTIC_FULL_FAMILY_TARGET=1000 SEMANTIC_FULL_LIMIT=0 \
bundle exec ruby tools/fuzz/run.rb --matrix --templates semantic_full_matrix ...
```

The full retained depth campaign is complete. Root-cache exhaustion observed
during an earlier parallel attempt was environmental; serial isolated-cache
reruns supplied the retained semantic evidence above.

### Capability expansion campaign

`SemanticCapabilityExpansion::Suite` crosses every legality-approved
value/capability pair with independently derived typed payload expressions.
At depth 4 and target 100 it builds 1,700 distinct cases: 100 for each of the
17 approved pairs (Int64 100; String/List/Map/Tuple 200 each; Struct 800).
This meets the count requirement more strictly than 100 per enabled family and
retains the capability's declared direct/exclusive/snapshot access oracle.

The full campaign is opt-in so ordinary template loading does not build 1,700
sources:

```text
SEMANTIC_CAPABILITY_EXPANSION=1 \
SEMANTIC_CAPABILITY_EXPANSION_DEPTH=4 \
SEMANTIC_CAPABILITY_EXPANSION_TARGET=100 \
SEMANTIC_CAPABILITY_EXPANSION_SEED=1 \
bundle exec ruby tools/fuzz/run.rb --matrix \
  --templates semantic_capability_expansion_matrix ...
```

`SEMANTIC_CAPABILITY_EXPANSION_SHARD=I/N` shards by stable case fingerprint.
An 85-case representative run (five independently derived payloads per pair)
is clean. `TransportSuite` now generates the high-risk direct and nested-field
COPY/GIVE/TAKES carriers for all ten direct managed value/capability pairs
(20 cases). Its first full run exposed and fixed two lowering defects: a
frame-owned aggregate containing a retained managed child was assigned an
incoherent allocator, and a managed map field was structurally deep-copied
instead of retained. It then exposed and fixed
`managed_copy_give_takes_plain_parameter`, including the dynamic-list wrapper
shape needed in a managed struct field. The complete 20-case lane is now green
(20/20; no leak, MIR error, or unexpected pass). Locked/snapshot carriers and
larger nested-storage topologies remain future expansion work.

### Bounded schedule execution

The schedule model enumerates all 20 interleavings of two actors with three
yield points each and checks the normalized six-step counter trace. Each
interleaving has a generated CLEAR program with independently locked state
transitions and an asserted final value. The full 20-case generated-schedule
run is clean: 20/20, with zero runtime failures, leaks, MIR errors, or
unexpected passes. The model supplies exhaustive interleaving semantics; the
runtime programs supply the scheduler/lowering/leak check. A runtime hook that
forces a particular scheduler interleaving remains a future strengthening, but
is not required to admit the current commutative locked-counter model.
