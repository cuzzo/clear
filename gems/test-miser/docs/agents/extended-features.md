# TestMiser Extended Features

Status: Core implementation landed; counterfactual and oracle execution are evidence-gated and adapter-backed

## Purpose

TestMiser should answer a narrow, high-value question: does a test add reliable fault-detection evidence, or is it weak or redundant relative to the rest of the suite?

This is especially useful for reviewing LLM-assisted and generated tests, but provenance must not affect the verdict. Handwritten, generated, and LLM-assisted tests must be evaluated by the same evidence. Provenance may be used only to select a cohort or present results.

The design must remain:

- Cross-language at its core.
- Conservative when evidence is incomplete.
- Based on observed behavior, not test style.
- Compatible with lightweight language adapters.
- Explicit about the difference between weak, redundant, out-of-scope, and unknown.

TestMiser already has the most important foundation: complete per-test mutant attribution through `covered_by` and `killed_by`. It also correctly distinguishes a covered test that kills no mutants from a test that never reaches the mutated code, and describes equal kill sets as only *possibly* redundant. The features below extend that evidence model rather than replacing it.

## Evidence hierarchy

Evidence should be ranked from strongest to weakest:

1. The test detects reversal of the production change it claims to protect.
2. The test adds stable detection of mutants that no comparison test kills.
3. The test adds detection on the dynamically subsuming mutant frontier.
4. The test's mutant kills demonstrably depend on its explicit oracle.
5. The test is dominated by another test or duplicates an existing kill set.
6. Coverage, runtime, size, and provenance provide context only.

No single scalar “test quality score” should collapse these dimensions. A vector of evidence and named findings is more accurate and easier to audit.

## 1. Marginal mutation contribution

For a test `t`, define:

```text
C(t) = mutants covered by t
K(t) = mutants killed by t

unique_kills(t) = K(t) - union(K(u) for every u != t)
```

For a newly added or selected cohort `N` compared with a baseline cohort `B`:

```text
new_detection(N) = union(K(t) for t in N) - union(K(t) for t in B)
```

Both views are necessary. Two new tests may kill the same previously surviving mutant. Each then has zero globally unique kills, while the cohort genuinely increases detection. TestMiser should report that the cohort adds value but contains internal redundancy.

Suggested classifications:

- `ADDS_STABLE_UNIQUE_KILLS`: the test is the only stable killer of at least one mutant.
- `ADDS_GROUP_DETECTION`: the cohort kills mutants not killed by the baseline, although no member is individually unique.
- `MUTATION_REDUNDANT`: the test adds no stable kills relative to the selected comparison set.
- `COVERED_WEAK_ORACLE`: the test covers relevant mutants but kills none.
- `OUT_OF_MUTATION_SCOPE`: no relevant mutant is covered; this is not evidence that the test is poor.

Marginal contribution is language-neutral and can be derived from the existing complete kill matrix.

## 2. Test dominance

Exact equal kill sets catch only the simplest redundancy. TestMiser should also identify conservative set dominance.

Test `A` is a dominance candidate of `B` when:

```text
C(A) is a subset of C(B)
K(A) is a subset of K(B)
unique_kills(A) is empty
```

The finding should explain the exact set relationship and should never recommend automatic deletion. Tests may still differ in diagnostic quality, specification value, platform coverage, integration boundaries, or future fault sensitivity.

Dominance findings require complete attribution for the comparison corpus. Partial runs must yield `UNKNOWN`, not a redundancy verdict.

## 3. Counterfactual production-change detection

The strongest practical check for a newly written regression test is whether it detects removal of the production change it accompanies.

The first implementation should operate on the complete production patch:

1. Run the new test against the current source; it must pass.
2. Reverse the production-code portion of the patch while retaining the new test.
3. Build and run the selected test in an isolated worktree.
4. Record one of:
   - `PROVES_REVERTED_CHANGE`: the reversed source builds and the test fails for the expected reason.
   - `DOES_NOT_DETECT_REVERTED_CHANGE`: the reversed source builds and the test still passes.
   - `INCONCLUSIVE`: the reverse patch cannot be applied, the source no longer builds, the test cannot execute, or infrastructure fails.

TestMiser should also run the relevant baseline tests against the reversed source when feasible:

- If only the new cohort fails, it adds regression detection.
- If both existing and new tests fail, the new test may duplicate change detection.
- If neither fails, the test does not protect the reverted behavior.

