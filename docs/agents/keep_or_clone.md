# Carrier Polymorphism & `KEEP` Lowering

> **CORRECTION (implemented model).** This doc's early sections treat `COPY` as
> the detach/independent-identity operator. That was wrong and has been
> corrected in the shipped implementation:
> - **`COPY` is a memcpy.** It is illegal on a live `@multiowned`/`@shared`
>   handle at *every* boundary (copying handle bits skips the refcount).
> - **`KEEP` is the carrier-preserving retain** (Rc/Arc retain, plain copy).
> - **`OWN COPY x`** is the sole handle->owned-RawT detach (deref the payload,
>   deep-copy it into a fresh unique owner). Bare `OWN x` is deferred.
> - A retained handle can no longer *silently* fill a plain slot
>   (`RETAINED_NEEDS_OWN_COPY`); crossing the carrier axis is always explicit.
>
> The MONOMORPHIC lowering below shipped as described (Zig-comptime `anytype`,
> reusing `retainOne`/`releaseOne`/`cleanup`). See
> `carrier-first-pass-tracker.md` for the as-built record.

Status: proposed design, 2026-07-22. Companion to
`retained-identity-design.md` (v5). This document settles *how* a
carrier-polymorphic `KEEP`/read/write is lowered, after rejecting both
monomorphization (unbounded code / unpredictable) and value-witness tables
(cache-miss + indirect call on the refcount hot path).

## 0. First-pass scope (2026-07-22 decision)

The **non-monomorphic tag-dispatch default of §3 is deferred** (later, maybe
never). The first pass ships only **explicit, monomorphic** contracts — no new
runtime value shape, no tag threading, no `switch(tag)` in reads/drops. Each
carrier resolves to a concrete instantiation that reuses the *existing*
concrete lowering and its already-proven memory-safety story.

The three first-pass parameter contracts:

| Spelling | Accepts | Fan-out (creating another owner) | Lowering |
|---|---|---|---|
| `TAKES p: UNIQUE T` | **any single-owner `T`** — inline, `T@boxed`, a uniquely-owned list/string buffer, or an Rc/Arc detached to an owned payload via explicit `COPY`. Rejects a *live multi-owned* Rc/Arc handle. | requires **`COPY`** at a non-final fan-out | native to the value's placement (inline or boxed) |
| `TAKES p: MONOMORPHIC T` | `T` / `@multiowned` / `@shared` | requires **`COPY_OR_KEEP`** at a *non-final* fan-out (see §0.2); the final use moves | one specialized variant per carrier actually called (native each) |
| `TAKES p: SHARED T` | **one concrete retained carrier** — sugar for `@multiowned` (Rc) *or* `@shared` (Arc); it does **not** span both (see §0.1) | **none required** — multiple uses auto-retain; `COPY` is disallowed (copying shared identity is meaningless) | native retained handle |

Carrier polymorphism in the first pass is available **only** via
`MONOMORPHIC` — Rust-style specialization made explicit, with its 3^N (or 2^N
via the Rc/Arc GC-shape merge) code-growth acknowledged by the keyword and
reported by the variant-count warning (§4/§6). The unannotated `TAKES p: T`
default and the zero-code-growth tag path (§3) are **not** in the first pass.

### 0.1 UNIQUE and SHARED — two corrections

**`UNIQUE` means *exactly one owner*, not "raw/inline only".** Uniqueness and
placement are **separate** properties. All of these are legal `UNIQUE` values:

- an inline `T`,
- a heap-allocated `T@boxed`,
- a uniquely-owned list or string buffer,
- an Rc/Arc that was detached into an independently-owned payload via an
  explicit `COPY`.

`UNIQUE` rejects only a *live multi-owned* Rc/Arc handle (something whose
identity is currently shared). So `UNIQUE`'s lowering is native to whatever
placement the value has — it does not force by-value/inline.

