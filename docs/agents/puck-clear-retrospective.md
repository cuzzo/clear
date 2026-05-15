# Puck-on-CLEAR — Retrospective

A short postmortem on the CLEAR compiler bugs surfaced while porting
`v10/vm.c` to `examples/puck/vm.cht`. The four reproducers in
[`transpile-tests/known-failing/`](../../transpile-tests/known-failing/)
all came out of writing roughly 300 lines of straightforward stack-machine
interpreter code — that is, the bug-discovery rate was about one per
75 lines of new CLEAR. The question this document tries to answer is:
**how can bugs of this severity still be present at this stage of
CLEAR's development, and what does the fact that we missed them tell us
about the test surface?**

## TL;DR

Three structural gaps, in order of severity:

1. **The test corpus is mostly happy-path examples.** Existing
   `transpile-tests/*.cht` files demonstrate that a working program
   compiles and runs. The bugs we hit are not "what compiles" failures
   but "what compiles incorrectly" or "what compiles awkwardly" failures
   — adversarial shapes that no existing test was probing.
2. **The MIR ownership invariants are enforced but not synthesised.**
   `[FRAME_NO_REWIND]` exists as a checker, but the corresponding
   `restoreLoopMark` *insertion* in escape analysis is incomplete.
   Verification without synthesis means user code that is *correct in
   spirit* is rejected with a low-level error message.
3. **Hoisting and effect inference each have well-formed unit
   behaviours that compose badly.** Each transformation is locally
   correct; their interaction in the presence of `OR fallback` and
   nested heap shapes is what produces incorrect Zig and surprising
   fallibility cascades.

The good news: every single one of these bugs reproduces in ~10 lines of
isolated CLEAR. None of them needed the VM scaffolding to surface. They
were waiting for someone to write a port from a non-CLEAR memory model.

## What the bugs are

For full details and reproducers, see
[`puck-clear-bugs.md`](puck-clear-bugs.md). The four that warrant
discussion here:

- **Bug #1** (hoisting, `if (X OR "") != "lit"`): codegen emits the
  lifted temp's `const` declaration **inside** the `if` body, after the
  expression that uses it. Zig refuses. **Severity: high** — silently
  corrupts every "if-with-defaulted-fallible-condition" in a CLEAR
  program. We hit it on the very first `if` of the very first loader I
  wrote.

- **Bug #2** (`FRAME_NO_REWIND` on plain `WHILE` loops with a local
  heap-shaped temporary): the MIR check fires correctly, but the
  pipeline that should have inserted the per-iteration rewind defer
  never ran. **Severity: high** — every non-trivial loop hits it, and
  the only escape is hoisting every transient out of the loop body.

- **Bug #3 / #8** (`OR fallback` doesn't reset `can_fail` in effect
  inference): a function whose only "fallible" operation is consumed by
  `OR ""` is still marked fallible, forcing the whole call chain to
  declare `!T`. **Severity: medium** — silently *enlarges the signature*
  of half the file.

- **Bug #9** (nested `@list` storage clobbered across outer-loop
  iterations): `procs[0].codes` returns garbage memory after the second
  outer-loop iteration completes. **Severity: critical** — produces
  silently wrong output. This was the one that took the longest to find
  because everything looked right *at construction time*; we only saw
  the corruption when the same procedure was read later.

## How did these reach this stage?

### Cause 1 — the test corpus only proves what we already wrote

`transpile-tests/` has ~456 entries, all of which exercise a feature
that *worked at the time it was added*. The structure of those tests is:

> Write a `.cht` file that compiles and runs.
> If it compiles and prints the right thing, we ship.

Every entry in the corpus was authored *after* the corresponding feature
worked. None of them are adversarial. There is no class of test that
asks "did you remember to make this work when used together with that?"

The bugs we hit are interaction bugs:

- Bug #1 needs: fallible call + OR fallback + comparison + IF condition
  (four features, each fine individually).
- Bug #9 needs: STRUCT with @list field + outer @list + WHILE loop +
  MUTABLE-declared inner @list (four features, each fine individually).

The compiler has unit-test coverage for each of those features
independently. **The interaction surface is untested.** No fuzzer, no
property test, no quickcheck-style "two random `transpile-tests/`
patterns concatenated" runner.

This is the dominant cause. The other two below are downstream of it —
they're things the corpus didn't notice because nobody wrote a `.cht` in
that shape until now.

### Cause 2 — MIR verifies but doesn't always synthesise

CLAUDE.md is explicit about the MIR pipeline's three roles:

> **Role 1 — MIRLowering: Makes ALL decisions.**
> **Role 2 — MIRChecker: Verifies the decisions, nothing else.**
> **Role 3 — MIREmitter: Pure template engine, zero decisions.**

Bug #2 is precisely a Role 1 failure: the lowering didn't insert the
`MIR::FrameSave` / `MIR::FrameRestore` for a `WHILE` body whose
allocation never escapes the iteration. The checker (Role 2) caught it,
which is exactly what the checker is supposed to do. The story stops
there — the user sees a low-level "you broke the invariant" message
that they have no way to fix, because they didn't author the invariant.

This is the architectural risk that the role separation *should* be
preventing: if the lowering misses a case, the checker noisily flags it
but does not synthesise. The codebase has notes (in `mir-bugs.md`,
`mir-rewrite.md`, etc.) suggesting this synthesis-vs-verification split
is a known design tension. The Puck port is one more datapoint that the
lowering pass needs more "common patterns" written into it.