Whole-patch reversal is deliberately preferred to per-hunk reversal. Individual hunks frequently depend on one another and create build failures that reveal nothing about test quality. More granular semantic reversal can be considered later only if whole-patch results demonstrate a real need.

This feature is cross-language: the core needs Git, an isolated workspace, and the existing native test-runner adapter. It does not require parsing application syntax.

## 4. Oracle-dependent mutant kills

A mutant can be killed by an assertion, but also by setup failure, an unrelated mock, a timeout, or an incidental exception. Raw kill count therefore overstates oracle quality.

For a test with recognized explicit oracles:

1. Disable one oracle at a time using a syntax-aware transformation.
2. Rerun only mutants the original test killed.
3. Compute:

```text
oracle_dependent_kills = original_kills - kills_with_oracle_disabled
persists_without_oracle = original_kills intersect kills_with_oracle_disabled
```

Kills that disappear when the oracle is disabled are evidence that the assertion distinguishes behavior. Kills that persist may be incidental. This is a review signal, not proof that the test is worthless: crash safety and termination can themselves be intended properties.

The analysis must retain attribution per oracle when a test has several assertions. Disabling all assertions at once is cheaper but loses the distinction between a strong assertion and a redundant one.

## 5. Oracle sensitivity mutations

TestMiser should support a small set of conservative mutations to the test itself. A mutated oracle should fail against correct production code. If it still passes, the oracle may be vacuous, unreachable, or disconnected from the behavior under test.

Initial high-signal transformations:

- Negate a boolean assertion.
- Change a literal expected value to a nearby value of the same kind.
- Remove the target invocation from an expected-exception construct.
- Broaden or narrow an expected exception when the framework exposes an exact type.
- Remove a mock or spy verification.
- Perturb a snapshot or golden expectation through its framework API.

Each transformation must have a positive recognition rule and a safe rewrite. Unsupported or ambiguous constructs produce `UNKNOWN`; they must not be described as missing or weak assertions.

Normalized oracle facts should include at least:

```text
test_id
oracle_kind
oracle_span
expected_span
actual_span
framework
confidence
```

Recognized oracle families should include equality, identity/truth/null checks, exception expectations, snapshots/goldens, mock verification, property assertions, compile-fail tests, and subprocess exit/output assertions. Support can be added incrementally by framework.

### Syntax-adapter boundary

TestMiser must not become another multi-language parser.

Preferred architecture:

- FactMine's `syntax-facts` output is adapted into normalized oracle facts.
- Tree-sitter framework providers recognize assertion-shaped calls from registered grammar packs.
- TestMiser consumes those facts, schedules transformations, executes tests, and evaluates outcomes.

A framework query should normally be tens of lines, not a language-specific analyzer. Aliases, wrappers, metaprogrammed assertions, and uncertain data flow remain unknown unless another provider resolves them.

CodeQL may optionally enrich supported ecosystems with high-confidence data-flow facts, such as whether a system-under-test result reaches an assertion operand. It must not be required by the core design: CodeQL coverage, database construction, and APIs are language-specific and do not span TestMiser's intended language matrix.

## 6. Dynamic mutant subsumption

Large numbers of easy or equivalent mutants can make kill counts misleading. TestMiser should derive dynamic mutant subsumption from the complete test-by-mutant kill matrix.

For mutant `m`, let `T(m)` be the tests that kill it. A harder mutant `m1` dynamically subsumes an easier mutant `m2` when:

```text
T(m1) is nonempty
T(m1) is a subset of T(m2)
```

Any suite that detects `m1` therefore also detects `m2` in the observed corpus. TestMiser should retain all mutants for diagnostics while deriving a nonredundant or subsuming frontier for ranking marginal contribution.

Recommended evidence fields:

- Total stable unique kills.
- Stable unique kills on the subsuming frontier.
- Newly detected subsuming mutants for a cohort.
- Equivalent-mutant groups with identical nonempty killer sets.

This prevents dozens of trivial mutants at one expression from outweighing one difficult, behaviorally distinct mutant elsewhere. The result remains dynamic and corpus-dependent; reports must not claim universal semantic subsumption.

## 7. Stable attribution

Flakiness can manufacture both kills and apparent redundancy. Expensive reruns should be focused rather than applied to the entire matrix.

Rerun candidates include:

- Tests provisionally classified as weak or redundant.
- Mutants that distinguish otherwise similar tests.
- Counterfactual trials.
- Oracle-disabled and oracle-mutated trials.

Three consistent observations are a reasonable initial threshold. Artifacts should retain trial outcomes rather than only an aggregate boolean.