**`SHARED` must name its concrete carrier.** If `SHARED T` accepted both Rc
and Arc, `retain`/`release` still differ (non-atomic vs atomic) — which would
force monomorphization or runtime dispatch, defeating "simplest first
system." So for the first pass, either write the concrete carrier directly:

```clear
TAKES p: @multiowned T   # concrete Rc
TAKES p: @shared T       # concrete Arc
```

or treat `SHARED T` as **sugar for one of them**, with a *separate*
cross-thread spelling. `SHARED` must **not** silently pick Rc vs Arc from use
context — that makes the cost and thread-safety model non-local. (This
supersedes the earlier "does `SHARED` admit `@multiowned`?" open item, §3c:
in the first pass it resolves to one concrete carrier.) Placement of a plain
value into a retained parameter: **EASY** may auto-box; **DEFAULT/STRICT**
must produce a *fixable error*, because heap allocation has to stay visible.

### 0.2 `MONOMORPHIC` behavior

```clear
FN distribute(TAKES user: MONOMORPHIC User) ->
    cache(COPY_OR_KEEP user);   # non-final fan-out: needs the explicit op
    queue(user);                # final use: moves the remaining value/handle
END
```

The compiler emits only the variants actually called:

- **plain `User`** → `COPY_OR_KEEP` **structurally copies** the payload;
- **`User@multiowned`** → **non-atomic retain**;
- **`User@shared`** → **atomic retain**.

Rules that carry over from v5 (they are not weakened by monomorphism):

- `COPY_OR_KEEP` is required **only at a non-final fan-out** — where the value
  becomes two owners — *not* merely because the parameter is `MONOMORPHIC`.
  The final consuming use just moves the remaining value or handle.
- A **plain** instantiation must **fail** if `User` has no valid structural
  `CopyPlan` (nothing to copy) — the copyable-payload requirement (rule 7/8)
  applies per specialized variant.

The §3 tag-dispatch design remains the recorded target for *if/when* the
i-cache cost of `MONOMORPHIC` proves painful in practice — see §7c for the
effort comparison. Everything below (§1–§8) describes the full design; §0 is
the subset we build first.

> Naming note: this section uses `COPY_OR_KEEP` for the carrier-polymorphic
> fan-out on a `MONOMORPHIC` parameter (copy a plain payload, retain a
> handle). The v5 implementation currently spells the unified fan-out `KEEP`
> (the `COPY_OR_CLONE`→`KEEP` rename). Reconciling the spelling — a single
> `KEEP` vs. `KEEP` (concrete-carrier retain) plus `COPY_OR_KEEP`
> (carrier-polymorphic) — is a naming decision to settle before building
> `MONOMORPHIC`.

## 1. The problem

A `TAKES` parameter is **carrier-polymorphic** when the same function is
called with the same parameter carried as a plain value, `@multiowned` (Rc),
and/or `@shared` (Arc), and the body performs a **carrier-dependent
operation** on it:

- `KEEP` (fan-out): plain → payload copy, Rc → non-atomic retain, Arc →
  atomic retain;
- **drop** as final owner: plain → trivial/destructor, Rc → non-atomic
  release, Arc → atomic release;
- **field read/write**: plain → direct (native), Rc/Arc → through the handle.

One function body cannot emit different machine code per carrier without
getting the carrier from *somewhere* — compile time (specialize) or run time
(a tag). There is no third channel; this is physics, not a missing trick.

## 2. The physical trilemma (pick two)

| | zero-cost plain | bounded code | general N-carrier polymorphism |
|---|---|---|---|
| **Rust** (monomorphize) | yes | **no — 3^N, non-local, unbounded** | yes |
| **Swift** (value-witness table) | **no — uniform repr + indirect call** | yes | yes |
| **Restrict** (commit the carrier) | yes | yes | **no** |

