# Replicating the Stack VM's Real Fibers in the Register VM

The user's insight is correct: the **stack VM (`_bc_runner.cht` +
`bc_emitter.rb`) already implements real BG fibers, futures, joins,
sleep-yield, and stream channels.** The register VM
(`vm.cht` + `register_bc_emitter.rb`) inlines BG synchronously. This
doc is the exact, verified mapping — the "easy path to replicate."

Source of truth read 2026-05-17: `_bc_runner.cht` lines 2516-2590
(exec! signature + futureTable), 3311-3410 (BG_SPAWN op 82 / AWAIT
op 83), 3294-3309 (FIBER_RET op 81), 3802-3970 (SLEEP_MS op 118 /
STREAM_SPAWN op 119 / STREAM_NEXT op 121); `bc_emitter.rb` 2763-2800
(BgBlock -> separate entry_ip + FIBER_RET + BG_SPAWN).

## The stack VM mechanism (verbatim shape)

```clear
# exec! is re-entrant: a spawned fiber calls it from a different
# entry point with its captures.
FN exec!(ops: Int64[], consts: Value[], envId: Id<Env>,
         MUTABLE pool: Env[50000]@pool,
         entryIp: Int64, initCaps: Value[]) RETURNS !Value ->
    MUTABLE ip: Int64 = entryIp;
    ...
    FOR ci IN (0 ..< initCaps.length()) DO slots[ci] = COPY initCaps[ci]; END
    ...

MUTABLE futureTable: ~Value[]@list = List[];     # Future handles
MUTABLE futureResolved: HashMap<Value> = {};     # memoized, key=fid.toString()

# op 82  BG_SPAWN [entry_ip] [argc]
bgEntry = ops[ip]; ip += 1;
bgArgc  = ops[ip]; ip += 1;
MUTABLE bgCaps: Value[]@list = List[];
FOR bi IN (0 ..< bgArgc) DO bgCaps.append(COPY stack[sp - bgArgc + bi]); END
sp -= bgArgc;
bgFut: ~Value = BG { @service ->
    exec!(COPY ops, COPY consts, curEnv, pool, bgEntry, GIVE bgCaps) OR RAISE;
};
bgFid = futureTable.length();
futureTable.append(bgFut);
push Value.Pair{ pairCar: Symbol "__future__", pairCdr: Int64Val bgFid };

# op 83  AWAIT  (pop; if Pair("__future__", fid))
IF futureResolved[fid.toString()] AS cached THEN pv = COPY cached;
ELSE pv = NEXT futureTable[fid]; futureResolved[fid.toString()] = COPY pv; END

# op 81  FIBER_RET : pop -> fiberRetVal; fiberReturned = TRUE (ends this exec!)
```

Key facts:
- The runner is itself a CLEAR program on the real Zig runtime, so
  `BG { @service -> ... }` is a **real fiber**; `NEXT fut` is a real
  join. No shadow scheduler — fully runtime-faithful (satisfies the
  README invariant).
- `bc_emitter.rb` emits the BG body as a **separate bytecode region**:
  `JUMP over-body; entry_ip: <body with captures bound to slots
  0..N-1>; FIBER_RET; <call site> BG_SPAWN entry_ip argc`.
- Captures are passed positionally; `exec!` loads them into
  `slots[0..N-1]` (uniform `Value[]`), and the emitted body prologue
  binds capture names to slots 0..N-1.
- `futureResolved` memoizes so multi-NEXT is idempotent
  (`~T@shared` semantics).
- `SLEEP_MS` (op 118) = real `sleep`, a yield point. Stream channels
  (op 119/121) spawn a producer fiber + spin the consumer on a
  channel cell.

## Register-VM mapping (the replication)

`runRegisterBytecode!` is the analogue of `exec!`. The register VM
has typed register files (`iregs`/`fregs`/`sregs` + `iBase`/`fBase`)
instead of a uniform `slots[]`, and `RegisterValue` instead of
`Value`. Everything else maps 1:1.

