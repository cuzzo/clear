# Design: The SCIP Boundary — what SCIP owns, what fact-mine owns

Status: decided, evidence-based. Supersedes the implicit assumption (held through
the 2026-07-25/26 work) that fact-mine should compute its own call resolution and
type inference for every language.

All numbers below are measured, not estimated. Method: for each corpus, run
`espalier -f architecture` four ways — pre-session baseline (`9221f8f17`) and HEAD,
each with and without a SCIP index — and compare `time_complete` per function.

---

## 0. The evidence

### 0.1 Completeness by corpus and configuration

| Corpus | Lang | BASE src | HEAD src | BASE+SCIP | HEAD+SCIP |
|---|---|---|---|---|---|
| fact-mine `src/` | Rust | 27.0% | 30.2% | 58.8% | **66.5%** |
| Go stdlib (sort+strings) | Go | 24.5% | 48.6% | 46.4% | **60.4%** |
| gremlins | Go | 32.0% | 35.0% | 53.1% | **56.0%** |
| boobytrap | Go | 45.9% | 51.0% | 56.5% | **61.2%** |
| unslop | Go | 24.0% | 23.6% | 28.1% | **27.7%** |
| cheat | Ruby | 6.0% | 5.7% | *no indexer* | — |

**SCIP is worth more than every resolution feature we have ever written**, in every
language that has an indexer: +36.3 pts (Rust), +21.0 (gremlins), +11.8 (Go stdlib),
+10.2 (boobytrap), +4.1 (unslop).

### 0.2 Who actually resolves calls when SCIP is present

| Corpus | calls | resolved by SCIP | resolved by our passes |
|---|---|---|---|
| fact-mine (Rust) | 8727 | 8406 | **0** |
| gremlins (Go) | 649 | 519 | **0** |
| boobytrap (Go) | 1030 | 673 | **0** |
| Go stdlib | 731 | 391 | **7** |

`scip.rs` overwrites `call.target`/`semantic_symbol` unconditionally for any call it
matches. Our resolution contributes ~nothing whenever SCIP is available.

### 0.3 Proof by deletion

Reverting the entire local-call-result type-inference feature (`2327bbc70` — design
doc + implementation, the single largest investment of the session):

```
HEAD             + SCIP:  956/1438 = 66.5%
HEAD − inference + SCIP:  956/1438 = 66.5%    ← byte-identical
```

Zero contribution under SCIP.

### 0.4 What our work *does* add on top of SCIP

Comparing BASE+SCIP → HEAD+SCIP: Go stdlib **+14.0 pts**, Rust **+7.7**, boobytrap
+4.7, gremlins +2.9, unslop −0.4. Mechanically this is **+2778 newly-priced call
contexts**, dominated by cost-layer work: field reads (~1000), `Some`/`None`/`Ok`/`Err`
(+393), constructors (+347), collection methods (+50).

### 0.5 What a SCIP index actually contains (verified on gremlins.scip)

- 15809 occurrences, 2675 symbol entries
- **582 external symbols**, versioned:
  `scip-go gomod github.com/golang/go/src go1.25.0 context/`
- **128 `is_implementation` relationships** (interface satisfaction)
- **2673/2675 symbols carry `signature_documentation`** with full types:
  `func newRootCmd(ctx context.Context, version string) (*gremlinsCmd, error)`

---

## 1. What SCIP does that is useful to us

1. **Call resolution** — the occurrence at a call site maps to a canonical symbol.
   This is the single highest-value input we get, and it is compiler-grade
   (produced by `go/types`, rust-analyzer, tsc, …). §0.1/§0.2.
2. **Receiver/expression typing, implicitly** — because the symbol path encodes the
   owner (`…/Buf#Add().`), receiver typing comes free with resolution. This is the
   entire problem the session's inference/field-access/generic-owner work tried to
   solve by hand.
3. **Declared type signatures** — `signature_documentation` gives parameter and
   return types verbatim. **Currently discarded** (see §4.1).
4. **Interface satisfaction** — `is_implementation` relationships. Already consumed
   (`scip.rs:522`), and it is exactly what `compute_dispatch_impls` re-derives.