CLEAR's priority order is **predictability > ergonomics > safety >
throughput**, and explicitly: *constant* increases over Rust are acceptable,
*unpredictable* ones are not. Monomorphization is the unpredictable increase
(a function's real cost depends on the whole instantiation graph; worst case
is a code-size/compile-time cliff). So CLEAR does **not** monomorphize by
default. Swift's VWT is also rejected: it puts a memory load + indirect call
on the hottest operation (refcount inc/dec), and it is unnecessary here
because CLEAR's carrier axis is a **closed set of three**, not Swift's open
world of arbitrary types.

## 3. The design: closed-carrier tag dispatch, no auto-specialization

Because carrier is a first-class, closed axis in CLEAR (Types are separate
from Capabilities), a carrier-polymorphic parameter travels as a **tagged
value** — a 2-bit carrier discriminant plus the payload, with the tag packed
into the Rc/Arc pointer's spare low bits (aligned) and the plain arm carried
inline:

```zig
CarrierPoly(T) = struct {
  tag: enum(u2){ plain, rc, arc },
  body: union { inl: T, hnd: *RcBox(T) },   // plain inline vs Rc/Arc handle
};
```

Every carrier-dependent operation lowers to **one predicted `switch(tag)`**:

```zig
// read  y = u.f
switch (u.tag) { .plain => u.body.inl.f, .rc,.arc => u.body.hnd.data.f };
// write u.f = x  (mutable-safe; the carrier is invariant under field mutation)
switch (u.tag) { .plain => u.body.inl.f = x, .rc,.arc => u.body.hnd.data.f = x };
// KEEP u
switch (u.tag) { .plain => copyPayload(u.body.inl),
                 .rc => rcRetain(u.body.hnd), .arc => arcRetain(u.body.hnd) };
// drop u (final owner)
switch (u.tag) { .plain => {}, .rc => rcRelease(u.body.hnd), .arc => arcRelease(u.body.hnd) };
```

Key properties:

- **Plain stays register-resident.** The plain arm reads/writes the inline
  struct in registers — no load, no indirection. The indirection lives only
  in the Rc/Arc arm, which already pays it today.
- **The only added cost is a predicted branch.** The tag is stable per call
  site, so mispredicts are effectively zero. The branch is a genuine control
  dependency (the Rc arm dereferences a pointer that is invalid in the plain
  arm — it cannot be a `cmov`/select).
- **No memory added to Rc/Arc, no heap.** The tag is packed into pointer
  low bits (Rc/Arc) or a spare register (plain).
- **The tag propagates but is free to carry.** Passing a tagged value to a
  callee is a register move; cost is paid only where the callee actually
  keeps/drops/accesses it.
- **No auto-specialization, ever.** We do NOT rely on loop-unswitching,
  recursive specialization, or call-graph cloning. Those are optimizer
  heuristics whose firing is unpredictable and whose worst case is the very
  3^N cliff we rejected. The cost model is therefore legible from the source:
  **one predicted branch per carrier-dependent operation, always.** (LLVM
  may still unswitch a small loop as a free bonus, but correctness and the
  promised cost never depend on it.)

Recursion and cross-function flow are **non-events** under this rule: each
recursion level / each callee simply does its own predicted branch where it
touches the value. There is no detection pass, no cycle analysis, no
specialization spreading — the compiler side is mechanical lowering.

## 4. The three parameter annotations

| Spelling | Meaning | Codegen | Accepts |
|---|---|---|---|
| `TAKES u: User` (default) | carrier-polymorphic | tag dispatch, 1 predicted branch/op | plain, Rc, Arc |
| `TAKES u: @multiowned User` (pin) | commit to one carrier | native, zero tag | that carrier only |
| `TAKES u: MONOMORPHIC User` | keep polymorphism, force native | Rust-style specialization per carrier tuple actually called | plain, Rc, Arc |

- **Default** is write-once, ergonomic, predictable; pay a predicted branch
  where the carrier is used.
- **Pin** removes the branch by giving up polymorphism — a one-keyword edit
  to the *same* function (never a second function), valid when the function
  genuinely needs only one carrier.
