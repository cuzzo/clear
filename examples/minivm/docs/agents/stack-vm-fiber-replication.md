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

### Narrowed diagnosis (the blocker is NOT a full FSM rewrite)

The `INLINE_ALLOC_MISMATCH` cited **only** `intListHandles` and
`stringListHandles` — and **only** those two. Both are the register
VM's only **nested-`@list`-in-struct** locals:

```clear
STRUCT RegisterIntListHandle    { values: Int64[]@list }
STRUCT RegisterStringListHandle { values: String[]@list }
MUTABLE intListHandles:    RegisterIntListHandle[]@list    = List[];
MUTABLE stringListHandles: RegisterStringListHandle[]@list = List[];
... intListHandles.append(RegisterIntListHandle{ values: [] });
```

Under `EFFECTS REENTRANT`, escape analysis conservatively promotes
`intListHandles` to `:heap`, but the inline
`RegisterIntListHandle{ values: [] }` constructs the nested `values`
list `:frame` -> a frame list stored into a heap container =
`INLINE_ALLOC_MISMATCH`.

The stack VM's reentrant `exec!` does **not** hit this because its
locals are all **flat** (`Value[]@list`, `Int64[]`, `Float64[]`) —
no struct-with-nested-`@list`. **That flat-collection discipline is
the proven-safe model under reentrancy.** Every other register-VM
collection (fixed `iregs`/`fregs`/`sregs` arrays, flat
`vlist0..3: RegisterValue[]@list`) did NOT error.

So the blocker is precise and small, NOT "rewrite the giant
function to FSM": **the two handle tables must be flattened to
match `exec!`'s flat-collection pattern.**

### Concrete fix path (actionable, scoped)

Two options, in preference order:

1. **Flatten the handle tables (recommended; mirrors exec!).**
   Replace `RegisterIntListHandle{ values: Int64[]@list }[]@list`
   with a flat representation: e.g. a single
   `MUTABLE intHandleValues: Int64[]@list` plus per-handle
   `(start, len)` offsets in a flat `Int64[]@list`, or reuse the
   existing flat `vlist*` list-reg machinery for handle storage.
   Same for string handles. Touch sites: the IHANDLE/SHANDLE
   opcode family (vm.cht ~2425-2460) + their emission. No compiler
   change, no FSM rewrite; matches the stack VM's proven shape.
2. **Compiler escape-analysis propagation.** When a struct literal
   with an `@list` field is stored into a `:heap` container under a
   reentrant fn, promote the field-list to `:heap` at construction
   (EscapeAnalysis, per CLAUDE.md "Adding a New Escape Scenario").
   More general but a shared-compiler change with broader blast
   radius; defer unless option 1 proves insufficient.

**Revised gate:** P0 = (a) faithful guest frame-arena
(`vm-bugs.md`) AND (b) **flatten `intListHandles`/`stringListHandles`
to flat lists (option 1 above)** so `runRegisterBytecode!` survives
`EFFECTS REENTRANT` + non-TIGHT. (b) is a contained VM refactor (the
IHANDLE/SHANDLE opcode family), NOT the giant FSM conversion. R2-R6
unblock once (a)+(b) land. This is still a dedicated workstream, but
a precisely scoped one.

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
