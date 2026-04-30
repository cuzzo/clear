# Thunks + Trampolines

## Goal

Replace `@reentrant` with three first-class effect variants that make recursion's stack cost explicit and shift its lowering off the fiber stack whenever possible.

| Variant | Lowering | Stack cost per call | Default? |
|---|---|---|---|
| `EFFECTS REENTRANT` | Real recursion | One frame per depth | Forces caller onto `@service` (OS thread, 2 MB) or `@size:canSmash` fiber |
| `EFFECTS REENTRANT:TAIL_CALL` | Self-loop | Constant (1 frame) | Caller's tier unchanged; verified by stack pass |
| `EFFECTS REENTRANT:THUNK` | Heap CPS state machine + trampoline | Caller's frame + thunk state-struct | Caller's tier sums in the thunk state size |

From the **caller's** perspective, `:TAIL_CALL` and `:THUNK` are NOT reentrant — they don't grow the calling fiber's stack. They satisfy `REQUIRES x: NON_REENTRANT`. Only plain `REENTRANT` is contagious.

`@thunk(N)` is a **call-site** override: it asks the compiler to thunkify a normally-recursive callee for this one call, with `N` as the cooperative-yield gas budget (loop iterations between scheduler yields).

## Why

Today every reentrant function forces `@service` — a 2 MB OS thread. That's the entire reason recursion is excluded from the FSM path. Thunkification keeps recursion off the fiber stack while preserving cooperative scheduling. Tail-call optimization handles the linear-recursion case at zero overhead. The combination shrinks the "must be stackful" set down to a small handful of patterns (REENTRANT-without-variant, fn-pointer dispatch, EXTERN) where the trampoline path can't help.

A secondary win: turning `@reentrant` into a regular `EFFECTS` clause aligns recursion with the rest of the effect system (`HEAP`, `BLOCKING`, `LOOP_UNBOUND`, ...), so STRICT mode and `clear fix --effects` handle it uniformly.

## Surface syntax

### Function-side declaration

```
-- Plain recursion. Caller must spawn on @service or @size:canSmash.
FN deepWalk(node: *Node) RETURNS Void
  EFFECTS REENTRANT ->
  ...
END

-- Tail-call optimized. All recursive calls MUST be in tail position;
-- stack pass verifies this. Compiles to a self-loop, no extra cost.
FN sum(n: Int64, acc: Int64) RETURNS Int64
  EFFECTS REENTRANT:TAIL_CALL ->
  IF n <= 0 -> RETURN acc; END
  RETURN sum(n - 1, acc + n);
END

-- Thunk + trampoline. General recursion via a heap-allocated
-- continuation stack; cooperative yield at gas exhaustion.
FN factorial(n: Int64) RETURNS Int64
  EFFECTS REENTRANT:THUNK ->
  IF n <= 1 -> RETURN 1; END
  RETURN n * factorial(n - 1);
END
```

The variant binds at the colon: `REENTRANT:TAIL_CALL` and `REENTRANT:THUNK` are two more values in the effect grammar (lexer treats `:` as part of the effect token here, like `@locked:rank:0`).

### Constraint syntax for fn parameters

Old (capability on the type):
```
FN map(items: Int64[], f: FN(Int64) -> Int64@nonReentrant) RETURNS Int64[] -> ...
```

New (constraint on the binding):
```
FN map(items: Int64[], f: FN(Int64) -> Int64) RETURNS Int64[]
  REQUIRES f: NON_REENTRANT ->
  ...
END
```

`REQUIRES` is the same keyword used today for capability constraints on receivers (e.g. `REQUIRES self: MUTABLE`). One more constraint kind: `NON_REENTRANT`. The constraint applies to the binding, not the type — multiple parameters can carry independent constraints, and the type stays a plain `FN(...) -> T`.

A function with no constraint and no `EFFECTS REENTRANT` declaration on a fn-typed parameter is an error (see "Errors" below). The compiler refuses to silently accept arbitrary callbacks because the caller's stack tier depends on whether the callback recurses.

### Call-site override

