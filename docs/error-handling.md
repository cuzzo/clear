# Error Handling

CLEAR uses **error unions** — errors are returned by value, not thrown. There is no stack unwinding, no hidden cost, and no `if err != nil` boilerplate.

The most important thing to know: **the compiler handles error propagation for you by default.** If you call a function that can fail and don't handle the error, the compiler automatically propagates it to your caller. You only write explicit error handling when you want to *change* the default behavior.

## Automatic Error Propagation

This is CLEAR's most important error handling feature. Consider:

```ruby clear illustrative
FN compute(x: Float64) RETURNS !Float64 ->
    half = divide(x, 2.0);      -- if divide fails, compute fails too
    quarter = divide(half, 2.0); -- same here
    RETURN quarter;
END
```

You don't need `OR RAISE` on every call. The compiler sees that `divide` can fail, and automatically emits error propagation (Zig's `try`) for unhandled error unions. The function's return type `!Float64` tells callers that `compute` can fail.

This means:
- **You write the happy path.** The compiler ensures errors propagate safely.
- **You only write `OR` when you want to *handle* the error** — provide a fallback, silence it, or do something specific.
- **No Go-style `if err != nil` on every line.** No Rust-style `?` on every call. Just write your code.

The compiler computes `can_fail` for every function via a call-graph fixed-point pass. If a function allocates, calls a function that can fail, or contains a `RAISE`, it `can_fail` — and the return type is automatically widened to `!T`.

## Error Unions (`!T`)

A function that can fail declares its return type with the `!` prefix:

```ruby clear illustrative
FN divide(a: Float64, b: Float64) RETURNS !Float64 ->
    IF b == 0.0 -> RAISE "Division by zero";
    RETURN a / b;
END
```

`!Float64` means "returns either a `Float64` or an error." Under the hood, this compiles to Zig's `anyerror!f64` — a zero-cost tagged union where the happy path has no overhead.

### RAISE

`RAISE` signals an error from inside a function:

```ruby clear illustrative
RAISE "Out of bounds";
```

The string is a human-readable message. Control flow returns immediately to the caller with an error value. There is no stack unwinding — it's a normal return with the error variant of the union.

## Handling Errors: The OR Operator

When you *do* want to handle an error (instead of letting it propagate), use `OR`:

### OR *value* — Provide a fallback

```ruby clear illustrative
val = divide(10.0, 0.0) OR 0.0;
-- val is guaranteed to be Float64 (0.0 if divide failed)
```

The most common pattern. If the left side fails, use the right side instead. The result type is always the payload type (`Float64`), never an error union.

### OR RAISE — Propagate explicitly

```ruby clear illustrative
FN compute(x: Float64) RETURNS !Float64 ->
    half = divide(x, 2.0) OR RAISE;
    RETURN half * 2.0;
END
```

Identical to automatic propagation, but makes the error path visible in the source. Use this when you want to document that a specific call can fail, even though the compiler would handle it automatically.

### OR PASS — Silence the error

```ruby clear illustrative
val = risky_operation() OR PASS;
```

Ignores the error and uses an undefined/default value. **Use with extreme caution** — this is the closest thing CLEAR has to swallowing an exception. It exists for low-level scenarios where failure is acceptable and the value is never read on the error path.

### OR PRUNE — Filter in concurrent pipelines

```ruby clear illustrative
results = data s> CONCURRENT(workers: 4) SELECT process(_) OR PRUNE;
```

Specific to `CONCURRENT` pipelines. If an item causes an error, it is dropped from the result set rather than failing the whole pipeline. The output array will have fewer elements than the input.

### Quick reference

| Syntax | Behavior | Result type | Use when |
|---|---|---|---|
| *(no handler)* | Auto-propagate to caller | `!T` | Default — let errors bubble up |
| `expr OR value` | Use fallback on error | `T` | You have a sensible default |
| `expr OR RAISE` | Propagate explicitly | `!T` | You want the error path visible in source |
| `expr OR PASS` | Silence, use undefined | `T` | Low-level code where failure is OK |
| `expr OR PRUNE` | Drop item from pipeline | `T[]` (shorter) | Concurrent pipelines with acceptable failures |

## Errors in Concurrency

### BG (Background Fibers)

When a BG fiber fails, the error is captured in the promise. It surfaces when you `NEXT` the promise:

```ruby clear illustrative
p = BG { divide(10.0, 0.0); };
result = NEXT p OR 0.0;  -- handle the error from the fiber
```

### DO (Fork-Join)

DO blocks wait for all branches. If any branch fails, the error propagates after all branches complete.

### CONCURRENT Pipelines

CONCURRENT pipelines support two error strategies:

```ruby clear illustrative
-- Strategy 1: Fail the whole pipeline on first error
results = items s> CONCURRENT(workers: 4) SELECT process(_) OR RAISE;

-- Strategy 2: Skip failed items, keep the rest
results = items s> CONCURRENT(workers: 4) SELECT process(_) OR PRUNE;
```

`OR RAISE` propagates the first error encountered. `OR PRUNE` silently drops failed items. Without either, errors auto-propagate (same as `OR RAISE`).

## Design Principles

### No Unwinding

CLEAR does not use stack unwinding (C++ exceptions, Java throws). Errors are returned by value as part of a sum type (error union). This means:
- **Deterministic performance**: No hidden cost for the error path.
- **Explicit control flow**: You can see exactly where a function might fail.
- **Tiny binaries**: No exception-handling tables.

### Zero-Cost Happy Path

Error unions are a tagged union — an integer error code plus the payload. On the happy path, the error code is zero and the payload is used directly. There is no allocation, no vtable lookup, no string formatting unless you explicitly `RAISE`.

### Errors Are Values

Because errors are values (not control flow exceptions), they compose naturally with CLEAR's pipeline system. `OR PRUNE` in a `CONCURRENT SELECT` is just a value-level filter — no special exception-catching machinery.

## Implementation Status

| Feature | Status |
|---|---|
| Error unions (`!T`) | **v0.1** — shipping |
| `RAISE` | **v0.1** — shipping |
| `OR value` (fallback) | **v0.1** — shipping |
| `OR RAISE` (propagate) | **v0.1** — shipping |
| `OR PASS` (silence) | **v0.1** — shipping |
| `OR PRUNE` (concurrent filter) | **v0.1** — shipping |
| Automatic error propagation | **v0.1** — shipping |
| `OR EXIT` (fatal termination) | v0.2 — planned |
| `!!` (explicit panic/unwrap) | v0.2 — planned |
| `CATCH` blocks (pattern-matched error handling) | v0.2 — planned |
| Custom error types | v0.2 — planned |
