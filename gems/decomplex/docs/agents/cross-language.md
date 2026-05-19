# decomplex - cross-language defect coverage

## Scope of this document

decomplex parses Ruby (`RubyVM::AbstractSyntaxTree`); it analyzes the
Ruby *source of a compiler*, not Rust/Go/C. This doc is NOT "decomplex
runs on those languages." It answers a sharper question: **of the
defect CLASSES decomplex's detectors target, which survive into a
statically typed language, and which does a particular type system
structurally remove?** It is the argument for why decomplex's thesis
is not made redundant by "just use a better-typed language," and a map
of where the residual risk moves when you do.

## Thesis

decomplex's core - re-derived decisions, drifted state, decision
scatter, copy-paste divergence - is a **design/duplication** axis,
orthogonal to types. No type system, including Rust's or Haskell's,
addresses "the same guard tuple is recomputed in 14 methods" or "this
predicate was reinvented inline." Those exist identically in every
language. A second, smaller family of decomplex findings has a
*sub-case* that ownership, sum types, `Option`, or exhaustive `match`
make unrepresentable - that is the only place a type system erodes the
target surface, and only in specific languages.

## Per-detector portability matrix

`Y` = the defect class exists in full. `Y*` = exists, but a sub-case
is removed by that language's type discipline (see Mechanisms).
Dynamic = Ruby / Python / Lua.

| detector | Dynamic | C | Go | Rust |
|---|---|---|---|---|
| Missing Abstractions | Y | Y | Y | Y |
| Reification Misses | Y | Y | Y | Y |
| Exact / Semantic Predicate Aliases | Y | Y | Y | Y |
| Type-3 Clone (missed rename) | Y | Y | Y (a few more pass than C/Rust) | Y (strong nominal typing catches the cross-type fraction; same-type renames still pass) |
| Neglected Conditions / Path Conditions | Y | Y | Y | Y* (exhaustiveness slice removed) |
| Broken Protocols | Y | Y | Y* (memory pair only, via GC) | Y* (resource-pair slice removed, via RAII/Drop) |
| Neglected Updates (co-written state) | Y | Y | Y | Y* (removed when modeled as one sum type) |
| Derived-State Staleness | Y | Y | Y | Y* (aliased-derived slice removed by borrow checker; owned-copy slice remains) |
| Decision Pressure | Y | Y | Y | Y* (nil-guard slice removed by `Option`; type-tag slice removed by sum types/generics) |
| False Simplicity - hidden mutation | Y | Y | Y | **N** (borrow checker: `&mut` exclusivity) |
| False Simplicity - hidden IO / global / effects | Y | Y | Y | Y (no effect system in any of these; only Haskell-class removes it) |
| False Simplicity - dynamic dispatch / metaprogramming / monkeypatch | Y (the big bucket) | reduced (preprocessor instead) | reduced (`interface{}`/reflect instead) | reduced (hygienic macros; monkeypatch impossible) |

## Mechanisms: what Rust removes that C and Go do not

Six sub-cases. Each is a specific Rust guarantee applied to a
decomplex defect class. C removes none of them. Go removes only the
first, and only its memory slice.

1. **Broken Protocols, resource-pair slice** (alloc/free, lock/unlock,
   open/close, acquire/release). Rust: ownership + `Drop`/RAII makes
   the release automatic and the unpaired state unrepresentable. C:
   fully manual - this is *the* C bug. Go: GC removes only the
   *memory* alloc/free pair; `sync.Mutex` Lock/Unlock, `file.Close`,
   etc. are still manual and `defer` is an unenforced convention, so
   the non-memory pairing bug is common in Go.
2. **False Simplicity, hidden aliased mutation.** Rust's flagship
   guarantee: `&mut` exclusivity makes "value mutated through another
   reference you did not see" a compile error. C: pointer aliasing,
   rampant. Go: shared refs / data races, rampant.
3. **Decision Pressure, nil/null-guard slice.** Rust: no null;
   `Option<T>` is destructured once, not defended against everywhere.
   C: null pointers - maximum pressure. Go: `nil` pervades interface,
   map, pointer, slice - high and notorious.
4. **Neglected Conditions, exhaustiveness slice.** A dispatch over a
   closed set missing a case. Rust: `match` on an enum is
   compiler-forced exhaustive. C: `switch` is not exhaustive. Go: no
   sum types, `switch` not exhaustive-checked.