### R1. Re-entrant `runRegisterBytecode!` (keystone, inert)

Add `entryIp: Int64` and `initCaps: RegisterValue[]` params. Set the
dispatch `ip = entryIp`. Top-level call (bc_run.rb generated main,
and vm.cht template) passes `entryIp = 0` (main is compiled first so
its entry is ip 0) and `initCaps = List[]`. Capture loading is a
no-op when `initCaps` is empty -> identical behavior. Mirrors
exec!'s signature growth. Verify allowlist 245/245.

### R2. (resolved 2026-05-17) No `FIBERRET` opcode needed

The stack VM needed op 81 because all fibers share one `exec!` loop
shape with a sentinel. In the register VM each spawned fiber is its
**own `runRegisterBytecode!` invocation** (R3 spawns
`BG { -> runRegisterBytecode!(..., bgEntry) }`) with its **own**
frame stack (`frameRetIps` starts empty in that invocation). The BG
body region therefore ends in a normal typed `RETURN`; at
frame-depth 0 the existing `IRET`/`FRET`/`SRET` arm already does
`RETURN intResult|floatResult|stringResult(...)`, which returns from
that `runRegisterBytecode!` = the fiber's result, exactly what `BG`
captures. So R2 is a no-op: the emitter just emits the BG body
region ending in the normal typed `compile_return` for the body's
value type. Avoids a speculative opcode (CLAUDE.md scope control).
Renumber: R3->R2 (BGSPAWN), R4->R3 (FNEXT), R5->R4 (emitter), etc.

### R3. `BGSPAWN entry_ip argc` opcode (= stack op 82)

vm.cht dispatch (mirror verbatim):
```clear
MUTABLE futureTable: ~RegisterValue[]@list = List[];
MUTABLE futureResolved: HashMap<RegisterValue> = {};
...
RegisterOp.BgSpawn ->
    bgEntry = ops[ip]; ip += 1;
    bgArgc  = ops[ip]; ip += 1;
    MUTABLE bgCaps: RegisterValue[]@list = List[];
    FOR bi IN (0 ..< bgArgc) DO bgCaps.append(<capture i as RegisterValue>); END
    bgFut: ~RegisterValue = BG { @service ->
        runRegisterBytecode!(COPY ops, COPY opcodes, COPY consts,
            COPY sourceLines, COPY sourceColumns, COPY sourcePaths,
            COPY breakpointIps, COPY varNames, bgEntry, GIVE bgCaps) OR RAISE;
    };
    bgFid = futureTable.length();
    futureTable.append(bgFut);
    <push future-marker RegisterValue: a dedicated RegisterValue
     variant `Future{ id: Int64 }` (cleaner than the stack's
     Pair("__future__",id) hack -- VM-internal value, allowed)>,
```

### R4. `FNEXT` opcode (= stack op 83 AWAIT) — joining NEXT

Replace the register emitter's pass-through `NEXT` with `FNEXT`:
resolve a future-marker -> memoized `futureResolved[fid]` or
`NEXT futureTable[fid]` (real join), store memo. Non-future operand
= identity (legacy).

### R5. Emitter: BG body as a separate region (= bc_emitter 2763)

`@bg_mode = :fiber`: instead of inlining `compile_bg_block_value`,
emit `JMP over_body; entry: <FIBER body>; FIBERRET; <site> BGSPAWN
entry argc`. Captures: the register VM's typed regs make this the
one real divergence from the stack VM's uniform `slots[]`. Two
options:
- **R5a (recommended, simplest):** carry every capture as a
  `RegisterValue` (the uniform carrier, exactly like the stack's
  `Value[]`). The body prologue loads `initCaps[i]` into the
  capture's Value-reg; scalar captures unwrap via the existing
  V2I/V2F accessors. One uniform path, mirrors the stack VM 1:1.
- R5b: typed cap vectors (iCaps/fCaps/sCaps). Faster, more
  bytecode; defer.

