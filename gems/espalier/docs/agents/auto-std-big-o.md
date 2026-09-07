# Automatic Standard-Library Big-O Models

Status: proposed design.

## Decision

Generate versioned standard-library complexity candidates from pinned runtime
source, then promote only reviewed or contract-backed candidates into the
models consumed by Espalier.

The generated catalogue is evidence, not an automatic public complexity
contract. Parsing a native implementation can usually identify the operation
and expose its control flow, but it does not by itself prove the public cost of
dynamic dispatch, callbacks, allocation, hashing, comparison, IO, or other
input-dependent behavior.

FactMine owns source acquisition, API binding, native-source analysis, and the
generated artifact. Espalier remains language-neutral: it consumes reviewed
normalized operation models and performs symbolic composition. It must not
parse runtime source or maintain language-specific standard-library names.

## Goals

- Discover public API-to-implementation bindings for supported runtime
  versions.
- Derive conservative time, auxiliary-space, allocation, and callback-cost
  candidates from native and language-level implementations.
- Preserve the source, conditions, derivation method, and confidence behind
  every candidate.
- Detect meaningful complexity changes between runtime versions.
- Reduce manual catalogue maintenance without introducing confidently wrong
  bounds.
- Give reviewers a focused queue for unresolved and changed native operations.
- Support implementation-specific analysis when the runtime and version are
  known, while retaining portable language-level contracts.

## Non-goals

- Do not infer a language-wide guarantee from one runtime implementation.
- Do not automatically publish every source-derived result as authoritative.
- Do not treat unresolved calls, callbacks, allocators, or dynamic dispatch as
  constant time.
- Do not store the authoritative history as a chain of diffs.
- Do not move language or runtime catalogues into Espalier.
- Do not use benchmarks as proof of asymptotic complexity. Benchmarks may find
  suspicious models, but cannot establish a bound.

## Why source mining is useful but insufficient

The public-to-native binding is often mechanically discoverable:

- CPython's Argument Clinic records qualified Python API names and generates C
  wrappers. It is an internal, version-dependent preprocessor, so extraction
  must be pinned to the runtime version. See the
  [Argument Clinic documentation](https://docs.python.org/3.10/howto/clinic.html).
- MRI registers native methods through calls such as `rb_define_method`,
  `rb_define_singleton_method`, and `rb_define_alias`. See the
  [Ruby extension API](https://docs.ruby-lang.org/en/master/extension_rdoc.html).
- Lua's core and standard libraries are compact, centralized C sources. See the
  [Lua 5.4 source index](https://www.lua.org/source/5.4/).

Native control flow is not necessarily the public cost. For example:

```c
for (i = 0; i < len; i++)
    rb_funcall(element, id_hash, 0);
```

The visible loop is linear, but the meaningful result is parametric:

```text
O(N * C_hash)
```

Common complications include:

- user-defined equality, comparison, hashing, coercion, and conversion;
- overrideable Python slots and Ruby methods;
- Lua metamethods;
- callbacks passed to traversal, sorting, regex, or transformation APIs;
- amortized allocation and hash-table resizing;
- multiple independent input domains;
- output-sensitive operations;
- garbage collection and allocator behavior;
- nonlinear regex and pattern-engine behavior;
- target- or build-specific implementations;
- IO and external latency;
- representation-dependent fast paths;
- generated wrappers and macros that obscure the actual call graph.

Unknown behavior must remain explicit rather than being collapsed to `O(1)`.

## Expected coverage

These are planning estimates, not acceptance claims. They distinguish binding
discovery from publishable complexity models.

| Runtime surface | Bind API to implementation | Derive useful candidate | Publish sound model automatically |
| --- | ---: | ---: | ---: |
| Lua 5.x core libraries | 90-98% | 65-80% | 40-60% |
| CPython builtins and core types | 80-95% | 50-70% | 25-45% |
| MRI Ruby core classes | 75-90% | 40-65% | 20-40% |
| Entire Python or Ruby standard library | 50-75% | 30-50% | 15-30% |

The practical target is higher for common operations: with reviewed overrides,
approximately 80-90% of frequently observed collection, string, numeric, and
primitive operations should have useful models. Covering most public symbols
is less valuable than covering the operations that dominate real corpora.

Actual coverage must be reported by runtime, version, operation family, and
corpus frequency. A single aggregate percentage would conceal important gaps.

## Runtime model versus language contract

Implementation evidence and portable guarantees are separate:

```text
Python language contract != CPython 3.13 implementation
Ruby language contract   != MRI 3.4 implementation
Lua language contract    != LuaJIT implementation
```

When the runtime and version are proven, FactMine may attach the corresponding
implementation model. Otherwise it may use only a portable documented
contract. If no portable contract exists, the operation remains
implementation-dependent or unknown.

This prevents CPython, MRI, or reference-Lua implementation details from being
reported as universal language behavior.

## Architecture

```text
pinned runtime source
  -> runtime API-binding extractor
  -> native call graph and normalized complexity facts
  -> generated immutable version snapshot
  -> documented-contract and manual-review overlay
  -> reviewed standard-library operation artifact
  -> FactMine call-site projection
  -> Espalier language-neutral complexity algebra
```

### FactMine owns

- Fetching or accepting an exact runtime source checkout.
- Recording the runtime, version, source commit, build configuration, and
  target assumptions.
- Extracting public API registrations and aliases.
- Resolving wrappers, macros, generated bindings, and native callees.
- Producing native call-graph and normalized complexity evidence.
- Identifying unresolved dynamic calls, callbacks, allocation, latency, and
  implementation-dependent branches.
- Producing generated snapshots and semantic version-to-version diffs.
- Applying reviewed contract and override overlays.
- Matching a proven call site to a reviewed runtime operation model.

### Espalier owns

- Consuming normalized call-site costs from FactMine.
- Combining input domains and callback-parametric costs.
- Propagating time and auxiliary-space costs interprocedurally.
- Preserving confidence and evidence gaps in output.
- Reporting implementation-specific provenance when relevant.

Espalier must continue to obey the boundary in
[`big-o-design.md`](big-o-design.md): it does not inspect source text or load a
language-specific operation table.

## Artifact model

Generated snapshots should be immutable, reproducible, and sharded by runtime
and version:

```text
stdlib-models/
  cpython/
    3.12.9.json.zst
    3.13.2.json.zst
  ruby-mri/
    3.3.7.json.zst
    3.4.2.json.zst
  lua/
    5.4.8.json.zst
  overrides/
    python.yml
    ruby.yml
    lua.yml
```

The exact location may change, but generated runtime artifacts belong to
FactMine packaging or a separately versioned artifact package, not Espalier's
source tree.

Each operation record should include at least:

```json
{
  "schema": "stdlib-complexity-candidate/v1",
  "runtime": "ruby-mri",
  "runtime_version": "3.4.1",
  "source_commit": "...",
  "target": "portable-default",
  "symbol": "Array#sort",
  "implementation": "rb_ary_sort",
  "time": "O(N log N * C_cmp)",
  "auxiliary_space": "O(N)",
  "amortized": false,
  "input_domains": ["receiver_length"],
  "callback_parameters": ["comparator"],
  "external_latency": false,
  "conditions": [],
  "source_locations": [],
  "derivation": "native-source",
  "confidence": "review-required",
  "unresolved_dependencies": []
}
```

The production schema should use structured expressions rather than storing
Big-O only as display strings. The JSON above illustrates the information, not
the final algebra encoding.

## Authority and conflict resolution

Resolve competing evidence in this order:

1. **Manual correction** for a demonstrated analyzer error or native algorithm
   that cannot yet be derived soundly.
2. **Documented language or runtime contract** when upstream explicitly
   guarantees the bound.
3. **Reviewed source-derived model** for the exact runtime/version.
4. **Unreviewed generated candidate**, retained as evidence but not used as a
   complete Espalier upper bound.
5. **Unknown**, with known lower components and unresolved causes preserved.

Manual overrides are small overlays. They must not copy the generated
catalogue. Every override records:

- the operation and applicable runtime/version range;
- the generated fact it replaces;
- the reason for replacement;
- supporting source, documentation, or regression evidence;
- reviewer and review date;
- whether the override is portable or implementation-specific.

An override must fail validation when its target operation disappears or its
native implementation changes, forcing reconsideration rather than silently
surviving forever.

## Confidence states

Candidates should move through explicit states:

- `discovered`: public API identity and native implementation are linked.
- `derived-partial`: some structural cost is known, with unresolved terms.
- `review-required`: a complete candidate exists but has not been approved.
- `reviewed-implementation`: approved for the exact runtime/version.
- `documented-contract`: supported by an upstream portable guarantee.
- `rejected`: known-unsound derivation retained for diagnostics.

Only `reviewed-implementation` and `documented-contract` may supply a complete
upper bound. Partial candidates may still contribute a lower bound and an
evidence-gap explanation.

## Versioning and diffs

Store full content-addressed snapshots, not a chain of patches. Full snapshots
support random access, independent verification, schema migration, and recovery
without replaying every historical delta. Compression and content-addressed
storage provide sufficient deduplication.

Generate semantic diffs on demand or in CI:

```text
ruby-mri 3.3.7 -> 3.4.2
  Array#foo: implementation changed
  Hash#bar: constant-amortized -> unknown
  String#baz: newly discovered callback dependency
```

A diff should flag:

- added, removed, or aliased public APIs;
- changed implementation bindings;
- changed time, space, allocation, latency, or callback expressions;
- confidence changes;
- newly unresolved dependencies;
- overrides invalidated by implementation changes;
- target-specific divergence.

Generated files must record the extractor version and schema version so a
tooling change can be distinguished from a runtime change.

## Required operation algebra

The current registry vocabulary in
[`config/stdlib_complexity/README.md`](../../../fact-mine/config/stdlib_complexity/README.md)
is deliberately small:

- `constant`
- `logarithmic`
- `linear_scan`
- `linear_materialize`
- `sort`
- `pairwise`

Automatic source mining should not begin by flattening richer evidence into
those labels. The normalized artifact must first represent:

- worst-case, expected, and amortized bounds;
- multiple independent cardinality variables;
- output-sensitive cost;
- callback-parametric cost;
- hashing, equality, and comparison cost parameters;
- allocation count and auxiliary space;
- lazy or deferred execution;
- external latency separately from computational work;
- conditional fast paths and representation-dependent behavior;
- known lower components with an unknown upper bound.

The existing shorthand catalogue may remain as a reviewed input format, but it
should lower into this richer operation algebra.

## Extraction strategy

### Phase 1: inventory and binding only

For one pinned Lua, CPython, and MRI version:

- enumerate public core APIs;
- map registrations, aliases, generated wrappers, and implementation symbols;
- emit unresolved binding reasons;
- compare the generated inventory with runtime introspection and published API
  indexes.

Do not infer complexity in this phase. Its purpose is to establish whether the
public-to-native binding is sufficiently complete and stable.

### Phase 2: conservative native candidates

- Run FactMine over implementation functions and their reachable native call
  graph.
- Preserve parameter and receiver cardinality relationships.
- Recognize loops, recursion, materialization, allocation, and known native
  primitives.
- Replace dynamic calls and callbacks with symbolic cost parameters.
- Mark allocator, GC, IO, regex, and platform dependencies explicitly.
- Produce partial candidates rather than inventing missing costs.

Start with Lua because its source and registration surface are smallest. Use
the results to validate the schema before tackling CPython and MRI wrappers,
macros, and dynamic dispatch.

### Phase 3: review overlays and promotion

- Import upstream documented contracts where they are explicit.
- Review the highest-frequency candidates from real corpora.
- Add small, justified overrides only where derivation is incomplete or wrong.
- Promote approved candidates to reviewed artifacts.
- Add a golden call-site fixture for every newly consumed operation family.

### Phase 4: version-diff automation

- Generate snapshots for adjacent supported runtime releases.
- Produce semantic change reports.
- Invalidate affected reviews and overrides.
- Require review for regressions from known to unknown and for changed
  implementation identities.

### Phase 5: broader runtimes

Add further runtimes only after the pipeline proves useful for Lua, CPython,
and MRI. Each runtime gets a small binding adapter; generic complexity
extraction must remain shared.

## Testing and validation

### Binding oracles

- Compare generated API inventories against runtime introspection.
- Cover aliases, singleton/static methods, generated wrappers, and conditional
  registrations.
- Keep exact fixtures for registration patterns that previously failed.

### Complexity oracles

- Use small native fixtures for loops, recursion, multiple domains, callbacks,
  amortized growth, conditional fast paths, allocation, and unresolved calls.
- Keep selected real runtime implementations as golden regressions.
- Verify that an unresolved callback prevents promotion to a complete upper
  bound.

### End-to-end oracles

- Prove that a runtime-specific model is used only when the runtime/version is
  known.
- Prove that portable analysis does not inherit implementation-specific costs.
- Verify the full path from runtime source through FactMine call-site facts to
  Espalier's rendered time and space.
- Verify that unreviewed candidates cannot silently complete an Espalier
  result.

### Differential and empirical checks

Microbenchmarks may test candidate growth over geometric input sizes and flag
gross inconsistencies. They are diagnostic evidence only. They must not
promote a candidate or override a static/documented result automatically.

Adjacent runtime snapshots should be regenerated twice to prove deterministic,
byte-identical output before semantic diffs are trusted.

## Reporting

Report coverage separately for:

- public APIs inventoried;
- APIs bound to implementations;
- complete and partial derived candidates;
- reviewed implementation models;
- documented portable contracts;
- unresolved operations weighted by corpus frequency;
- operations invalidated by a runtime upgrade.

The unknown-operation workflow described in
[`stdlib-complexity-candidates.md`](../../../fact-mine/docs/agents/stdlib-complexity-candidates.md)
remains the prioritization mechanism. Generated source coverage does not change
the rule that real-corpus frequency and proven call identity determine review
value.

## Risks and controls

| Risk | Control |
| --- | --- |
| Treating one runtime as the language contract | Separate portable and implementation-specific models |
| Dynamic callback hidden behind native code | Emit symbolic callback costs and block automatic promotion |
| Generated wrapper mistaken for the real implementation | Preserve wrapper-to-callee chains and unresolved edges |
| Fast path reported as universal | Record path conditions; use the conservative joined bound |
| Amortized cost reported as strict worst case | Represent bound kind explicitly |
| Override silently surviving an implementation change | Bind overrides to implementation identity and invalidate them |
| Catalogue grows while useful coverage does not | Rank review by typed real-corpus occurrences |
| Generator bug changes every snapshot | Record extractor version and distinguish tool diffs from runtime diffs |
| Empirical timing treated as proof | Use benchmarks only as anomaly detectors |

## Acceptance criteria for an initial implementation

- FactMine deterministically inventories one Lua, CPython, and MRI release.
- Generated snapshots contain exact runtime/source/extractor provenance.
- At least 90% of Lua core-library APIs and 80% of CPython/MRI core APIs are
  either bound or carry a specific unresolved-binding reason.
- The richer normalized algebra represents amortized, callback-parametric,
  multi-domain, allocation, auxiliary-space, and external-latency evidence.
- Unreviewed candidates cannot provide Espalier with a complete upper bound.
- Runtime-specific models are never used without proven runtime identity.
- Overrides are validated and invalidated when their implementation changes.
- Semantic version diffs distinguish runtime-source changes from extractor
  changes.
- End-to-end golden tests cover a reviewed constant, linear, materializing,
  sorting, callback-parametric, and unresolved operation.
- Existing conservative mappings remain correct throughout migration.

## Recommendation

Proceed with a narrow prototype, beginning with API binding and Lua. The design
is valuable because it can automate provenance, discover implementation
changes, and produce a much better review queue. Its success criterion is not
"parse most C and assign most APIs a Big-O." It is:

> Discover nearly all public-to-implementation bindings, derive conservative
> candidates for most native implementations, and automatically publish only
> the subset whose semantics are proven.

That preserves Espalier's soundness boundary while making standard-library
coverage substantially easier to maintain.
