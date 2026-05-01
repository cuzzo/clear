# BC Real Fibers Plan

The MiniVM (BC) currently runs `BG { ... }` bodies **synchronously** — each
BG_SPAWN op recursively calls `exec!` and pushes the result. There's no
real fiber, no concurrency, no lock contention. This works for tests
that assert order-invariant aggregate results but cannot reproduce
behaviors that depend on real parallel execution.

The bc_runner (`_bc_runner.cht`) is itself a CLEAR program running on
the Zig runtime, which DOES have real fibers, real `Locked<T>`, and
real `sleep()`. So the gap is not runtime capability — it's that the
BC implementation chose synchronous BG_SPAWN as a deliberate simplification.

## Tests that block on this

- **263_with_lock_contention** — the only currently-failing test that
  needs this. Holder fiber sleeps 300ms while waiter tries to acquire
  the same lock; the test asserts the waiter's `ON LockTimeout` clause
  fires exactly once.

This is the only known concrete test gated on real fibers in the BC.
The infinite-stream tests (234, 235, 237, 238) are flagged as
`infinite_stream` UNSUPPORTED in run_tests.rb — those need a different
shape of cooperative scheduling (lazy stream generators, cursors).

## Phase A — Real BG fibers

**Goal:** `BG { body }` returns a Future the caller can NEXT on. While
the body runs, the caller continues. NEXT blocks until the body
completes.

**Site:** `_bc_runner.cht`, opcode `82` BG_SPAWN dispatch (~line 3254).

**Current shape:**
```clear
82 ->
    bgEntry = ops[ip]; ip += 1;
    bgArgc  = ops[ip]; ip += 1;
    MUTABLE bgCaps: Value[]@list = List[];
    FOR bi IN (0_i64 ..< bgArgc) DO
        bgCaps.append(COPY stack[sp - bgArgc + bi]);
    END
    sp -= bgArgc;
    pv = exec!(ops, consts, curEnv, pool, bgEntry, bgCaps);
    IF sp >= stack.length() THEN stack.append(pv); ELSE stack[sp] = pv; END
    sp += 1;
```

**Target shape:**
```clear
82 ->
    bgEntry = ops[ip]; ip += 1;
    bgArgc  = ops[ip]; ip += 1;
    MUTABLE bgCaps: Value[]@list = List[];
    FOR bi IN (0_i64 ..< bgArgc) DO
        bgCaps.append(COPY stack[sp - bgArgc + bi]);
    END
    sp -= bgArgc;
    bgPromise = BG {
        exec!(ops, consts, curEnv, pool, bgEntry, bgCaps);
    };
    -- Encode the promise as a Value the dispatch loop can stash and AWAIT
    pv = Value.Future{ inner: bgPromise };
    IF sp >= stack.length() THEN stack.append(pv); ELSE stack[sp] = pv; END
    sp += 1;
```

**Required changes:**

1. **Add `Value.Future { inner: ~Value }` variant** to the Value union
   in `_bc_runner.cht`. Carries a `Promise(Value)` or equivalent
   handle. Affects MATCH-on-Value sites: there are many (~30+ sites
   for various ops); each needs an explicit DEFAULT branch (or a
   pass-through). Inventory required.

2. **Update opcode `83` AWAIT** to NEXT on Future:
   ```clear
   83 ->
       sp -= 1; awaitVal = COPY stack[sp];
       MATCH awaitVal START
           Value.Future AS f -> pv = NEXT f.inner;,
           Value.Pair AS fp -> pv = COPY fp.pairCdr;,  -- legacy
           DEFAULT -> pv = COPY awaitVal;
       END
       ...
   ```

3. **Verify exec! captures play nice**. The `BG { exec!(...) }` body
   captures `ops`, `consts`, `curEnv`, `pool`, `bgEntry`, `bgCaps`.
   - `ops` and `consts` are read-only (immutable bytecode). Sharing
     by reference is correct.
   - `curEnv` is an `Id<Env>` index into pool; pool is already
     `@shared:locked`. Cross-fiber access via `WITH EXCLUSIVE pool`
     remains correct.
   - `pool` is shared and locked.
   - `bgEntry` is an Int64 (the entry ip) — copied.
   - `bgCaps` is a Value[]@list — copied (each BG already snapshots
     captures into a fresh list).

4. **BG_SPAWN now creates one real fiber per call**. Tests that spawn
   100s of BG fibers will consume real fiber stacks. Need to verify
   stack pool is sized appropriately. Default stack pool is
   probably fine for typical tests but big stress tests might hit
   limits.

**Risks:**
- Many tests use BG and assume order. Real fibers are ordered by
  scheduler (typically FIFO within a scheduler). Audit needed.