`initCaps` loading in R1 then writes the lowest Value-regs (slots
0..N-1 of the spawned invocation's value-reg file), matching the
emitter's capture binding — exactly the stack VM's `slots[0..N-1]`
contract.

### R6. Real `Locked`/`Arc`/atomic on the `:fiber` path

When `@bg_mode = :fiber`, route cap-wrapped guest lock/atomic ops
through the real runtime `Locked<T>` / atomics (the runner has
them) instead of the single-threaded no-op. The stack VM relies on
the same real primitives ("pool's @shared:locked discipline
propagates cross-fiber mutations safely", op 82 comment). Unblocks
`263_with_lock_contention`.

### R7+. Streams / sleep / DO

`SLEEP_MS` (stack op 118) -> `SLEEPMS` opcode = real `sleep` yield.
`STREAM_SPAWN`/`STREAM_NEXT` (stack op 119/121) -> producer fiber +
channel cell, same shape. `DO` parallel branches = N BGSPAWN + N
FNEXT. These are direct ports of stack ops 118/119/121 once R1-R5
land.

## Why this is the easy path

- The hard design problem (how to get real concurrency in a
  bytecode VM that is itself a CLEAR program) is **already solved**
  in the stack VM and proven against its test corpus. We are
  porting a working mechanism, not inventing one.
- It is runtime-faithful by construction (real `BG`/`NEXT`/`Locked`
  via the runner's own CLEAR runtime) — satisfies the README and
  CLAUDE.md invariants automatically.
- Only ONE genuine new design decision vs. the stack VM: capture
  layout into typed register files (R5a uniform-RegisterValue
  resolves it the same way the stack VM uses uniform `slots[]`).

## R2 attempt (2026-05-18) — blocked on P0, as predicted

Implemented the real recursive-spawn mechanism (BGSPAWN/FNEXT +
futureTable + `BG { @service -> runRegisterBytecode!(..,bgEntry) }`)
to empirically test the giant-frame-fiber-recursion risk. Findings,
in order encountered:

1. **Compiler diagnostic (correct):** recursive `runRegisterBytecode!`
   needs `EFFECTS REENTRANT` (like the stack VM's `exec!`). Added.
2. **Compiler diagnostic (correct):** a `@reentrant` call cannot sit
   in a `TIGHT WHILE`. The register dispatch loop had to drop TIGHT
   (the stack VM's `exec!` loop is a plain `WHILE` for exactly this
   reason). Done — known per-iteration perf tradeoff.
3. **Compiler BUG (fixed + filed):** `ControlFlow.scan_direct`'s
   Sorbet sig forbade the nil sub-bodies it is internally designed
   to tolerate (IF-without-ELSE), aborting at the call boundary
   before its own `return unless body.is_a?(Array)` guard. Exposed
   by the new `EFFECTS REENTRANT` + BG-block path. Fixed
   (sig -> `T.nilable`); recorded in `docs/agents/vm-bugs.md`
   ("Compiler: control_flow.scan_direct sig rejects nil sub-bodies").
   Verified: prspec 4798/0, transpile-tests 554/554 (0 leaks),
   register allowlist 245/245.
4. **HARD BLOCKER (= P0):** with the giant `runRegisterBytecode!`
   made `EFFECTS REENTRANT` + non-TIGHT + spawning recursive
   fibers, MIR ownership verification fails:
   `[INLINE_ALLOC_MISMATCH] runRegisterBytecode::intListHandles --
   operation uses :frame but container is :heap` (and
   `stringListHandles`). Making the giant function reentrant changes
   the escape analysis of **its own** frame-allocated collections
   (frame -> heap), but inline ops on them still use :frame.

This is exactly the roadmap's **P0** and the README's standing
warning: the register VM's giant stackful `runRegisterBytecode!`
must become FSM-style / heap-resident (its big locals become
ctx fields) **before** it can be made reentrant and spawn real
fibers. The recursive-spawn shape is sound (the stack VM proves
it) — but the register VM's own arena/escape model under
reentrancy must be resolved first. R2's real spawn was reverted;
R1 (re-entrant entryIp, inert) + the compiler fix remain.

### Faithful re-reproduction (2026-05-18, post-compiler-fix)

After the `scan_direct`/`pipeline_rewriter` root-cause fix, a
**minimal** faithful probe (`EFFECTS REENTRANT` +
`IF false { probeFut: ~RegisterValue = BG { @service ->
runRegisterBytecode!(COPY ops, COPY opcodes, ...) }; ... }`) was
applied to drive the reentrant escape/codegen path with the
smallest possible change. It does NOT reach
`INLINE_ALLOC_MISMATCH` — it fails **earlier**, in generated Zig:

```
error: expected type '*array_list.Aligned(i64,null)',
       found '*const []i64'
```

i.e. `COPY ops` (a slice param, `Int64[]`) captured into a `BG`
fiber and passed to the recursive call. **This is the OPEN
BG-capture compiler-bug family** documented at the top of
`docs/agents/vm-bugs.md`:

- Bug #4 — "`COPY` at BG capture site → cryptic Zig error" (COPY
  of a value captured into BG produces wrong/`*const`-vs-`*T` Zig).
- Bugs #2/#3/#6 — the dangling-pointer family: a borrow/slice from
  local scope escaping into an async BG fiber without ownership
  transfer; the lowering emits no marker, the checker has nothing
  to fire on, codegen mismatches or UAFs.

The stack VM's `exec!` does the *same* `BG { exec!(COPY ops, ...) }`
shape and works — so the trigger is a register-side difference
(slice-param `ops: Int64[]` capture interacting with the giant
frame / `EFFECTS REENTRANT` escape model) that the existing
BG-capture bugs don't yet cover or fix.

**Revised, evidence-based blocker for R2-R6:** not "one
escape-analysis tweak" and not "flatten" (retracted). The fiber
port is blocked behind the **OPEN BG-capture / dangling-pointer
compiler-bug family** (`vm-bugs.md` Bugs #2/#3/#4/#6) — exactly
what that doc was opened to track — *plus* P0 (guest frame-arena +
giant-function FSM/heap-resident conversion). These are
shared-compiler correctness fixes that must land, architecturally,
**before** stack-VM fiber replication is viable. Do NOT band-aid
around them in `vm.cht`. R1 + the compiler-bug fix remain; the
probe was reverted (tree green, register allowlist 245/245).

### CORRECTION (2026-05-18): retracting the "flatten" workaround

An earlier revision of this section claimed the fix was to "flatten
the handle tables to match exec!'s flat-collection pattern" and
asserted the cause was an escape-analysis Condition-7 gap. **Both
claims are withdrawn.** They were a workaround instinct and an
unconfirmed diagnosis — exactly what CLAUDE.md forbids ("if you
find a limitation forcing workarounds, stop, identify the problem,
fix the language", and "prove the bug with a test first").

Empirically established instead:

- **Structs/lists do NOT need to be flat.** Minimal repros — a
  `Bucket{ values: Int64[]@list }` stored into a heap `Bucket[]@list`,
  both non-reentrant AND under `EFFECTS REENTRANT` with a
  BG-recursive spawn and in-place indexed nested-`@list` mutation —
  **all compile and run correctly** on the native backend. CLEAR
  supports nested-`@list`-in-struct in heap containers. `exec!`'s
  flatness is incidental, not a language requirement. "Flatten the
  VM's data structures" would be a band-aid around a compiler issue
  and is explicitly NOT the path.

- **The `INLINE_ALLOC_MISMATCH` was real** (it occurred in the
  actual `vm.cht` R2 build) but its precise trigger is **not yet
  minimally reproduced** — every minimal repro that should exercise
  the hypothesised path passes. So the "Condition 7 only promotes
  string-concats" root-cause is **unproven** and must not be acted
  on. The true trigger is more specific to the full `vm.cht`
  shape (likely the heavy param-capture set of
  `BG { runRegisterBytecode!(COPY ops, COPY opcodes, ...) }`
  combined with the giant function's other escaping locals).

### Correct next step (no workaround, no blind fix)

Per CLAUDE.md bug methodology, the escape mismatch must be
**faithfully reproduced before any fix**:

1. Re-apply the R2 vm.cht changes (the configuration that
   definitively produced `INLINE_ALLOC_MISMATCH`).
2. Bisect within it: is the trigger `EFFECTS REENTRANT` alone? +
   non-TIGHT? + the `BG { runRegisterBytecode!(COPY ops, ...) }`
   param-capture set? Reduce to the smallest failing CLEAR program.
3. Only then root-cause in `EscapeAnalysis` and fix at the
   architecturally-correct place — the canonical heap-promotion
   must recursively cover nested collection fields uniformly across
   ALL promotion conditions (RETURNS, reentrant, assign-escape,
   container-mutator), not a per-condition patch. The RETURNS path
   already propagates correctly (proven by repro); the gap, if any,
   is that the promotion paths are **not unified**.

See `compiler-bug-root-causes.md` (this dir) for the cross-cutting
architectural analysis of every compiler bug found this session.

**Revised gate:** P0 = (a) faithful guest frame-arena
(`vm-bugs.md`) AND (b) faithfully reproduce + root-cause the
reentrant `INLINE_ALLOC_MISMATCH`, then a unified escape-promotion
fix (NOT flattening, NOT FSM-rewrite, NOT a Condition-specific
band-aid). R2-R6 unblock once (a)+(b) land. Dedicated workstream;
the precise scope of (b) is "reproduce first."

## Ordering & gating

R1 (keystone, inert) -> R2 -> R3 -> R4 -> R5 -> R6, each a verified
commit, `@bg_mode` default stays `:inline` (full allowlist 245/245)
until R5 proves the `:fiber` path on a separate tranche. **P0
(guest frame-arena, docs/agents/vm-bugs.md) remains the hard
prerequisite for trustworthy multi-fiber allocation** — see
`concurrency-and-loom-roadmap.md`. The loom/interleaving work
(Phase 3 there) builds on R1's multi-fiber trace once fibers are
real.

## CLEAR language bugs

Record any compiler/language bug hit while replicating in
`docs/agents/vm-bugs.md` (per project convention; this doc focuses
on the VM port).

## Bisection result (2026-05-18, post Bug#7 + discard-`_` fixes)

Re-ran the faithful minimal reentrant probe (`EFFECTS REENTRANT` +
`IF FALSE { probeFut: ~RegisterValue = BG { @service ->
runRegisterBytecode!(COPY ops, COPY opcodes, ...) }; }`) after two
shared-compiler bug fixes landed:

- **Bug #7** (FIXED): `COPY` of a borrowed `@list`/struct param
  captured into BG (`*const T` vs `*T`). Was the exact
  `expected '*array_list...', found '*const []i64'` blocker.
- **Discard `_`** (FIXED): `_ = NEXT probeFut;` /
  `_ = <owned>;` emitted literal Zig `const _ = ...`. Was the
  next blocker the probe hit once Bug #7 cleared.

**Result: the probe now compiles cleanly** -- no `*const`/`*T`
error, **no `INLINE_ALLOC_MISMATCH`**, no MIR error, no
frame/escape failure. The giant `runRegisterBytecode!` made
`EFFECTS REENTRANT` and lexically containing a recursive
`BG { runRegisterBytecode!(COPY ops, ...) }` (the exact stack-VM
`exec!` shape) builds.

### Revised P0 assessment

The previously-feared P0(b) `INLINE_ALLOC_MISMATCH` **did not
reproduce** under the faithful minimal probe -- consistent with
the earlier note that it was "real in the full R2 vm.cht but never
minimally reproduced; root-cause unproven." The two real,
minimally-reproduced, now-fixed blockers were ordinary
shared-compiler bugs (BG-capture param typing; discard-`_`
codegen), exactly what `vm-bugs.md` exists to track -- NOT a
guest-arena/FSM rewrite.

Caveat: the probe keeps the recursive spawn in `IF FALSE` and the
dispatch loop still `TIGHT WHILE` (no `@reentrant` call lexically
inside the TIGHT loop). R3 (real `BGSPAWN` inside dispatch) will
still require de-`TIGHT`ing the loop (doc finding #2) and a faithful
re-check for `INLINE_ALLOC_MISMATCH` at that point -- if it
reappears there, reproduce minimally before any fix (CLAUDE.md).
The probe was reverted; tree green (prspec 4802/0, transpile-tests
555/555 0-leak, fuzz 145/145, register 245/245).

**Revised gate:** R2->R3 is no longer blocked behind the
BG-capture bug family (cleared). Remaining R3 prerequisites:
de-TIGHT the dispatch loop + faithfully re-probe for the reentrant
`INLINE_ALLOC_MISMATCH` *with the spawn actually reachable inside
the loop* (reproduce-first; do not pre-emptively rewrite).

## P0(b) FAITHFULLY REPRODUCED — minimal trigger isolated (2026-05-18)

While measuring the perf cost of de-`TIGHT`ing the dispatch loop
(R3 prerequisite), the P0 `INLINE_ALLOC_MISMATCH` reproduced from a
**single-token change** and nothing else:

`examples/minivm/vm.cht:950` `TIGHT WHILE ip < ops.length()` ->
`WHILE ip < ops.length()` (drop `TIGHT`). NO `EFFECTS REENTRANT`,
NO BG/probe, NO `COPY`-capture set. `./clear build vm.cht`:

```
MIR ownership verification failed (post-lowering):
[INLINE_ALLOC_MISMATCH] runRegisterBytecode::intListHandles
  -- operation uses :frame but container is :heap
[INLINE_ALLOC_MISMATCH] runRegisterBytecode::stringListHandles
  -- operation uses :frame but container is :heap
```

### Root trigger (now proven, no longer hypothesised)

A non-`TIGHT` `WHILE` in a runtime fn with a frame-allocating body
gets, per `mir_lowering.rb` `lower_while` (~L6862/L6874):
`saveLoopMark()` + `defer restoreLoopMark()` (per-iteration frame
arena rewind) and a trailing `checkYield()`. Adding per-iteration
arena rewind to the dispatch loop flips the escape classification
of the giant function's own loop-spanning collections
(`intListHandles` / `stringListHandles`) frame->heap (they must
survive the per-iteration rewind), but the inline ops on them are
still emitted `:frame`. That mismatch is INV-1/ALLOC_MISMATCH.

This is the earlier doc's hypothesis CONFIRMED and the trigger
NARROWED: it is **not** reentrancy and **not** the BG-capture set
(those were the Bug#7 / discard-`_` blockers, now fixed and shown
to compile). It is the **non-tight-loop per-iteration arena
rewind** interacting with collections whose lifetime spans loop
iterations.

### Consequence for R3 / the user's perf concern

De-`TIGHT`ing the dispatch loop does not merely cost performance
(it would: a `checkYield()` + `saveLoopMark/restoreLoopMark` on
EVERY bytecode instruction, the VM's hottest loop) -- it currently
**fails to compile**. So R3 cannot proceed by naively dropping
`TIGHT`. Two independent problems, both must be solved before R3:

1. **Correctness (gating):** the escape model must promote
   loop-spanning nested collections (`@list` and their element
   backing) consistently so inline ops match the container
   allocator under per-iteration rewind. Architecturally-correct
   fix = unify heap-promotion so it recursively covers nested
   collection fields across ALL promotion conditions including the
   non-tight-loop-rewind path (NOT a per-condition band-aid, NOT
   flattening the VM's data, NOT an FSM rewrite). Dedicated
   standalone bug-fix workstream; reproduce-first satisfied here.
2. **Performance:** even once it compiles, per-instruction
   `checkYield`/arena-rewind on the dispatch loop must be measured
   and kept off the hot path (e.g. the recursive `BG{ runReg... }`
   may be expressible WITHOUT de-`TIGHT`ing -- the earlier probe
   compiled with the loop still `TIGHT` because the spawn sat in
   `IF FALSE` outside it; whether a BG-wrapped spawn INSIDE the
   `MATCH` trips the TIGHT-reentrant check is the next probe).

**Revised gate:** R3 blocked on (1) [now reproduced; root-cause +
unified-promotion fix pending, its own commit]. Path (2) probe:
test whether `BG { runRegisterBytecode!(...) }` inside the still-
`TIGHT` dispatch `MATCH` compiles (avoids the perf hit entirely).

## R3 gating resolved (2026-05-18): alt-path dead, de-TIGHT required + costed

With the P0 nested-@list-field allocator bug fixed+hardened
(b538f5dd, 2be29d3d), the two R3 questions were settled empirically.

### 1. Alt-path (keep TIGHT, spawn inside) -- NOT VIABLE

Probe: `EFFECTS REENTRANT` + a `BG { @service ->
runRegisterBytecode!(COPY ops, ...) }` placed LEXICALLY INSIDE the
still-TIGHT dispatch MATCH (in the `RegisterOp.Halt` arm, guarded
by `IF FALSE`) -- exactly where the real BGSPAWN handler lives.

Result: `[Compiler Error] TIGHT loop cannot call @reentrant
function 'runRegisterBytecode!'`. The `BG { @service -> ... }`
wrapper does NOT shield the call: the reentrant-in-TIGHT check is
an EFFECT check (the BG body's effect set includes the reentrant
call), not a lexical-call check. So a recursive BGSPAWN cannot live
in a TIGHT loop. **R3 must de-TIGHT the dispatch loop.**

### 2. De-TIGHT now compiles; perf cost measured

The P0 fix unblocked de-TIGHT compilation (it previously failed
with INLINE_ALLOC_MISMATCH). De-TIGHT line 950 only, register VM,
vs the TIGHT baseline:

| bench | TIGHT | noTIGHT | delta |
|---|---|---|---|
| 01_fib | 108 | 163 | +51% |
| 02_loop_sum | 276 | 345 | +25% |
| 03_hashmap | 149 | 191 | +28% |
| 05_call_loop | 62 | 93 | +50% |
| 06_float_loop | 69 | 69 | +0% |
| 08_branch_loop | 89 | 156 | +75% |
| 09_struct_loop | 44 | 77 | +75% |

Avg ~+43% on the dispatch-heavy hot path. Per `mir_lowering
lower_while`, a non-tight loop in a runtime fn injects, per
iteration: (a) `checkYield()` ALWAYS, and (b)
`saveLoopMark()`/`defer restoreLoopMark()` IFF the body
frame-allocates (`mark_per_iter`).

- (a) `checkYield` is the ACCEPTED cost: the stack VM's `exec!` is
  itself a plain non-tight WHILE and pays exactly this per
  instruction -- it is the project's primary VM at acceptable perf.
- (b) per-instruction arena mark+rewind is the expensive,
  *mitigable* part, and is the same mechanism behind the P0. It
  fires only because the giant dispatch body frame-allocates each
  iteration.

### R3 next step (the proper workstream)

Reduce/relocate the dispatch loop body's per-iteration frame
allocations so `mark_per_iter` is false -> de-TIGHT then costs only
`checkYield` (the stack VM's accepted cost), not arena rewind. This
is a dispatch-body restructuring task (hoist per-instruction temp
collections/strings to reused buffers or heap-resident ctx fields;
note the existing bc_run.rb comment that vm.cht is the tree's one
stackful task pending an FSM-style heap-resident conversion). Only
once `mark_per_iter` is false should de-TIGHT land + R3's real
BGSPAWN/FNEXT opcodes proceed. Do NOT ship a +43% hot-path
regression to unblock R3.

Tree state: vm.cht reverted to clean TIGHT baseline; all probes
reverted; suite green.