Derived fields:

```text
stable_unique_kills
unstable_kills
stable_oracle_dependent_kills
counterfactual_stability
```

An unstable fact cannot support `ADDS_STABLE_UNIQUE_KILLS`, `MUTATION_DOMINATED`, or a strong low-value conclusion.

## 8. Cost-aware review

Runtime and resource cost matter only after contribution is established. A slow test with unique fault detection may be valuable; a fast duplicate may still be unnecessary.

Expose evidence as a vector, for example:

```json
{
  "stable_unique_kills": 3,
  "newly_killed_subsuming_mutants": 2,
  "detects_reverted_change": true,
  "oracle_dependent_kill_ratio": 1.0,
  "runtime_ms": 42
}
```

`HIGH_COST_NO_MARGINAL_DETECTION` may prioritize review, but cost alone must never classify a test as low quality.

## Findings and verdicts

Reports should use composable named findings.

High-value evidence:

- `PROVES_REVERTED_CHANGE`
- `ADDS_STABLE_UNIQUE_KILLS`
- `ADDS_GROUP_DETECTION`
- `ADDS_SUBSUMING_MUTANT_DETECTION`
- `STRENGTHENS_EXISTING_ORACLE`

Review candidates:

- `DUPLICATES_CHANGE_DETECTION`
- `MUTATION_DOMINATED`
- `EQUAL_KILL_SET`
- `COVERED_WEAK_ORACLE`
- `HIGH_COST_NO_MARGINAL_DETECTION`
- `PERSISTS_WITHOUT_ORACLE`

A “likely low-value” summary should require several independent, stable signals—for example: no marginal kills, relevant mutant coverage, dominance by another test, failure to detect the reverted production change, and kills that persist after disabling the oracle.

Unknown states:

- No relevant mutants.
- Incomplete attribution.
- Unsupported oracle syntax.
- Reversed source does not build.
- Test or mutant outcome is flaky.
- Test validates an integration or architectural property outside mutation scope.

Unknown is a first-class result, not a failure of the analysis and not evidence against the test.

## Artifact model

The current mutant facts should remain usable. Optional additions can record:

- Test provenance: added, modified, or existing.
- Trial identity and repeated outcomes.
- Test duration.
- Mutant operator, location, and execution outcome.
- Completeness of corpus and attribution.

Oracle facts should be a separate normalized artifact so syntax extraction remains decoupled from mutation execution.

A derived TestMiser evidence artifact should provide, per test and cohort:

```text
covered_mutants
killed_mutants
unique_kills
subsuming_unique_kills
cohort_new_detection
dominated_by
counterfactual_outcome
oracle_sensitivity
oracle_dependent_kills
stability
runtime
evidence_completeness
```

Schema evolution should remain additive where possible. A versioned `test-quality-evidence/v1` artifact is preferable to overloading raw mutant facts with every derived conclusion.

## Completeness gates

Every strong finding needs an explicit gate:

| Finding | Required evidence |
|---|---|
| Unique contribution, equality, dominance | Complete selected corpus and complete per-test attribution |
| Dynamic subsumption | Complete, stable kill matrix |
| Counterfactual detection | Head passes; reverse applies; reversed source builds; selected tests execute |
| Oracle-dependent kills | Recognized oracle; successful syntax rewrite; original and transformed trials complete |
| Oracle sensitivity | Recognized safe mutation; mutated test executes on correct production source |
| Cost comparison | Comparable runner and timing conditions |

If a gate fails, emit a reasoned `UNKNOWN` result rather than degrading to a weaker accusation.

## Implementation plan

### Phase 1: language-neutral contribution analysis

- Add per-test unique kills.
- Add cohort-versus-baseline detection.
- Add set dominance.
- Preserve current exact-equality reporting.
- Add completeness gates and machine-readable evidence.

Estimated production size: 250–450 lines plus tests.

### Phase 2: dynamic subsumption and stability

- Derive equivalent mutant classes and the subsuming frontier.
- Rank marginal detection using both full and frontier mutant sets.
- Add targeted rerun scheduling and stable/unstable attribution.

Estimated production size: 250–450 lines plus tests.

### Phase 3: counterfactual patch reversal

- Add isolated Git worktree orchestration.
- Split production and test patch paths.
- Reuse native runner adapters.
- Compare new and baseline cohort behavior.
- Preserve build and infrastructure failures as inconclusive evidence.

Estimated production size: 500–900 lines plus runner fixtures and tests.