The Bug #9 family is the more dangerous shape of the same disease:
the lowering didn't notice that a per-iteration `MUTABLE` declaration
inside a WHILE *aliases* the same underlying storage when the inner
type is `@list` and the outer container is also `@list`. There is no
checker for it — so it produces garbage at runtime instead of a
build-time error.

### Cause 3 — locally-correct transformations compose into incorrect Zig

Bug #1 is a hoisting bug, but the hoister isn't broken in isolation.
A simpler shape:

```cht
foo = maybe("x") OR "y";
IF foo != "z" THEN RAISE "..."; END
```

compiles fine. The hoister lifts `maybe("x") OR "y"` into a temp, binds
it to `foo`, and the `if` references `foo`. The temp's `const` lands in
the parent scope.

When the user inlines that one line into the `if` condition, the
hoister still creates a temp, but the *scope* it picks for the
declaration is the inner block (where the consumer expression now
lives), instead of the parent block (where the temp's value is
*observed*). Each of those decisions is defensible in isolation —
"declare the temp where it's used" is a reasonable heuristic for
naming, just not for emission ordering.

Bug #3 is similar in flavour: the effect inference pass and the
expression typer each have a defensible view of `OR fallback`, and they
disagree about whether the residual function "can fail". Each pass is
locally consistent; the cross-product is the bug.

These compositional bugs are the hardest to surface without
property-based or fuzzing tests. A type-check / effect-check / hoist /
emit pipeline can have N^2 interaction bugs and zero unit-test signal.

## What would have caught these earlier

In rough order of cost-effectiveness:

1. **Port one external real program per phase.** The Puck port is doing
   that job right now. If a similar port of, e.g., the Lua VM had
   happened during MIR refactoring, these would have surfaced months
   ago. The fact that *this* port produced four new bugs in 300 lines
   is itself a measurement of how big the unexplored surface still is.

2. **Adversarial test generator.** Pick N pairs from `transpile-tests/`
   and try to combine their features. Even a hand-written generator
   that produces "fallible-call-in-IF" variants and "list-in-struct-in-
   list" variants would have caught #1 and #9 immediately. None of
   the bugs needed deep semantics — they needed someone to *try the
   combination*.

3. **A "looks suspicious" reviewer pass on the Zig output.** Bug #1
   produced Zig that referenced an undeclared identifier. A trivial
   grep over the generated `.zig` for "use of undeclared identifier"
   patterns, or even a regular `zig fmt`/`zig ast-check` over the
   transpile-test outputs *before* trying to compile them, would have
   caught #1 the moment it was first emitted by the hoister.

4. **A MIR-synthesis completeness check.** The lowering pass could
   assert, at the end of each function, that every loop body it
   produces has *either* no frame allocations *or* a matching
   `FrameSave`/`FrameRestore`. Today the checker enforces this on the
   final MIR; pushing the same assertion up into lowering's own output
   would surface bug #2 as a "lowering invariant violated" panic
   instead of as a user-visible error message.

5. **A storage-aliasing model for `@list` in `@list`.** This is the
   harder structural fix. Bug #9 implies that when CLEAR sees
   `MUTABLE inner: T[]@list = []` inside a loop body, and the inner
   list is then *moved into a struct that lives in another @list*, the
   ownership analysis is currently letting the per-iteration storage
   alias the previous iteration's. The fix needs to either force a
   fresh allocation per iteration or reject the pattern.

## What we did

For each bug:

- It was reproduced in ≤20 lines of standalone CLEAR (see the
  `transpile-tests/known-failing/` reproducers).
- A workaround was applied to `vm.cht` so the file compiles today.
- The workaround is referenced from the bugs doc by section number so
  a future fix can find both the symptom and the rewrite.

The reproducers are deliberately kept out of the standard
`transpile-tests/gen.rb` glob (they would block CI). When a bug is
fixed, the reproducer should be renamed into the main directory so its
regression becomes part of the gate.

## What's owed back

In rough priority:

- **Bug #9** is silently wrong output. Highest priority for a real fix
  because the workaround (flatten the list-of-lists into one global
  list with `(start, count)` indices) is invasive enough that real
  CLEAR application code will probably continue to write the natural
  shape and silently break.
- **Bug #1** is a Zig-level "doesn't compile" error, much louder than
  #9, and a localised hoister fix should close it.
- **Bug #2** is the synthesis-vs-verification split. The right fix is
  in the MIR lowering pass, not in user code; the workaround
  (hoist-everything-above-the-loop) makes user code less idiomatic
  than CLEAR otherwise asks for.
- **Bug #3 / #8** are quality-of-life: forces invasive signature changes
  but never produces wrong code. Lower priority but the easiest to fix.

The four reproducers are the minimal gate. Adding a fifth — a small
program that mixes all four shapes — would catch the inevitable
"interaction-of-interactions" bug that hits whoever writes the next
real CLEAR port.

## What this tells us about the project

CLEAR's compiler has solid documentation of intent (CLAUDE.md), strict
MIR invariants (mir-bugs.md), and a sizeable transpile-test corpus.
What it does **not** have is meaningful coverage of the *interaction
surface* between features. Every feature in isolation works; every
feature with itself works; cross-feature interactions are largely
untested.

Building any new program of nontrivial size — Mal, a brainfuck VM, a
Puck VM — surfaces ~4 distinct compiler bugs in the first 300 lines.
That isn't a CLEAR-is-bad signal; it's a "the corpus has not yet
sampled real application shapes" signal. The fix is more programs,
written end-to-end, with no fallback to "just ignore the bug and move
on" — which is how vm.cht ended up in its current shape.
