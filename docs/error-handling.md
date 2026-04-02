# Error Handling

CLEAR uses **error unions** -- errors are returned by value, not thrown. There is no stack unwinding, no hidden cost, and no `if err != nil` boilerplate.

The most important thing to know: **the compiler handles error propagation for you by default.** If you call a function that can fail and don't handle the error, the compiler automatically propagates it to your caller. You only write explicit error handling when you want to *change* the default behavior.

## The 6 Error Kinds

HTTP status codes run the most complicated distributed system ever built using 5 categories: 1xx informational, 2xx success, 3xx redirect, 4xx client error, 5xx server error. Infinite specific error codes collapse into a handful of *intents* -- and the caller almost always only cares about the intent, not the specific code.

CLEAR applies the same principle. Every error has a **Kind** that tells the caller what to do about it:

| Kind | Intent | Caller action | HTTP analog |
|---|---|---|---|
| `Transient` | Temporary failure, try again | Retry with backoff | 503 Service Unavailable |
| `Input` | Caller sent bad data | Fix the input and retry | 400 Bad Request |
| `System` | Infrastructure failure | Stop, alert, escalate | 500 Internal Server Error |
| `NotFound` | Resource doesn't exist | Create it or use a default | 404 Not Found |
| `Permission` | Not authorized | Re-authenticate or abort | 403 Forbidden |
| `Canceled` | Operation was canceled | Clean up and stop | 499 Client Closed |

Six categories. That's it. Every error in every CLEAR program falls into one of these.

### Why not infinite error types?

Languages with infinite error types (Java's checked exceptions, Rust's custom enums) create infinite branching. Every function in the call chain must decide what to do with `HttpTimeoutError` vs `DnsResolutionError` vs `TlsHandshakeError`. But the answer is almost always the same: **retry** (they're all transient).

CLEAR collapses the error space at the point of creation, not the point of handling. The function that *raises* knows whether the failure is transient, and tags it. The caller doesn't need to enumerate every possible failure mode.

### Specific errors as subtypes

You can optionally name a specific error within a kind:

```clear
-- ILLUSTRATIVE
RAISE Transient, Timeout, "connection timed out after 30s";
RAISE Transient, DnsFailure;
RAISE Input, InvalidJson, "expected { at position 0";
RAISE NotFound;
```

The specific error (`Timeout`, `DnsFailure`, `InvalidJson`) is available in CATCH blocks via `WITH(ErrorName)` for the rare case where you need fine-grained matching. But the default path just matches on Kind.

## Automatic Error Propagation

```clear
-- ILLUSTRATIVE
FN compute(x: Float64) RETURNS !Float64 ->
    half = divide(x, 2.0);
    quarter = divide(half, 2.0);
    RETURN quarter;
END
```

You don't need `OR RAISE` on every call. The compiler sees that `divide` can fail, and automatically emits error propagation. `!Float64` tells callers that `compute` can fail.

## RAISE

`RAISE` signals an error with a Kind, optional specific name, and optional message:

```clear
-- ILLUSTRATIVE
RAISE Input, InvalidJson, "expected { at position 0";
RAISE Transient, Timeout;
RAISE Input, "bad data";
RAISE NotFound;
RAISE "something went wrong";
```

## Handling Errors: The OR Operator

### OR *value* -- Provide a fallback

```clear
-- ILLUSTRATIVE
val = divide(10.0, 0.0) OR 0.0;
```

### OR RAISE -- Propagate explicitly

```clear
-- ILLUSTRATIVE
half = divide(x, 2.0) OR RAISE;
```

### OR EXIT "message" -- Annotate and propagate

```clear
-- ILLUSTRATIVE
parsed = parseHeader(data) OR EXIT "failed at header parsing";
```

Sets the error context message, then propagates. Useful in pipelines where you want to know *which step* failed.

### OR PASS -- Silence the error

```clear
-- ILLUSTRATIVE
val = risky_operation() OR PASS;
```

### OR PRUNE -- Filter in concurrent pipelines

```clear
-- ILLUSTRATIVE
results = data s> CONCURRENT(workers: 4) SELECT process(_) OR PRUNE;
```

### RECOVER(default) -- Pipeline error recovery

```clear
-- ILLUSTRATIVE
result = fetchData(url) s> RECOVER(defaultData());
```

### Quick reference

| Syntax | Behavior | Use when |
|---|---|---|
| *(no handler)* | Auto-propagate | Default -- let errors bubble up |
| `OR value` | Use fallback | You have a sensible default |
| `OR RAISE` | Propagate explicitly | You want the error path visible |
| `OR EXIT "msg"` | Annotate + propagate | Pipeline step identification |
| `OR PASS` | Silence | Low-level code, failure is OK |
| `OR PRUNE` | Drop from pipeline | Concurrent pipelines |
| `s> RECOVER(val)` | Pipeline fallback | Error recovery in chains |

## CATCH Blocks

CATCH blocks go at the bottom of a function, before `END`. They match on error Kind and optionally on specific error names:

```clear
-- ILLUSTRATIVE
FN fetchAndParse(url: String) RETURNS String ->
    data = fetch(url) OR RAISE;
    parsed = parse(data) OR EXIT "parse step failed";
    RETURN transform(parsed);

CATCH Transient
    RETURN "service unavailable, try again";
CATCH Input WITH(InvalidJson)
    RETURN "bad json from " + url;
DEFAULT
    RETURN "unknown error";
END
```

Rules:
- CATCH can only appear at the **bottom** of a function, after all body statements
- Multiple CATCH clauses are checked in order
- `CATCH Kind` matches any error with that kind
- `CATCH Kind WITH(ErrorName)` matches kind + specific error
- `DEFAULT` catches everything not matched above
- `__error` is available in CATCH bodies with `.kind`, `.error_name`, `.message`, `.snapshot`

### Error Snapshots in Pipelines

When an error occurs inside a pipeline, the ErrorContext's `.snapshot` field captures the element that caused the failure:

```clear
-- ILLUSTRATIVE
data s> WHERE validate(_) OR PRUNE;
```

Snapshots are heap-allocated. If allocation fails during error handling, snapshot is null -- the error still propagates, you just lose the debug data.

## Design Principles

### Collapsed Error Space

Infinite error types create infinite branching. CLEAR collapses errors into 6 Kinds based on caller intent. This is the same insight that made HTTP status codes work for 30+ years: the caller almost never needs to know the *specific* failure, just what to *do* about it.

### No Unwinding

Errors are returned by value. No hidden cost, explicit control flow, tiny binaries.

### Zero-Cost Happy Path

Error unions are a tagged union. On the happy path, the error code is zero and the payload is used directly. No allocation, no vtable lookup, no string formatting unless you explicitly `RAISE`.

### Errors Are Values

Because errors are values, they compose naturally with pipelines. `OR PRUNE` is just a value-level filter. `RECOVER(default)` is just `catch`. No special exception machinery.