### Phase 4: oracle facts and sensitivity

- Define the normalized oracle-facts schema.
- Run the FactMine and Tree-sitter oracle providers.
- Apply conservative span-based rewrites and require a correct-production control failure.
- Rerun originally killed mutants under unique, comparable repeated trial IDs.

Estimated generic production size: 300–600 lines, plus approximately 10–40 lines per straightforward framework query and framework-specific fixtures. Complex frameworks should be deferred rather than forcing low-confidence recognition.

### Phase 5: optional enrichments

- Add CodeQL data-flow providers where they demonstrably improve precision.
- Add cost-aware prioritization.
- Add provenance filters for reviewing generated-test cohorts.

These features should not block the language-neutral core.

## Testing strategy

### Language-neutral matrix fixtures

Use compact synthetic kill matrices covering:

- One unique killer.
- A dominated test.
- Exact duplicate kill sets.
- A cohort pair with group value but no individually unique kill.
- Relevant coverage with zero kills.
- Zero mutation coverage.
- Equivalent mutants.
- A nontrivial subsumption chain.
- Incomplete and unstable attribution.

Expected classifications and evidence sets must be exact.

### Counterfactual fixtures

Create small repositories in at least two supported ecosystems with:

- A true regression test that fails after reversal.
- A plausible-looking test that does not detect the reversed change.
- Existing tests that already detect the reversal.
- A reverse patch that causes a build failure and must be inconclusive.

The orchestration contract should be identical across languages; only runner commands differ.

### Oracle fixtures

For every supported framework, include:

- Positive examples for each recognized oracle kind.
- Lookalike custom functions that must not be classified as framework assertions.
- Multiple assertions with different mutant contribution.
- Exception, snapshot, mock, and subprocess assertions when supported.
- Unsupported aliases that explicitly produce unknown evidence.

### Quality gate

Before enabling a new warning by default, manually label a representative multi-language sample and require at least 90% confirmed precision. Lower-precision findings remain informational or opt-in. The goal is not maximum recall; it is actionable review with very low noise.

All analyses must remain run-to-completion and report every qualifying test, rather than stopping at the first finding.

## Explicit non-goals

Do not infer test quality from:

- Assertion count.
- Test line count.
- Test names, comments, or prose quality.
- Embedding or textual similarity alone.
- Mock count.
- An LLM judge.
- Coverage percentage alone.
- Generic test-smell totals.

These values may be displayed as metadata, but they must not create a quality or redundancy finding.

Do not automatically delete or disable a test. TestMiser provides behavioral evidence to a reviewer; it does not know every specification, diagnostic, platform, or integration role a test serves.

## Why this is cross-language

The highest-value layers operate on universal artifacts:

- Git patches.
- Test identities and outcomes.
- Mutant coverage and kill sets.
- Repeated-trial stability.
- Runtime measurements.

Only oracle recognition needs syntax-specific support. Keeping that boundary as normalized facts allows small Tree-sitter framework queries without making TestMiser language-aware throughout its architecture. CodeQL remains an optional enrichment rather than a portability requirement.

## Research basis

- Just et al. found mutation analysis to correlate with real-fault detection independently of structural coverage, including for automatically generated suites: [Are Mutants a Valid Substitute for Real Faults in Software Testing?](https://homes.cs.washington.edu/~mernst/pubs/mutation-effectiveness-fse2014-abstract.html)
- Dynamic subsumption provides a test-observed way to identify a nonredundant mutant frontier: [Dynamic Mutant Subsumption Analysis](https://arxiv.org/abs/1809.02435)
- Operator and mutant redundancy can materially distort mutation scores: [On the use of mutation operators for equivalent mutant detection](https://doi.org/10.1002/stvr.1561)
- Assertion removal exposes the gap between executing faulty behavior and actually checking it: [Mind the Gap: An Empirical Study on the Limitations of Code Coverage as a Measure of Test Effectiveness](https://arxiv.org/abs/2309.02395)

## Recommendation

Implement marginal contribution, cohort analysis, dominance, and dynamic subsumption first. They are broadly useful, require no new language adapter, and directly improve the interpretation of TestMiser's existing facts.

Patch reversal should follow because it supplies the strongest evidence for newly generated regression tests. Oracle sensitivity is valuable, but should be introduced framework by framework with conservative recognition and an explicit unknown state.

This produces a high-signal system for assessing LLM-assisted tests without attempting to detect authorship, rewarding superficial test style, or making claims that the available evidence cannot support.