```
-- Caller decides to trampoline a normally-recursive callee.
-- gas: 1000 = run up to 1000 trampoline iterations before yielding
-- to the scheduler.
result = @thunk(1000) factorial(10);
```

`@thunk(N)` is a prefix to a call expression. Lowering generates the same CPS state machine as `EFFECTS REENTRANT:THUNK`, but produced at the call site. The callee must be `EFFECTS REENTRANT` or already `EFFECTS REENTRANT:THUNK` (call-site overrides on `:TAIL_CALL` are pointless and rejected).

`N` must be a compile-time integer literal (>=1). Default if `@thunk` is written without `(N)`: 256.

## Semantics

### Effect propagation

`REENTRANT` propagates through the call graph (callee REENTRANT => caller REENTRANT) **only for the plain variant**. `THUNK` and `TAIL_CALL` do NOT propagate: a function calling a `:THUNK` callee is not itself reentrant (the thunk's recursion is self-contained on its heap state).

This is the load-bearing rule that lets thunked recursion satisfy `REQUIRES x: NON_REENTRANT`.

### NON_REENTRANT constraint solving

When `foo(callback)` is called with `REQUIRES callback: NON_REENTRANT`, the compiler checks the callback's effective effect:

| Callback effect | Satisfies `NON_REENTRANT`? |
|---|---|
| (no REENTRANT effect) | yes |
| `EFFECTS REENTRANT:TAIL_CALL` | yes |
| `EFFECTS REENTRANT:THUNK` | yes |
| `EFFECTS REENTRANT` | no — error |

For the last case the user must either change the callback's declaration to `:TAIL_CALL` / `:THUNK`, change `foo` to declare `EFFECTS REENTRANT` (and accept the propagated cost), or thunkify the call site: `foo(@thunk(N) callback)`.

### Default lowering for plain REENTRANT

A function with `EFFECTS REENTRANT` and no variant defaults to the `@service` stack tier (2 MB OS thread). Calls into it from a fiber are ABI-compatible — the call goes through `spawnService` if the caller isn't already on a service stack. This is the same machinery that exists today for `@reentrant`; the change is the declaration syntax, not the runtime.

A user who wants a plain REENTRANT function to run on a regular fiber (with stack-smash protection rather than 2 MB pre-allocation) writes:

```
FN walk(...) EFFECTS REENTRANT @size:canSmash -> ...
```

`@size:canSmash` is a function-level annotation that asks for the SafeStack-style guard page + soft overflow detection. The `@canSmash` BG/DO marker we already parse moves to functions in this design; the BG path becomes implicit (whatever the called function asks for).

## Codegen

### TAIL_CALL: self-loop

A tail-call function compiles to a Zig `while (true)` over the parameter slot, with each tail call rewritten as a re-bind + continue.

```
fn sum(n: i64, acc: i64) i64 {
    var n_ = n;
    var acc_ = acc;
    while (true) {
        if (n_ <= 0) return acc_;
        // RETURN sum(n - 1, acc + n);
        const new_n = n_ - 1;
        const new_acc = acc_ + n_;
        n_ = new_n;
        acc_ = new_acc;
        continue;
    }
}
```

`MIR::TailCall` already exists; the stack pass already verifies tail position via `verify_tail_calls`. New work:

- Parser accepts `EFFECTS REENTRANT:TAIL_CALL` and sets `fn_node.tail_call = true`.
- The verifier raises if any recursive call site is NOT a tail call (currently it warns; we promote to a hard error for `:TAIL_CALL` declarations).
- Stack tier stays at `:standard` (or whatever the locals require) — depth is 1.

### THUNK: heap CPS state machine + trampoline

The transform is conceptually identical to the FSM transform we already built — a function body with a "yield" point becomes a state machine. For thunks the yield is the recursive call (instead of an IO/NEXT/lock suspend).

Per `:THUNK` function:

1. **State struct** (`__ThunkFrame_<fn>`) holds:
   - The fn's parameters
   - All cross-segment locals (Liveness analysis, same as FSM)
   - A `step: u8` field
   - A `parent: ?*__ThunkFrame_<fn>` pointer for the call stack
   - A `pending_op: PendingOp` enum (e.g. `multiply_by_n`) for what to do with the recursive return value

2. **Step function** (`runStep<N>(frame: *Self) StepResult`) does one segment of work and returns one of:
   - `Done(value)` — frame completes; trampoline pops the parent and applies `pending_op` to the value
   - `Recurse(new_frame_args, pending_op_for_this_frame)` — push a new frame; trampoline runs that next
   - `Goto(step)` — internal state transition (no recursion, no pop)

3. **Trampoline** (synthesized once, parameterized over the frame type):
   ```zig
   fn trampoline(comptime Frame: type, initial: Frame, gas: u32) Frame.Result {
       var current = initial;
       var remaining = gas;
       while (true) {
           const r = current.step();
           switch (r) {
               .Done => |v| {
                   if (current.parent) |p| {
                       p.apply(v);
                       current = p.*;
                       continue;
                   }
                   return v;
               },
               .Recurse => |new| {
                   // push new frame; old frame already saved its
                   // pending_op; current = new.
                   current = new;
               },
               .Goto => |s| current.step = s,
           }
           remaining -= 1;
           if (remaining == 0) {
               // yield to scheduler; resume reads current state.
               yieldFsm();
               remaining = gas;
           }
       }
   }
   ```

4. **Call site lowering**:
   - Direct call into a `:THUNK` function emits the trampoline with the function's default gas.
   - `@thunk(N) f(...)` overrides the gas at this call site.
   - Inside a recursive `:THUNK` body, recursive calls to the same function compile to `Recurse` returns, NOT a real call. The trampoline pushes the new frame.

5. **Mutual recursion** between two `:THUNK` functions uses a tagged union frame type (`__ThunkFrame = union { fn_a: __ThunkFrame_a, fn_b: __ThunkFrame_b }`). Synthesized when the call graph has a cycle.

### `@thunk(N)` on a plain `EFFECTS REENTRANT` callee

The compiler synthesizes the same state-machine + trampoline at the **call site**. The callee's body is re-lowered through the thunk transform on demand. This is bounded: the thunk transform memoizes per (callee, gas) pair so the second call doesn't re-emit the state struct.

If the callee is `EFFECTS REENTRANT` only (not `:THUNK`), the call-site thunkification is what makes the call non-reentrant from the caller's POV. Without `@thunk(...)`, calling a plain REENTRANT callee from a non-`@service` context is an error (see "Errors").

## Stack-sizing

The stack pass (`compute_stack_tiers!`) gains three rules.

1. **`REENTRANT` (plain)** — function tier is `:service` (unchanged from today's `:unbounded`). Propagates: any caller becomes `:service` unless the call site uses `@thunk(N)`.

2. **`REENTRANT:TAIL_CALL`** — verifier mode tightened: every recursive call site MUST be in tail position. The pass walks the function body's MIR, finds `MIR::Call` to self, and confirms each is wrapped in `MIR::TailCall` (or directly in `MIR::Return`). Failure is a compile error pointing at the non-tail call. Stack tier is computed from locals only (depth=1).

3. **`REENTRANT:THUNK`** — function tier accounts for the thunk state-struct size:

   ```
   tier_bytes = locals_bytes
              + sizeof(__ThunkFrame_<fn>)        # one frame
              + sizeof(__ThunkFrame_<fn>) * 16   # heap overhead estimate
   ```

   The state struct lives on the heap, so it doesn't grow the caller's actual fiber stack. But the `tier_bytes` figure is used by the budget check that says "this function fits in `:standard`" — heap state DOES count against the per-task memory budget the user is reasoning about. Callers don't propagate `:THUNK` size; the heap is per-task isolated.

4. **Call-site `@thunk(N)`** — caller's tier is computed as if calling a `:THUNK` callee directly. The callee's thunk state struct enters the caller's `tier_bytes` calculation; the callee's underlying recursion does NOT.

## Effect propagation rules

The fixed-point pass that propagates effects through the call graph treats the three variants as distinct effect tokens:

```
REENTRANT_PLAIN      transitive  (callee plain => caller plain)
REENTRANT_TAIL_CALL  not transitive
REENTRANT_THUNK      not transitive
```

A function whose computed effect set contains `REENTRANT_PLAIN` either:
- Already declares `EFFECTS REENTRANT` — fine.
- Doesn't declare it — STRICT mode error; `clear fix --effects` adds the clause.

A `:THUNK` or `:TAIL_CALL` function with computed `REENTRANT_PLAIN` from a callee is also an error: "function declares `EFFECTS REENTRANT:THUNK` but transitively calls plain REENTRANT 'foo'. Either thunkify foo (`EFFECTS REENTRANT:THUNK` on foo, or `@thunk(N)` at the call site) or change this function's effect to plain REENTRANT."

## Errors

| Site | Message |
|---|---|
| `FN foo(f: FN(...) -> T)` with no `REQUIRES` and no `EFFECTS REENTRANT` | `'foo' takes function parameter 'f' but does not constrain its reentrance. A reentrant 'f' would silently force 'foo' onto a service stack. Add 'REQUIRES f: NON_REENTRANT' (callable with thunked / tail-call / non-recursive callbacks) or 'EFFECTS REENTRANT' (propagates the cost; foo runs on @service).` |
| Plain `EFFECTS REENTRANT` callee called from non-`@service` context without `@thunk(...)` | `'walk' is reentrant. Calling it here would require a service stack (2 MB OS thread). Use '@thunk(N) walk(...)' to trampoline this call (gas = N iterations between yields), or move 'walk' onto @service explicitly, or declare 'walk' as 'EFFECTS REENTRANT:THUNK' or ':TAIL_CALL'.` |
| `EFFECTS REENTRANT:TAIL_CALL` with a non-tail recursive call | `'sum' is declared TAIL_CALL but the recursive call at line N is not in tail position. <show suggested rewrite>. If the recursion is genuinely non-tail, declare ':THUNK' instead — it handles arbitrary recursion at the cost of a heap state-struct.` |
| `REQUIRES f: NON_REENTRANT` violated by passing a plain REENTRANT fn | `'cb' is 'EFFECTS REENTRANT' but 'foo' requires 'cb: NON_REENTRANT'. Wrap the call: 'foo(@thunk(N) cb_fn)', or change 'cb_fn' to 'EFFECTS REENTRANT:THUNK' / ':TAIL_CALL'.` |
| `@thunk(N)` on a non-recursive callee | (warning) `'@thunk(...)' on 'leaf' is a no-op: 'leaf' is not declared reentrant. Remove the prefix.` |
| `@thunk(N)` with N <= 0 or non-literal | `'@thunk(...)' requires a positive integer literal for the gas budget.` |

## `clear fix` migrations

Three new categories.

1. **`@reentrant` annotation -> `EFFECTS REENTRANT`**
   ```
   - @reentrant FN walk(node: *Node) RETURNS Void ->
   + FN walk(node: *Node) RETURNS Void
   +   EFFECTS REENTRANT ->
   ```
   Fully mechanical. Detect via the AST node's existing `reentrant: :reentrant` field; rewrite the surface form.

2. **`@reentrant:tailCall` -> `EFFECTS REENTRANT:TAIL_CALL`** — same shape.

3. **Unconstrained FN-typed parameter -> add `REQUIRES f: NON_REENTRANT`**
   ```
   - FN map(items: Int64[], f: FN(Int64) -> Int64) RETURNS Int64[] ->
   + FN map(items: Int64[], f: FN(Int64) -> Int64) RETURNS Int64[]
   +   REQUIRES f: NON_REENTRANT ->
   ```
   The legacy form `FN(...)@nonReentrant` doesn't exist in the parser
   (only `FN(...)@reentrant` does -- opt-in for reentrant callbacks).
   Today's implicit default for FN-typed parameters is non-reentrant;
   Phase 1.5 makes that default explicit. The fix is auto-confidence
   (defaults to NON_REENTRANT) and skips parameters that already carry
   `@reentrant` on the type or where the enclosing function declares
   `EFFECTS REENTRANT` (propagation case). Phase 2 escalates the same
   detection from info to warning to error.

4. **Unconstrained fn parameter** — interactive fix offers two options:
   ```
   error: 'callIt' takes 'f: FN(Int64) -> Int64' but does not constrain reentrance.
     suggested fixes:
       [1] add 'REQUIRES f: NON_REENTRANT'           (most callers)
       [2] add 'EFFECTS REENTRANT' to callIt          (if callbacks may recurse)
   ```
   `clear fix` defaults to (1) in non-interactive mode; (2) is selected when the function body itself is REENTRANT.

5. **Plain REENTRANT callee called from a non-service context** — fix offers two options:
   ```
   error: 'consume' is reentrant; this call needs a service stack or @thunk.
     suggested fixes:
       [1] @thunk(256) consume(arg)                   (trampoline at call site)
       [2] declare 'consume' as 'EFFECTS REENTRANT:THUNK' (trampoline always)
   ```

The fix infrastructure (Phase A/B/C done in tasks #61-#64) takes a new "fixer" entry per category. Errors emit machine-readable spans + the same hint text the user sees in CLI output.

## Validation: TAIL_CALL is actually tail-called

`stack_verifier.rb` already has `verify_tail_calls`. Today it walks emitted Zig and asserts that every `tail_call` function returns at every tail-position site. We tighten:

1. For `EFFECTS REENTRANT:TAIL_CALL` declarations, verify EVERY recursive call to self is in tail position. Today the check is "if you said tail_call, all your tail-position calls are; we don't check non-tail recursive calls aren't there". Promote that gap to a hard error.

2. The verifier's existing trampoline-as-leaf treatment (line 280) extends to `:THUNK` functions: their state-machine bodies are leaves from the caller's stack-pass perspective.

3. The verifier emits per-fn artifacts:
   - `:TAIL_CALL` => `verified_tail_call: true | false`
   - `:THUNK` => `thunk_state_bytes: N`
   - Callers consume these to compute their own tier.

## Implementation plan (phased)

Each phase is a green commit; nothing breaks behavior until phase 4.

**Phase 1 — surface syntax + fix migrations** (no behavior change)
- Parser accepts `EFFECTS REENTRANT[:TAIL_CALL|:THUNK]` and `REQUIRES x: NON_REENTRANT`.
- Annotator stores them as `fn_node.effects_decl` and `fn_node.requires_clauses[<name>]`.
- `clear fix` migrations 1-3 (mechanical) land.
- The old `@reentrant` annotation continues to work, lowered to `EFFECTS REENTRANT` internally.
- All existing tests pass; 0 new functional behavior.

**Phase 2 — error coverage** (warnings -> errors after a soft-deprecation window)
- Unconstrained fn parameter (error #1 above) is a warning at this phase, error in phase 3.
- `clear fix` migrations 4-5 (interactive) land.
- The warning fires on the corpus and we audit which side users naturally pick.

**Phase 3 — TAIL_CALL strictness**
- Stack verifier promotes "non-tail recursive call inside `:TAIL_CALL`" to a hard error.
- A handful of stdlib functions get migrated to `:TAIL_CALL` explicitly (sumLoop, etc.).

**Phase 4 — THUNK lowering**
- New MIR pass `thunk_transform.rb` (mirrors `fsm_transform/` structure):
  - `RecursiveSplitter` adapted: pivots on recursive calls, segments the body around them.
  - `Liveness` reused (cross-segment vars become frame fields).
  - `Emit.build_thunk_recursive` produces `__ThunkFrame_<fn>` + `runStep<N>` + trampoline.
- Stack-sizing rule for `:THUNK` lands.
- `@thunk(N)` call-site override lands.
- New transpile-tests: factorial, fibonacci, mutual recursion, 1M-deep recursion under fixed gas.

**Phase 5 — service-stack reduction**
- `EFFECTS REENTRANT:TAIL_CALL` and `:THUNK` no longer force `:service`.
- Plain `EFFECTS REENTRANT` still does, but `clear fix` audit nudges the corpus toward variants.
- Benchmarks: deep recursion under THUNK should beat the fiber-stack version on memory; TAIL_CALL should match a hand-written loop.

## Resolved decisions

Resolved against CLEAR's principle order: **correct > safe > understandable (predictable, maximum local reasoning, declarative over "exactly how") > scalable**. The meta-rule is to minimize global complexity; we accept slowdown or extra memory when it makes the system safer or easier to reason about.

### 1. Mutual recursion between `:THUNK` and plain `:REENTRANT`

> If `A: REENTRANT:THUNK` calls `B: REENTRANT`, what happens?

**Decision: error at A's declaration. The user breaks the chain locally with `@thunk(N)` at the call to B, or by changing B's declaration.**

Reasoning, in principle order:
- *Correct:* `B` consumes real stack; `A` declared `:THUNK` (claiming non-contagious). Silent acceptance would lie about A's effect. The effect propagation pass detects this and fails the build.
- *Safe:* the only stack-correct outcomes are "A propagates" or "A thunkifies B". Both are explicit choices; neither is a default the compiler picks for the user.
- *Local reasoning:* looking at A's body must explain A's stack behavior. `@thunk(N) B(...)` at the call site is right there in A's body — no signature gymnastics on B required.
- *Predictable:* a transitive plain-REENTRANT in any `:THUNK` body is always an error. One rule, one error message; no contextual exceptions.

Implementation: the propagation pass already computes effects transitively. Add the check: if `fn_node.effects_decl` is `REENTRANT_THUNK` or `REENTRANT_TAIL_CALL` and the transitive set contains `REENTRANT_PLAIN` from a callee that isn't being thunkified at a call site, error.

### 2. Generic functions over recursion variants

> Does `map<T>(items: T[], f: FN(T) -> T)` get an implicit `REQUIRES f: NON_REENTRANT`?

**Decision: no implicit constraints. Generics use the same constraint rules as concrete functions; instantiation is type-substitution only.**

Reasoning:
- *Correct:* an implicit `NON_REENTRANT` would silently reject reentrant callbacks at instantiation sites with no surface trace. An implicit `EFFECTS REENTRANT` would silently push every `map<T>` instantiation onto `@service`. Neither is sound by default — they're behavioral choices the author has to make.
- *Local reasoning:* `map<T>`'s declaration must explain how it treats `f`. Reading the signature should be enough; the user shouldn't have to remember "generics get implicit constraints" as a separate rule.
- *Declarative over imperative:* the constraint is a property of the function, declared once. No instantiation-time inference.
- *Minimize global complexity:* zero new mechanism. Generic instantiation is type substitution; the constraint travels verbatim. The error message at the unconstrained-fn-param site (Phase 2) fires identically for generic and non-generic functions.

Implementation: nothing generic-specific. The "unconstrained fn parameter" warning/error fires on `map<T>` exactly like on `map_int`.

### 3. Gas accounting for nested thunks

> If `thunkA` calls `@thunk(M) thunkB`, do they share gas or each get their own?

**Decision: single shared gas counter, threaded down through nested trampolines. The outermost `@thunk(N)` (or `:THUNK` fn's declared default at first entry) sets the budget. Inner `@thunk(M)` annotations are warnings ("redundant; outer trampoline already controls gas"); the outer gas wins.**

Reasoning:
- *Correct:* cooperative scheduling depends on bounded time-between-yields. The original "each gets their own" gives `N * M * ...` between yields — unbounded by user-visible numbers.
- *Safe:* a runaway nested computation always yields within `N` iterations. No fairness footgun. Aligns scheduler behavior with the scheduler's contract.
- *Predictable / local reasoning:* `@thunk(N)` at the call site means "this entire subtree of work yields every N iterations". One number, one mental model. Reading the call site tells you exactly when it yields.
- *Scalable:* scheduler fairness preserved at any nesting depth. We accept the small overhead of threading the counter down (a `*u32` parameter on the trampoline).

The cost: trampoline parameter list grows by a `*gas` pointer. The internal step functions don't change — only the trampoline reads/decrements gas.

The redundancy warning: `@thunk(M)` on a call inside an active trampoline frame fires `warn: '@thunk(M)' is redundant inside an active trampoline; outer gas budget (N) controls scheduling`. This is information for the reader, not a behavior change — it nudges the source toward the principle "set gas at the boundary, not in the middle".

Implementation: the trampoline takes `gas: *u32` instead of `gas: u32`; nested `@thunk` call sites that detect they're already inside a trampoline (via comptime parameter or runtime flag) skip starting a new trampoline and just call into the inner state machine with the same gas pointer.

### 4. `@thunk` on EXTERN

> What happens with `@thunk(N) some_extern_call(...)`?

**Decision: hard error at parse / annotate time. EXTERN bodies are opaque; there is no body to thunkify.**

Error: `cannot @thunk an EXTERN function: 'foo' has no CLEAR body to lower into a state machine. Use a CLEAR wrapper around the EXTERN call (with EFFECTS EXTERN) and @thunk that wrapper if you need cooperative yield around long-running EXTERN work.`

Reasoning:
- *Correct:* trivially.
- *Understandable:* the error names the workaround (wrap in CLEAR, thunkify the wrapper). User has a clear path forward.
- *No special case in the lowering:* the thunk transform never sees EXTERN; the error is at the constraint-check phase before lowering.

### 5. Error propagation through the trampoline

> A `:THUNK` body that errors mid-recursion has a chain of heap frames; how does the error unwind them?

**Decision: piggyback on the FSM cleanup pipeline we already have. Each frame is a `runStep<N>`-style state machine with the same cross-segment cleanup rules. The trampoline's `Err(e)` handling pops frames in reverse, invoking each frame's `destroyFrame` hook on the way out. The same `check_fsm_cleanup_invariant!` checker applies.**

Reasoning:
- *Correct:* every allocation made by a frame is released exactly once on every path (success / error / yield-then-cancel). The MIR Cleanup machinery + FSM cleanup invariant already guarantees this for FSM bodies; thunks reuse it.
- *Safe:* no frame leaks on error, no double-free, no UAF. The invariant catches future regressions.
- *Minimize global complexity:* zero new cleanup mechanism. We rename the field from `ctx[:fsm_destroy_lines]` to `ctx[:task_destroy_lines]` (covers both FSM tasks and thunk frames) and reuse the same `:lock` / `:capture` / `:body` ordering.
- *Local reasoning:* one rule for cleanup ("cross-segment / cross-frame cleanups go in destroyTask / destroyFrame, never as `defer` inside a step fn") covers BG bodies and thunk bodies uniformly. Users learn it once.

Concrete shape:

```
StepResult = union {
    Done: T,
    Recurse: NextFrameArgs,
    Goto: u8,                  -- internal transition
    Err: anyerror,             -- propagate up the frame chain
};

// Trampoline (synthesized once per frame type):
while (true) {
    const r = current.step();
    switch (r) {
        .Done => |v| { /* pop parent + apply pending op */ },
        .Recurse => |args| { /* push new frame */ },
        .Goto => |s| current.step = s,
        .Err => |e| {
            // Unwind: pop frames in reverse, calling destroyFrame
            // (which runs ctx[:task_destroy_lines] for that frame).
            while (current.parent) |p| {
                current.destroyFrame();
                alloc.destroy(current);
                current = p;
            }
            current.destroyFrame();
            return e;
        }
    }
    if ((gas.* -= 1) == 0) { yield; gas.* = initial_gas; }
}
```

For the MVP we omit per-frame `try/catch` (no in-frame error recovery; an error always unwinds the whole trampoline). When CLEAR's `try/catch` lands inside `:THUNK` bodies, we add a `Catch(handler_step)` pending-op that the unwind loop honors instead of unconditionally popping.

### Summary of decisions

| Question | Resolution | Why (lead principle) |
|---|---|---|
| Mixed THUNK/REENTRANT mutual recursion | Hard error; `@thunk(N)` at boundary is the explicit fix | Correctness — silent acceptance would misreport effects |
| Generic recursion-variant inference | None; constraints are explicit and uniform | Local reasoning — the signature is the contract |
| Nested-thunk gas | Shared counter, threaded down; inner `@thunk` is a warning | Predictability — one budget, one mental model |
| `@thunk` on EXTERN | Hard error with workaround in the message | Understandability — name the workaround |
| Error propagation | Reuse FSM cleanup pipeline; rename to `task_destroy_lines` | Minimize global complexity — one rule covers both |