5. **Stable, versioned external identity** — stdlib/dependency symbols carry a
   version (`go1.25.0 context/`). This is a far better key for a cost registry than
   the name-based matching we use today.
6. **Cross-file / cross-package / cross-module linking** — for free, at whole-project
   scope, without our namespace-reconciliation machinery.

## 2. What we must NEVER do if we use SCIP

These are the rules that would have prevented two days of waste.

1. **Never write language-specific call resolution for a language that has an
   indexer.** Trait/generic/overload/macro resolution is a type-checker's job. Our
   Rust source-only mode caps at 30% against SCIP's 66%; the gap is unclosable by
   construction.
2. **Never infer a type we can read.** Local call-result types, receiver types,
   field types, return types — SCIP has them. Consume, don't derive.
3. **Never re-derive interface satisfaction.** `is_implementation` is authoritative;
   structural methodset matching is a strictly worse approximation.
4. **Never report a completeness number without recording which resolution tier
   produced it.** The root cause of the session's failure was measuring source-only
   and believing it was the ceiling. Every reported metric must carry its tier.
5. **Never trust a SCIP index without asserting it is non-empty and covering.**
   `scip-go .` on unslop produced a *valid, well-formed, 79-byte, completely empty*
   index. Silent degradation to source-only is the most dangerous failure mode in
   this system.
6. **Never fix a "call resolution" symptom in the cost layer without checking the
   tier.** Several session commits (operators, member reads, conversions, enum
   constructors) *look* like resolution failures. They are legitimately cost-layer
   fixes — the target genuinely has no body — but the check must be conscious.

## 3. What SCIP does NOT do, which we need

SCIP is a *symbol graph*. It has no notion of cost, control flow, or program shape.
Everything below is ours and always will be:

1. **Big-O cost of an operation.** SCIP says `Vec#push()`; it never says
   `linear_materialize`. The `config/stdlib_complexity/*.yml` registries are ours.
2. **The complexity algebra** — loop nesting and power, recursion classification,
   size domains, callback-cost substitution (`C`, `N*C`), parametric bounds, the
   per-function fixpoint. Nothing in SCIP participates.
3. **AST/CFG extraction** — normalized nodes, control-flow graph, reaching
   definitions, liveness. SCIP has ranges, not structure. Without our extractor,
   lambdas were not analyzed as functions *at all*, and Kotlin expression bodies
   were dropped entirely (`e043b0989`, `822aad153`, `5c1ecf7d0`).
4. **Syntactic constructs that have no callee** — operators, subscripts, field
   reads, type conversions, enum constructors. There is no symbol to resolve; these
   must be priced. This is where the majority of our SCIP-additive value came from
   (§0.4).
5. **Cost of *unindexed* code** — stdlib/dependency *bodies*. See §4.2.
6. **The no-build path.** SCIP requires a compiling project. Snippets, partial
   checkouts, broken builds, and unsupported languages have no index.
7. **Nil-Kill / Decomplex facts** — nullability, hazards, clone detection, path
   conditions. Entirely outside SCIP's model.

## 4. The biggest gaps — and which we can close

### 4.1 GAP (ours, not SCIP's): we throw away the types SCIP gives us — **CLOSE NOW**

`SymbolInformation` in `scip.rs` deserializes only `symbol` and `relationships`.
`signature_documentation` — which contains complete parameter and return types for
2673/2675 symbols — is **discarded**.

This is the highest-value, lowest-risk work available. It replaces, with authoritative
data, the exact thing the session tried to hand-roll (return types → local types →
receiver types → method pricing). **Closeable: yes, immediately.**

### 4.2 GAP: SCIP indexes references to dependencies, not their bodies — **CLOSE, and it is our moat**

`scip-go` on a probe module produced an index of `main.go` only; stdlib source was
not indexed. Dependency/stdlib calls resolve to a *symbol* but there is no body to
derive a cost from. Verified: `strings.ToUpper` / `Builder.WriteString` in the Go
test carried no SCIP provenance at all.