- Some tests do `p = BG{ x }; mutate x; NEXT p` and expect the
  fiber to see post-mutation `x`. Currently synchronous BG sees the
  pre-mutation snapshot (because captures are copied before the body
  runs). Real fibers also snapshot captures, so behavior should match.
- Per-fiber `slots`/`stack`/`istack`/etc. are local to each `exec!`
  call (already independent). Good.

**Estimated effort:** 1-2 days, ~50 LOC change in _bc_runner.cht
plus full BG-test audit (~50 tests).

## Phase B — Real per-resource locks

**Goal:** User-program `c = Counter{} @shared:locked` gets an actual
lock. WITH EXCLUSIVE c acquires it (with timeout for ON LockTimeout
clauses).

**Current state:** in BC, `@shared:locked` is a Value.Boxed cell-id.
WITH EXCLUSIVE c does `alias_to_source` (no real locking — both alias
and source share storage by Box reference).

**Two design options:**

### Option B1 — `Value.Locked` variant

Add `Value.Locked { id: Id<Env>, lock: Locked<Value> }` to the Value
union, where `lock` is a real `CheatLib.Locked` wrapping the inner
Value. WITH EXCLUSIVE acquires the lock, binds the alias to the
unwrapped guard.

**Pros:** Cleanest mapping; per-resource lock identity preserved.

**Cons:**
- Locked<Value> is large and recursive (Value contains Locked containing
  Value). May not compile cleanly without indirection.
- Every Value cleanup site needs to handle the variant.

### Option B2 — Dedicated lock pool

Add a second pool: `lockPool: ?Locked<Value>[1024]@pool:shared:locked` (or
similar). Each `@shared:locked` decl gets a slot id. The Value just
carries the id (`Value.Locked { id: i64 }`). WITH EXCLUSIVE
goes through the lock pool.

**Pros:** Avoids recursive type; consolidates lock state.

**Cons:** Two-level indirection (id → lockPool → guard); pool size
limit (could grow but capped).

**Recommendation:** Option B2 — fewer type-system surprises.

**Required changes:**

1. **bc_emitter.rb compile_let**: when the binding is a CapWrap with
   sync `:locked` and storage `:shared`, allocate a lock-pool slot
   and emit `LOCK_NEW <pool_idx>`.

2. **New opcodes:**
   - `LOCK_NEW`: allocate a lock-pool slot, store initial value, push
     `Value.Locked { id }`.
   - `LOCK_ACQUIRE` (with timeout) → guard handle (or error.LockTimeout).
   - `LOCK_RELEASE`.
   - Or wrap as native fns called via NATIVE_CALL.

3. **with_block_bindings handler in bc_emitter.rb**: when the source
   is a Value.Locked, emit LOCK_ACQUIRE and bind the alias to the
   guard. Body's writes go through the guard. Release on scope exit.

4. **ON LockTimeout clause support**: the ScopeBlock for WITH currently
   handles label-break for PASS / RAISE. Need to handle the timeout
   path: if LOCK_ACQUIRE returns error.LockTimeout, jump to the ON
   handler.

**Estimated effort:** 3-5 days. Touches bc_emitter.rb, _bc_runner.cht,
and the WITH lowering path. Many tests use WITH EXCLUSIVE (test 170,
228, 240, 263, 264, 265, 266, 267, 268, 270) — full audit required.

## Phase C — Real sleep()

**Goal:** `sleep(ms)` actually yields the current fiber for ms.

**Site:** `bc_emitter.rb` line 3551, `:sleep` dispatch.

**Current:** No-op (eval arg, push Nil).

**Target:** NATIVE_CALL "sleep" → calls real `sleep()` runtime function.

**Required changes:**
1. Add `sleep` native to the bc_runner natives table.
2. bc_runner's sleep handler calls real `sleep(ms)` (already a
   primitive available to CLEAR code).

**Estimated effort:** 30 minutes. Trivial.

## Total estimate

- Phase A: 1-2 days (BG fibers + BG-test audit)
- Phase B: 3-5 days (lock infrastructure + WITH lowering + WITH-test audit)
- Phase C: 30 minutes (sleep)
- **Total: ~1-2 weeks**, multiple commits, with risk of regressing
  ~50+ existing BG/WITH tests during the audit.

## Recommendation

Start with Phase A (smallest, most isolated) as a probe to validate
that real BG fibers don't regress existing tests. If Phase A lands
cleanly, Phase B and C follow naturally. If Phase A reveals
unexpected complexity (e.g., the BG-test audit uncovers tests
genuinely depending on synchronous semantics), pause for a redesign
discussion before committing to Phase B.
