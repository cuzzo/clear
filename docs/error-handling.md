# Error Handling in CLEAR

CLEAR treats error handling as a first-class control flow construct. By leveraging Zig's **Error Unions** under the hood, CLEAR provides the safety of explicit error handling without the boilerplate of `if err != nil`.

## The Core Principle: No Unwinding
Unlike C++ or Java, CLEAR does **not** use stack unwinding for exceptions. Errors are returned by value as part of a **Sum Type** (an Error Union). This ensures:
1.  **Deterministic Performance**: No "hidden" cost for throwing an error.
2.  **Explicit Control Flow**: You can see exactly where a function might fail.
3.  **Tiny Binaries**: No bulky exception-handling tables required.

## 1. Error Unions (`!T`)
A function that can fail is declared with the `!` prefix on its return type.

```clear
-- Returns either a Number or an Error
FN divide(a: Number, b: Number) RETURNS !Number ->
    IF b == 0.0 THEN
        RAISE "Division by Zero";
    END
    RETURN a / b;
END
```

In the Zig transpilation, this becomes `anyerror!f64`.

## 2. The `OR` Operator (Railway Oriented Programming)
The most common way to handle errors in CLEAR is the `OR` operator. It allows you to provide a "fallback" path in a single line.

### `OR default` (Fallback)
If the left-hand side fails, use the right-hand side value.
```clear
-- val is guaranteed to be a Number
val = divide(10.0, 0.0) OR 0.0;
```
*Transpilation: `(divide(10.0, 0.0) catch 0.0)`*

### `OR RAISE` (Bubble Up)
Propagate the error to the caller (equivalent to Zig's `try`).
```clear
-- This function must also return !T
FN process(x: Number) RETURNS !Number ->
    res = divide(x, 2.0) OR RAISE;
    RETURN res * 2.0;
END
```
*Transpilation: `try divide(x, 2.0)`*

### `OR PASS` (Silence)
Ignore the error and use an undefined/default value. Useful only in low-level scenarios where failure is acceptable and handled elsewhere.
```clear
val = risky_operation() OR PASS;
```
*Transpilation: `(risky_operation() catch undefined)`*

### `OR PRUNE` (Filter)
Specific to `CONCURRENT` pipelines. If an item causes an error, it is simply dropped from the result set rather than failing the whole pipeline.
```clear
results = data s> CONCURRENT SELECT process(_) OR PRUNE;
```

### `OR EXIT` (Fatal)
Terminate the program with a message if the operation fails.
```clear
file = File.open("config.json") OR EXIT "Missing config file";
```

## 3. Explicit Panic (`!!`)
If you are 100% certain an operation cannot fail (or if failing means the program state is unrecoverable), use the `!!` suffix.

```clear
-- Panics at runtime if the operation fails
val = critical_operation()!!;
```
*Transpilation: `(critical_operation() catch unreachable)`*

## 4. `CATCH` Blocks
For complex error handling, CLEAR supports `CATCH` blocks at the end of functions or in `MATCH` statements.

```clear
FN main() RETURNS Void ->
    res = divide(10.0, 0.0);
CATCH err WITH "Division by Zero"
    log("Caught division error");
DEFAULT
    log("Unknown error occurred");
END
```

## Transpiler Implementation
CLEAR's transpiler performs **Automatic Error Propagation**. If a function call can return an error and you do *not* handle it with an `OR` operator, the transpiler automatically emits a `try` in the generated Zig code.

This means you only write `OR RAISE` when you want to be explicit, but the compiler ensures safety by default.

### Key implementation details:
*   **Railway logic**: The `OR` operator acts as a "switch" that diverts the execution flow to the error path.
*   **Zero-Cost**: Since Zig error unions are just an integer (the error code) plus the payload, there is zero overhead for the "Happy Path."
*   **Compile-Time Safety**: The `SemanticAnnotator` tracks `can_fail` for every function and ensures that errors are either handled or propagated.
