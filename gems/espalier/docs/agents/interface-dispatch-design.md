# Interface / virtual dispatch: a language-agnostic Big-O design

## The problem

A call through an abstract type has no single target:

```go
func Sort(data Interface) {           // Interface = { Len; Less; Swap }
    ... data.Less(i, j) ... data.Swap(i, j) ...
}
```

`data.Less` can be any concrete implementation. Today the analyzer treats it as
fully unknown, so `Sort` produces a garbage polynomial and is marked
*incomplete* - when the honest answer is `O(N log N * C_Less)`: **known, and
dependent on the cost of the comparison**.

This is not Go-specific. Every language has the same shape under different
syntax: Go interfaces, Rust traits, Java/C#/Kotlin interfaces and abstract
classes, Swift protocols, TypeScript interfaces, C++ virtual classes, Python
ABC/`Protocol`/duck typing, Ruby modules/duck typing. The solution must live in
the language-agnostic core, with the only per-language piece being *"which
concrete types can stand in for this abstract one."*

## Core insight: an interface method call is a callback

`sort.Interface` is a **bundle of callbacks** passed as one parameter. `data.Less`
is exactly `cmp(i, j)` where `cmp` is an injected function of unknown cost. So the
machinery already built for callbacks (#43/#44) is the foundation:

- `parameterized_cost` mints a symbolic cost domain `C`.
- `substitute` / `without_domains` substitute a concrete callback cost for `C`.
- callback-taking functions already resolve to `O(N * C)`.

The whole design is: **treat an abstract-typed parameter/receiver's method calls
as callbacks with cost `C_{I.M}`, then resolve `C_{I.M}` to the worst concrete
implementation.** Two views fall out, and both are wanted:

1. **Definition-site (parametric).** Analyzing `Sort` alone, `Less`/`Swap` are
   callbacks. `Sort = O(N log N * C_Less + N * C_Swap)`. This is **complete as a
   parametric bound** - it fixes the "incomplete" bug immediately, and it is the
   result you asked for ("known, dependent on callbacks").
2. **Resolution (worst-case).** When we want a concrete number - at a call site
   `Sort(myData)`, or corpus-wide - substitute `C_{I.M}` with the cost of the
   worst concrete implementation, with provenance and an open/closed-world flag.

## The normalized fact: a dispatch graph

The core reasons over one new, language-neutral fact family carried on the
profile. Adapters populate it; the algebra never inspects syntax.

```
abstract_type(I)          # I dispatches at runtime; no single body per method
requires_method(I, M)     # abstract I demands method M (its callback surface)
dispatch_impl(I, T)       # concrete T is a possible runtime target for static I
open_dispatch(I)          # I is extensible outside the analyzed corpus
```

`dispatch_impl(I, T)` is the *satisfaction relation*. It is the **only**
language-specific input, and it is pure data once emitted:

| Language | Abstract type | How the adapter computes `dispatch_impl(I, T)` |
|---|---|---|
| Go | `interface` | structural: `methodset(T) ⊇ methods(I)` |
| Rust | `trait` | `impl I for T` blocks |
| Java / Kotlin | `interface`, `abstract class` | `class T implements I` / `extends` |
| C# | `interface`, `abstract class` | `T : I` |
| Swift | `protocol` | `T: P` incl. `extension T: P` |
| TypeScript | `interface`, abstract | `implements`, or structural methodset |
| C++ | class with virtuals | public inheritance |
| Python | `ABC` / `Protocol` / duck | subclass, `ABC.register`, or Protocol methodset |
| Ruby | `module` / duck | `include`, or responds-to the method set |

`open_dispatch(I)` is likewise adapter-owned (Go: exported interface; Rust:
public trait; Java: non-`sealed`; etc.) - it distinguishes "we have seen every
implementation" from "external code may add more."

Note we already carry `supertypes` on owners (used for Go embedding and nominal
inheritance in `resolve_inherited_calls`). `dispatch_impl` is the inverse,
transitive-closure relation and generalizes it; the two share extraction.

## The algorithm (language-agnostic, in espalier)

For a call `x.M(...)` whose static receiver type is abstract `I` (or `x` is an
abstract/callback parameter), during the existing structural big-O fixpoint:

1. **Candidate set.** `impls = { T : dispatch_impl(I, T) }` within the corpus.
2. **Per-implementation cost.** `cost(T.M)` from the method-complexity fixpoint
   (recursively; interface calls inside `T.M` recurse into this same rule).
3. **Cost domain.**
   - If `open_dispatch(I)` **or** `impls` is empty → `C_{I.M}` is a *free symbolic
     domain* (unknown-but-bounded parameter), source-kind `interface_cost`. The
     bound stays parametric, exactly like an unresolved callback.
   - Else (closed set of known impls) → `C_{I.M} = max_{T ∈ impls} cost(T.M)`,
     the **worst-case implementation**.
4. **Substitute** `C_{I.M}` into the caller's structural bound via the existing
   `substitute` path. `Sort → O(N log N * C_Less)`, then `C_Less → O(1)` (IntSlice)
   or whatever the worst impl proves.
5. **Recursion / SCC.** Interface calls can be mutually recursive (impl calls back
   through the interface). Use a monotone fixpoint seeded at the free `C` domain
   and widen upward; a strongly-connected interface cycle with no proven progress
   yields `unbounded`, never a fabricated polynomial.

The definition-site view is just step 3's "free domain" branch; the resolution
view is the "closed max" branch. Same code path.

## Open vs. closed world (correctness, not optimism)

- **Closed** (`impls` complete, `not open_dispatch(I)`): the max is a real bound.
  Report `O(... * C)` with `C` resolved and `bound_quality: closed_impl_max`.
- **Open** (`open_dispatch(I)`): the true worst case is unbounded - external code
  may implement `I` arbitrarily. Report the parametric `O(... * C)` and attach the
  known max as an **observed lower bound**, flagged
  `bound_quality: open_world_observed_max`. Never silently present the
  in-corpus max as the guaranteed bound for a public interface.

## Provenance: call out the worst case (required output)

Every interface-dispatched term emits, alongside the bound:

```
interface: I.M
chosen_worst: T.M  (cost)              # the implementation that set the bound
distribution: [T1.M O(1), T2.M O(n), …] # so tightness of the max is visible
world: closed | open
```

This is what surfaces "the specific worst case" in reports and lets a human see
whether one pathological implementation is dragging an otherwise-cheap interface.

## Impact analysis: how often the worst case actually matters (required output)

Two levels, both mechanical once the symbolic bound carries the `C` domain:

1. **Per-function significance.** After substituting the worst-case `C`, check
   whether the interface term is the **leading** term of the symbolic expression
   or a dominated lower-order one. `f = O(N log N * C + N)`:
   - `C = O(1)` → leading term `N log N`; the interface is *asymptotically
     irrelevant* - report `interface_impact: none`.
   - `C = O(N)` → leading term `N² log N`; report `interface_impact: dominant`,
     naming the worst impl.
2. **Corpus frequency.** Aggregate across functions: how many have an interface
   term that is (a) dominant, (b) present-but-dominated, (c) where the worst impl
   diverges from the median impl (high variance = one bad actor). This answers
   "how often does the worst case impact overall complexity" as a distribution,
   and points at exactly which implementations to optimize.

## Layering (what each component owns)

| Layer | Owns | Language-specific? |
|---|---|---|
| **Fact-mine adapters** (`go.rs`, `ruby.rs`, …) | compute `dispatch_impl`, mark `abstract_type` / `open_dispatch` | **yes** - and *only* here |
| **Fact-mine core** | carry the dispatch-graph facts on the profile; extend the callback-param signal to abstract-typed params | no - pure data |
| **Espalier core** | candidate enumeration, worst-case max, symbolic substitution (reuse callback path), open/closed handling, provenance, impact analysis | no |

The generic extractor never learns "interface" or "trait"; it consumes
`abstract_type`/`dispatch_impl` edges. This satisfies the architecture invariant
(`complexity_fact_extractor_has_no_language_iterator_lexicon`).

## Edge cases

- **Generics / bounded type params** (Go `[T Ordered]`, Rust `T: Trait`, Java
  `<T extends I>`): the constraint *is* an abstract bound; `dispatch_impl` ranges
  over the constraint's satisfying types. Same machinery.
- **Multiple / embedded interfaces**: a method may be required via embedding; the
  satisfaction relation is transitive - adapters emit the closure.
- **No implementations in corpus**: open-world `C`; parametric bound, honest.
- **Self-provided interfaces** (`sort.Interface` is supplied by callers, not by
  `sort`): from `sort`'s document there are zero in-corpus impls → free `C` →
  `Sort = O(N log N * C)`. The concrete cost only materializes at the call site
  that passes `IntSlice` - which is the existing callback substitution.
- **Diamond / overriding**: nearest override wins per branch (already modeled by
  `resolve_inherited_calls`); `dispatch_impl` records the effective target.

## Rollout

1. **Parameterize** (biggest, cheapest win): recognize an abstract-typed
   parameter/receiver as a callback surface; its method calls get free `C`
   domains. This alone flips interface-heavy functions from *incomplete* to
   *complete-parametric* (`sort`, `io`, `container/heap`, `sync` families) with no
   satisfaction data yet.
2. **Satisfaction extraction**: adapters emit `dispatch_impl` (start with Go
   structural + Rust/Java/C# nominal - the highest-signal set).
3. **Worst-case resolution + provenance**: closed-world max with the call-out.
4. **Impact analysis**: significance flag + corpus frequency report.

Phase 1 is independently valuable and reuses #43/#44 almost verbatim; phases 2-4
add the concrete numbers and the worst-case reporting you asked for.

## Success criteria

- `sort.Sort` reports `O(N log N * C_Less)` and is `time_complete` (parametric).
- A call `sort.Sort(IntSlice)` resolves to `O(N log N)` with provenance
  `chosen_worst: IntSlice.Less O(1)`.
- A public interface is never presented with a false closed bound; it carries the
  open-world flag and observed max.
- The report can answer, per function and corpus-wide, whether an interface's
  worst case is asymptotically significant, and name the implementation.