- **`MONOMORPHIC`** is the explicit opt-in to Rust's model: it keeps the
  function callable with any carrier *and* emits native, branch-free code —
  by generating a specialized variant per carrier tuple that is actually
  called. The keyword makes the **combinatoric-explosion possibility
  visible and searchable**: a function with N `MONOMORPHIC` params can
  generate up to 3^N variants. The compiler counts emitted variants and
  **warns** past a threshold (e.g. `MONOMORPHIC 'foo' generated 27 variants
  across 3 carrier-polymorphic parameters; consider pinning a carrier`), so
  the cliff is never silent and is always the developer's informed choice.

## 4b. Generalization: non-monomorphic by default, `MONOMORPHIC` as the opt-in — for carrier *and* type generics

`MONOMORPHIC` is not a carrier-specific hack; it is CLEAR's universal
**"specialize this dimension"** marker, and it inverts Rust's default:

- **Rust:** every generic is monomorphized, no opt-out → zero-cost, but
  unbounded/unpredictable code (the 3^N cliff, non-local i-cache).
- **Go:** generics are never fully monomorphized (GC-shape stencils +
  dictionaries) → bounded code, but a permanent dictionary-dispatch cost and
  *no way* to recover zero-cost when you need it.
- **CLEAR:** non-monomorphic **by default** (predictable, bounded), with an
  **explicit per-parameter opt-in** to monomorphization — the control Go
  lacks and the predictability Rust lacks.

Same marker, both axes:

```clear
FN foo<T>(x: T) -> ... END                 # type-generic, non-mono by default
FN foo<T: MONOMORPHIC>(x: T) -> ... END     # opt into specialization per T
FN bar(TAKES u: User) -> ... END            # carrier-polymorphic, tag by default
FN bar(TAKES u: MONOMORPHIC User) -> ... END # opt into specialization per carrier
```

**When to reach for `MONOMORPHIC`** — exactly the developer judgment the user
named: the function is **small** (code duplication is cheap), the number of
instantiations is **small/known** (no explosion), or performance is
**dire** and the zero-cost abstraction is worth the code. The compiler
assists both directions: it **warns** when `MONOMORPHIC` generates more
variants than a threshold (the explosion is never silent), and it can
**suggest** `MONOMORPHIC` when it detects a hot generic/carrier access in a
loop (§6).

**This resolves the type-generic composition open item (§7).** Because carrier
polymorphism and type genericity share one policy — non-mono default +
`MONOMORPHIC` opt-in — they compose without a special case:
`foo<T>(u: T@carrier)` is simply non-mono on *both* dimensions (a dictionary
for the unknown payload `T`, a tag for the carrier), and `MONOMORPHIC` on
either axis specializes that axis.

**Honest asymmetry in the default's cost across the two axes.** The two
non-mono defaults are not equally cheap:

- **Carrier axis** (closed set of 3, known payload): the default is a **2-bit
  tag + predicted branch** — no dictionary, no indirect call. Cheap.
- **Type axis** (open set, unknown payload): the default needs **Go-style
  dictionaries** — a hidden per-instantiation table, and method/size/alloc
  ops on `T` go through a dictionary load + indirect call (Go's known
  generics overhead; a possible cache-miss + a devirtualization barrier).
  Heavier than the carrier tag.

So `MONOMORPHIC` earns its keep *more* on the type axis (where the default
dictionary cost is real) than on the carrier axis (where the default is
already just a branch). The combinatorics of an opt-in `MONOMORPHIC` are the
**product** of the instantiation counts across all `MONOMORPHIC` parameters
(carrier: ≤3 per param, or ≤2 with the Rc/Arc GC-shape merge; type: the
number of distinct `T`s actually used) — which is exactly what the
variant-count warning reports.

## 5. Cost analysis

These are **reasoned estimates pending the Rust-corpus measurement** (see
§7). They should be replaced with measured numbers.

### 5.1 What percentage of functions is impacted at all?