Two complementary closures:
- **Index stdlib source directly** — the Go stdlib *is* indexable (`/usr/lib/go/src`
  has a `go.mod`; `scip-go ./sort/... ./strings/...` works). Analyze stdlib source
  with Espalier and emit a cost registry keyed by SCIP symbol.
- **Key cost registries on versioned SCIP symbols** rather than names, eliminating
  the name-collision guessing in the current registries.

This is the Espalier-maps-the-stdlib idea, and SCIP makes it *more* valuable, not
less: SCIP supplies precise identity, we supply the cost. **Closeable: yes; highest
long-term value.**

### 4.3 GAP: languages with no indexer — **PARTIALLY CLOSEABLE, and currently neglected**

| Have an indexer | No usable indexer |
|---|---|
| Go, Rust, TS/JS, Java/Kotlin, Python, C#, C/C++¹ | **Swift, Lua, PHP, Zig, Ruby²** |

¹ `scip-clang` needs `compile_commands.json`, often absent.
² `scip-ruby` requires Sorbet; unusable on ordinary Ruby.

For these, our own resolution is the *only* option — and the session did nothing for
them. Ruby went from **40 complete functions to 40**. This is the real gap in our
coverage and it is where resolution effort belongs. **Closeable: partially** — Ruby
and PHP need runtime type feedback (the nil-kill join), not a static resolver;
Swift/Zig are tractable statically.

### 4.4 GAP: SCIP is a stale snapshot requiring a build — **MITIGATE, not close**

Index cost is small (rust-analyzer on fact-mine: 24s/17MB; scip-go on gremlins:
7.6s/1.5MB), but it requires a working build and goes stale on edit. Mitigation:
cache indexes by commit, fall back to source-only with a *loud* tier annotation, and
never silently degrade (§2.5).

### 4.5 NON-GAP: source-only resolution quality for indexed languages — **DO NOT CLOSE**

Tempting and wrong. Rust source-only cannot approach 66%. Go source-only is closer
but still behind SCIP on real projects (35.0 vs 56.0 on gremlins). Effort here is
strictly dominated by just running the indexer.

---

## 5. Path forward

### Phase 1 — Stop the bleeding (immediate)
1. **Make SCIP the default resolution tier** for every language with an indexer.
   Already implemented; make it the default path, not an opt-in flag.
2. **Add tier assertions**: index non-empty, and ≥ threshold of calls carrying
   `target_provenance == "scip"`. Fail loudly otherwise.
3. **Stamp the resolution tier on every emitted metric** and on architecture output.
4. **Delete Rust source-only resolution**: `2327bbc70` (proven zero, §0.3),
   `2b33520ca`, and the resolver half of `b84058a0d` (keep its `scoped_call_parts`
   extraction half). Freeze that layer for indexed languages.

### Phase 2 — Consume what SCIP already gives us (highest ROI)
5. **Parse `signature_documentation`** into parameter/return types and feed the
   existing type maps (§4.1). This retires the entire hand-rolled inference path.
6. **Prefer `is_implementation`** over `compute_dispatch_impls` when SCIP is present;
   keep the structural computation only as the no-SCIP fallback.

### Phase 3 — Invest in the moat (the only durable differentiator)
7. **Espalier-map stdlib/dependency costs, keyed by versioned SCIP symbol** (§4.2).
   Measured precedent: cost work delivered **+14 pts on the Go stdlib with SCIP on**.
8. **Extend the cost algebra** — recursion classification (77 `O(2^N)` functions
   remain in the Rust corpus), callback/interface parametric closure, the
   complete-vs-complete-worst-case distinction.

### Phase 4 — Serve the languages SCIP abandons
9. **Redirect all resolution effort to Swift, Lua, PHP, Zig, Ruby.** Hold it to a
   measured bar: ship only if completeness moves on a real corpus.
10. **Ruby/PHP need the nil-kill runtime-type join**, not a static resolver — their
    ceiling is type *availability*, not type *inference*.

### The one-line rule

> **SCIP (or a real type checker) owns "what is this and what does it call."
> fact-mine owns "what does it cost." Never invert that.**