5. **Neglected Updates, coupled-state slice.** Two fields that must
   move together. Rust: model the combined state as one sum type and
   the desync becomes unrepresentable. C: no sum types (manual tagged
   union - the desync thrives). Go: no sum types/enums (two fields,
   desync persists).
6. **Derived-State Staleness, aliased-derived slice.** `b` is a
   reference into `a`; `a` mutated under it. Rust: borrow checker
   rejects mutating `a` while `b` borrows it. C/Go: not caught. The
   *owned-copy* slice (`b = expensive(a)`, `a` later changes) remains
   in Rust too.

## The Go fallacy (call this out explicitly)

Go is typed and garbage-collected, so it is intuitively assumed to be
"Rust-safe." It is not, for decomplex's axis. GC removes exactly one
sub-case: the memory alloc/free protocol. Go has no sum types, no
exhaustiveness checking, `nil` everywhere, `interface{}` + reflection,
and `defer` as unenforced convention. So Go retains essentially the
entire C-side column that Rust eliminates. On decomplex's defect
surface, **Go behaves much closer to C than to Rust**; "modern typed
language" buys almost nothing here beyond memory reclamation.

## The dynamic-language superset (Ruby / Python / Lua)

Dynamic languages have *every* universal defect class above, plus they
*add* the False Simplicity dispatch/metaprogramming surface that the
typed languages largely lack: `send`/`__send__`/`getattr`, open
classes / monkeypatch, `method_missing`, `define_method`,
`class_eval`, runtime reflection. This is strictly additive risk - the
reason False Simplicity is "the big Ruby bucket." It is not shared by
C/Go/Rust (C's preprocessor and Go's `interface{}`/reflect are
narrower, typed-adjacent analogues; monkeypatch is impossible in all
three by coherence/closed-class rules). Decision Pressure is also at
its maximum here: with no static contract at all, every boundary is a
loosely-typed contract driving scattered defensive `is_a?`/`nil?`
checks.

## Fat unions / product-vs-sum (the union-complexity question)

A "fat union" - variants sharing most of their payload, small genuine
variation - is Missing Abstractions for data shape (see the
fat-union analysis). Type systems vary in how much they *mitigate*
(never fully remove) it:

- **Rust / ML / Swift**: sum types are ergonomic AND exhaustiveness is
  enforced, so the `struct{common; kind: enum{variant}}` decomposition
  is the natural idiom and a forgotten variant is a compile error. The
  fat-union *anti-pattern* still occurs (nothing forces the
  decomposition), but the correct shape is cheap and the desync class
  it generates (Neglected Updates) is removable (Mechanism 5).
- **C**: tagged unions are manual and unchecked - the worst case; the
  fat union and its desync thrive.
- **Go**: no sum types, so the pattern manifests as `interface{}` +
  type switch, or `struct{ kind int; ...all fields... }` - the fat
  shape is effectively the *only* shape; full risk.
- **Dynamic**: manifests as a class hierarchy or a `:kind`-tagged
  hash; recovery is value-object extraction = nil-kill's owned
  territory, not decomplex's (decomplex measures+ranks the use-site
  cohesion evidence and routes the refactor out, per the design
  boundary).

## Honest caveats

- **Rust enables, it does not force.** Every Rust-eliminated sub-case
  assumes idiomatic Rust (sum types, ownership, `Option`, exhaustive
  `match`). Write two coupled `mut` fields and Neglected Updates
  returns in Rust. The distinction from C/Go is that C/Go *cannot
  express* the safe form (no sum types; null/nil baked in), so there
  the defect is structural, not stylistic.
- **The duplication/design core is universal.** Missing Abstractions,
  Reification, Predicate Aliases, Type-3 Clone, and the
  conjunction/protocol forms of the consistency detectors are fully
  present in Rust and Haskell. This is the headline: decomplex's
  central value targets an axis no type system covers.
- **Effects are universal.** None of Rust/C/Go track IO/global/effect
  in types; the hidden-effect slice of False Simplicity is identical
  across all of them (only Haskell-class effect typing removes it).
- **decomplex is not ported.** This is a defect-class portability map,
  not a feature claim. The detectors run on Ruby AST today.