A function pays *anything* only if it (a) takes an **owned** value (not a
borrow), (b) that param is **genuinely** called with more than one carrier,
and (c) it performs a carrier-dependent op (keep / final-owner drop /
field access). These compound:

- Borrows dominate parameter lists (reads use `&T`); owned params are a
  minority — estimate **~15-30%** of functions have an owned param.
- Of those, genuinely carrier-polymorphic (called with >1 carrier across
  sites) is rare, because codebases standardize a type's carrier — estimate
  **~5-15%** of owned-param functions.
- Net functions paying *any* branch: **~1-4%** of all functions (estimate).
- Most of those are forward/keep-only (no field reads) → they pay only a
  handful of keep/drop branches, not per-access read cost.
- Functions paying the **read/write** cost (field access in a polymorphic
  body): **< 1%** (estimate) — because reading is normally done via borrows.
- Functions paying the **hot-loop** read cost (many accesses/iteration over
  an unpinned polymorphic owned param): **< 0.1%** (estimate) — a fraction
  of a fraction, and exactly the case the compiler flags (§6).

### 5.2 Average added cost, where it adds any

- **Keep/drop:** one predicted branch per site, a handful of sites. ~0.5-1
  cycle each; sub-nanosecond total. Unmeasurable in practice.
- **Field access:** one predicted branch per access, plain register-resident
  (no load). A typical function touching a field a few times adds a few
  predicted branches total — effectively unmeasurable.
- The added cost is a **branch slot**, never a cache miss or an added load;
  the value stays in registers on the plain path.

### 5.3 Absolute worst case vs Rust

The pathological case is a **tight, branch-throughput-bound hot loop** doing
many reads/writes of an **unpinned, non-`MONOMORPHIC`** carrier-polymorphic
owned param:

```
FOR i IN (0 ..< N) DO total = total + p.field; END   # 1 polymorphic read/iter
```

- **Rust (monomorphized):** `load + add` ≈ 1-2 cyc/iter (the plain case is
  often a single register add).
- **CLEAR default (tag):** `+ 1 predicted branch/iter` (plain field is
  register-resident, so *no* extra load) ≈ 2-3 cyc/iter on this micro-loop.

So the **absolute worst case is roughly 1.5-2x on a micro-loop that does
essentially nothing but one polymorphic access per iteration**. For `K`
polymorphic accesses per iteration the ceiling is `~K` predicted branches,
bounded by branch throughput (~2 taken branches/cycle) → up to ~`K/2`
added cycles/iteration in the fully branch-bound limit. A loop doing any real
work per iteration (≥ ~10 cycles) hides the branches entirely → ~0 overhead.

Two mitigations make even this bounded worst case a non-issue in practice:

1. It is exactly the case the compiler detects and flags (§6); the developer
   pins or `MONOMORPHIC`s it → **identical to Rust, zero overhead.**
2. Unlike Rust, the default keeps **one code body** — no unbounded i-cache
   pressure from monomorphization, so aggregate performance stays *more*
   predictable even where a single micro-loop is slower.

There is **no unbounded worst case** in the default: the cost is always one
predicted branch per operation, period. The only unbounded thing in the
system is `MONOMORPHIC` (3^N), which is explicit, named, and warned.

## 6. Compiler hazard detection

The hazard is cheaply detectable at MIR level — no new analysis machinery:

- A carrier-polymorphic (unpinned, non-`MONOMORPHIC`) parameter that is
  **read or written inside a loop body** (especially an inner/hot loop), or
  accessed many times, is the only case that can matter.
- On detection, emit an advisory diagnostic (not an error), e.g.:

  ```
  [perf] 'accumulate' reads carrier-polymorphic parameter 'u' inside a loop
  (N accesses/iteration). Each access is a predicted branch. To make this
  native:
    - TAKES u: @multiowned User   # commit to one carrier (rejects others)
    - TAKES u: MONOMORPHIC User    # keep all carriers, specialize per carrier
                                   #   (may generate up to 3^params variants)
  ```

- If the developer chooses `MONOMORPHIC`, the compiler counts emitted
  variants and warns past a threshold so the combinatoric explosion is never
  silent.

This gives the intended workflow: **write once (predictable branch), let the
compiler point at the rare hot spot, opt into native explicitly** — never an
optimizer silently deciding your performance.

## 7. Preconditions, scope, and open items

- **Holds cleanly when:** the payload type is *known*, the carrier set is
  *closed* (plain/Rc/Arc), and the carrier is *visible at the call boundary*
  (whole-program or the caller sees it). Then the tag is a 2-bit register
  value and concrete sites fold to native.
- **Open — type-generic composition:** if carrier polymorphism must compose
  with *unknown-payload* generics (`foo<T>(u: T@carrier)` where `T` is
  abstract) or cross an *opaque, separately-shipped ABI* where the payload
  type is unknown, then the *payload* dimension inherits Swift's harder
  problem (you'd need `T`'s own copy/destroy). The *carrier* dimension stays
  a clean tag regardless. Decide whether carrier-poly must compose with
  type-generics before relying on the easy path.
- **Open — empirical validation:** the §5 percentages are reasoned
  estimates. Measure on representative Rust crates (owned-vs-borrow ratio,
  field-access-on-owned-params, same-type-both-carriers, reads-in-loops) and
  replace the estimates with data.
- **`SHARED` carrier (resolved for the first pass, §0.1):** `SHARED` names one
  concrete carrier (sugar for `@multiowned` *or* `@shared`) and never spans
  both silently. A carrier-polymorphic-retained parameter (accepting *either*
  Rc or Arc) is only meaningful under `MONOMORPHIC` (specialize) or the
  deferred tag path — not under `SHARED`. A separate cross-thread spelling
  distinguishes single-thread Rc from cross-thread Arc.

## 7b. Evaluation: Go-style generics (GC-shape stenciling + dictionaries)

Go 1.18+ does not fully monomorphize. It generates **one stencil per GC
shape** of the type arguments — and *all pointer types share one shape* — and
resolves type-specific operations through a per-instantiation **dictionary**
passed as a hidden argument. Value types (int, structs) get their own
stencils; pointer types collapse to one.

This maps onto CLEAR's carriers with a striking coincidence: **`Rc(T)` and
`Arc(T)` are both pointers to control blocks, so they share one GC shape.**
Applying Go's model:

- **Rc and Arc collapse into ONE pointer stencil.** Inside it, field
  reads/writes are `hnd.data.f` — **native, uniform, and branch-free** for
  both Rc and Arc. This is the property the tag default cannot give reads.
- **plain `T` is a value shape → its own stencil**, fully native by value.
- The only Rc-vs-Arc difference is retain/release atomicity. In Go that lives
  in the dictionary (a load + indirect call); in CLEAR it **degenerates to a
  single atomicity bit** — no real dictionary, no indirect call — checked
  only at keep/drop.

So Go's model gives CLEAR **native reads with no per-access branch**, merges
Rc/Arc for free, and needs only a 1-bit flag where Go needs a dictionary
(cheaper than Go, because CLEAR's "type-specific op" set is just
retain/release).

**But it does not escape the exponential.** Stenciling N carrier-polymorphic
params over {value-shape, pointer-shape} is **2^N stencils** — better base
than monomorphization's 3^N (Rc/Arc merged), but still exponential in N,
still non-local, still unbounded code. As the user notes, incremental builds
hide the *compile-time* cost, but the **i-cache / binary-size cost is real
and is exactly what CLEAR's predictability priority rejects as a default.**
`foo(plain User, Arc Config, Rc Session)` called across the full carrier
matrix is up to 2^3 = 8 stencils.

**Conclusion — Go's model is the right *implementation of `MONOMORPHIC`*, not
a replacement for the tag default.**

- **Default stays tag dispatch** (§3): one body, one predicted read branch,
  bounded i-cache — the predictable floor.
- **`MONOMORPHIC` should be implemented as Go-style GC-shape stenciling**, not
  naïve 3^N monomorphization: merge Rc/Arc into a shared pointer stencil with
  a 1-bit atomicity flag, so `MONOMORPHIC` costs **2^N** stencils, not 3^N,
  and gets native reads. The variant-count warning (§4) counts GC-shape
  stencils, so the ceiling the developer is warned about is 2^N.

One property worth noting in Go's favor: GC-shape stenciling is
**deterministic** (the compiler always stencils per shape — not an optimizer
heuristic like LLVM loop-unswitching), so it is a *predictable* way to buy
native reads. The choice for the default is therefore a clean, legible
trade: **tag = 1x code + one read branch** vs **Go-stencil = 2^N code +
native reads**, both deterministic. CLEAR's i-cache-and-predictability
priority picks the 1x tag by default and offers the 2^N stencil explicitly
via `MONOMORPHIC`.

| approach | code size | reads | Rc/Arc | atomicity dispatch | predictable? |
|---|---|---|---|---|---|
| monomorphize (Rust) | 3^N | native | separate | none (specialized) | no (unbounded, non-local) |
| Go GC-shape stencil | 2^N | native | merged (1 stencil) | dictionary / 1-bit flag | deterministic but unbounded code |
| **tag dispatch (CLEAR default)** | **1x** | 1 predicted branch/access | merged (1 arm) | 1-bit branch at keep/drop | **yes, local + bounded** |
| Swift VWT | 1x | uniform indirect load | merged | indirect call (cache-miss risk) | bounded but slow hot path |

## 7c. Implementation effort & sequencing

Everything built for retained-identity v5 so far is the **front half**
(deciding *which* ownership op) — annotator, static rules, the
`OwnershipEdgePlanner`, `carrier_op` stamping, `COPY`/`KEEP`/`SHARED`
semantics, concrete-carrier lowering, tests. That work is **reusable
foundation, not throwaway**: the `carrier_op` stamps are precisely the input
this lowering consumes. It was broad but *contained* — a wrong annotator rule
is a compile error, not a memory bug.

Tag dispatch is the **back half**: a new runtime value shape woven through the
memory-safety-critical MIR/emit/checker/runtime layers. A wrong drop branch or
a mis-threaded tag is a UAF or a leak, so it is slower per unit (every step
gated by leak detection, MIRChecker LEAK/ORPHAN invariants, and Loom/Hammer on
the atomic path).

New work, ordered by size × risk:

| Piece | Size | Risk | Notes |
|---|---|---|---|
| Tagged-value representation + ABI + tag threading | Large | High | A new value shape through MIR + emit (like a 2nd `@multiowned` shape); pointer-tagging; hidden tag arg through calls |
| Lower read/write/keep/**drop** to `switch(tag)` | Med-Large | High | Carrier-dependent **drop** must satisfy MIRChecker LEAK/ORPHAN |
| Zig runtime helpers + Rc/Arc layout (+ atomicity bit if merged) | Medium | High | Atomics → Loom test; cleanup → leak/ASan gates |
| `pin` (`@multiowned`/`@shared`/`UNIQUE`) | Small | Low | Reuses the concrete-capability path; parsing already exists |
| `MONOMORPHIC` (specialization + GC-shape merge + variant-count warning) | Large | Medium | A whole feature, but **deferrable** — the tag default works without it |

Estimate:

- **Tag default, end-to-end and memory-safe: ≈ 2–3× the v5 work so far**, and
  slower per unit because it is the highest-risk layer. This is the
  "carrier specialization" crux the burn-down has been failing closed on all
  along — the single largest unit of the feature.
- **`MONOMORPHIC`: a further comparable chunk**, deferrable.
- **`pin`: nearly free** — the cheapest path to a runnable end-to-end slice.

Recommended milestones:

1. **`pin`-only slice** — carrier-polymorphic *declared*, but a `pin`
   (`@multiowned`/etc.) is *required to run*; the unpinned case keeps failing
   closed with the current boundary message. Gives a runnable end-to-end path
   cheaply and exercises the annotator→concrete-lowering seam.
2. **Tag default** — the tagged representation, `switch(tag)` for
   read/write/keep/drop, tag threading, and MIRChecker/leak integration.
   Built incrementally under the 0-leak gate; surface if it fans out (this is
   where representation-woven-through-cleanup surprises hide).
3. **`MONOMORPHIC`** — Go-style GC-shape specialization (2^N via the Rc/Arc
   merge) with the variant-count warning. Pure optimization; ship last.

Net (full tag design): building it is a **new, larger, higher-stakes body of
work than the entire burn-down to date**.

### 7c.1 First-pass effort (§0) vs the deferred tag/icache optimization (§3)

The §0 first pass is dramatically cheaper because it introduces **no new
runtime representation** — `MONOMORPHIC` specializes to concrete carriers, and
each variant is just the existing concrete lowering.

- **`UNIQUE`:** mostly already done — parsing (V5-1b), `COPY`-on-`UNIQUE`
  (V5-3b), and the rule that `KEEP` on a `UNIQUE` param is an error (V5-2c) all
  land. Small remainder.
- **`SHARED`:** already verified working (V5-3c: rejects plain, accepts a
  retained family, auto-retains multiple uses). ~zero remainder (modulo the
  open `@multiowned`-into-`SHARED` axis decision).
- **`MONOMORPHIC`:** the one genuinely new piece — and it can reuse CLEAR's
  **existing `@hasField` comptime pattern** (the same one that unwraps
  `@shared:locked` at `WITH`): emit the param as Zig `anytype`, resolve
  reads/`KEEP`/drop with comptime `@hasField` (which folds to native per
  instantiation — no runtime branch), and let **Zig monomorphize per call
  carrier**. Plus the plain-carrier `KEEP` lowering (reuse `COPY`'s deep-copy)
  and a variant-count warning. Moderate size, **low risk** (no new shape, no
  tag threading, no cleanup-checker changes — the existing concrete
  memory-safety story carries it).

**Estimate:**

- **First pass (§0) ≈ 0.5–1× the v5 work so far, LOW risk.** It delivers a
  *working, end-to-end* carrier-polymorphic `KEEP` (via `MONOMORPHIC`), plus
  `UNIQUE` and `SHARED`, without touching the memory-safety-critical
  representation/cleanup layers.
- **Deferred tag/icache optimization (§3) ≈ 2–3× the v5 work so far, HIGH
  risk** (the new value shape through MIR/emit/checker/runtime).
- So the **first pass is roughly ¼–½ the size of the tag optimization, at a
  fraction of the risk**, and it removes the crux the burn-down has been
  failing closed on. The tag path becomes a *later, optional* i-cache
  optimization — pursued only if `MONOMORPHIC`'s code growth actually hurts in
  real programs (which the pending Rust-corpus study, §7, would quantify).

## 8. Summary

- Default carrier-polymorphic lowering = **closed-carrier tag dispatch**: one
  predicted branch per carrier-dependent op, plain register-resident,
  indirection confined to the Rc/Arc arm, no heap, no Rc/Arc memory growth,
  **no auto-specialization** → fully predictable and legible from source.
- **Pin** (`@multiowned`/`@shared`/`UNIQUE`) removes the branch by committing
  the carrier — one keyword, same function.
- **`MONOMORPHIC`** is the explicit, warned opt-in to Rust-style native
  polymorphism with acknowledged 3^N potential.
- Impact estimate: ~1-4% of functions pay any branch; < 1% pay a read/write
  branch; < 0.1% hit the hot-loop case. Average added cost: a few predicted
  branches (unmeasurable). Absolute worst case vs Rust: ~1.5-2x on a
  branch-bound micro-loop, bounded, detected, and removable to zero by one
  keyword. No unbounded worst case except the explicitly-opted-in
  `MONOMORPHIC`.
