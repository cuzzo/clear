# CLEAR Test Framework

## Vision

CLEAR's test framework is built into the language. No external test runner, no
separate assertion library, no mocking framework to install. The compiler knows
your code's types, capabilities, effects, and call graph -- and uses that
knowledge to make testing automatic where possible and simple where it's not.

```
TEST UserService DO
  store: HashMap<User>@sharded(8):locked = {};

  WHEN "create" DO
    TEST THAT "creates a user" DO
      result = createUser!(store, "alice", 30);
      ASSERT result.name == "alice";
      ASSERT result.age == 30;
    END

    TEST THAT "rejects duplicate names" DO
      createUser!(store, "bob", 25);
      ASSERT_RAISES Input, createUser!(store, "bob", 25);
    END

    BENCHMARK createUser!(store, "alice", 30) x10000;
    SMASH createUser!(store, "alice", 30);
  END
END
```

```bash
clear test myfile.clear               # run TEST THAT blocks (correctness)
clear benchmark myfile.clear          # run BENCHMARK + SMASH blocks (performance)
clear test myfile.clear --profile     # run tests with allocation profiling
```

## Why CLEAR can do this

Other languages need external mock frameworks because the compiler doesn't know
enough about the code to help. CLEAR's compiler knows:

- **Every function's effects**: allocates? blocks? recursive? calls extern?
- **Every variable's capability**: shared? locked? sharded? multiowned?
- **The full call graph**: who calls whom, transitively
- **IO boundaries**: which functions touch the network vs filesystem vs pure compute

This means the compiler can:
1. Auto-generate stubs for all IO at the language boundary
2. Make private functions visible for testing without runtime reflection
3. Generate adversarial inputs for sharded maps (SMASH)
4. Measure allocation/timing without user instrumentation (BENCHMARK)
5. Suggest capability changes based on profiling data (PROFILE)

## Test DSL

### TEST block

```
TEST <name> DO
  -- setup code: runs before each WHEN block
  store: HashMap<String> = {};

  WHEN <description> DO
    -- nested setup: runs before each TEST THAT in this group
    store["key"] = "value";

    TEST THAT <description> DO
      -- test body: assertions here
      ASSERT store.contains?("key");
    END

    TEST THAT <description> DO
      ASSERT store["key"] OR "" == "value";
    END
  END
END
```

**Execution model:**
- Each `TEST THAT` block runs in isolation (fresh setup)
- Setup code (between `TEST...DO` and first `WHEN`) runs before each group
- WHEN-level setup runs before each test in that group
- All state is reset between test blocks (arena rewind)

**Transpilation:**
- `TEST name DO ... END` becomes a Zig `test "name" { ... }` block
- Each `TEST THAT` becomes a separate scope with setup replay
- `WHEN` groups share setup but each test gets its own execution

### ASSERT variants

```
ASSERT condition;                         -- fails with generic message
ASSERT condition, "message";              -- fails with custom message
ASSERT_RAISES Kind, expression;           -- expects a RAISE of the given kind
ASSERT_RAISES Kind, ErrorName, expr;      -- expects specific error kind + name
```

### BENCHMARK and SMASH

```
TEST MyServer DO
  store: HashMap<String>@sharded(32):locked = {};

  WHEN "performance" DO
    BENCHMARK process(store, data) x10000;
    -- Output:
    --   BENCHMARK process x10000:
    --     Time:    0.8ms avg (0.6ms p50, 2.1ms p99)
    --     Allocs:  3 per call (144 bytes)
    --     Arena:   4 KB high-water

    SMASH process(store, data);
    -- Output:
    --   SMASH process — shard skew attack:
    --     Generated 1000 keys routing to shard 0 (of 32)
    --     Before: 890ms (serialized on shard 0)
    --     After:  32ms (runtime auto-fixed)
  END
END
```

`BENCHMARK` and `SMASH` blocks only run under `clear benchmark`, not `clear test`.
This keeps correctness tests fast.

## Stubbing and Mocking

### The problem

Testing network services requires intercepting IO. In most languages this means
dependency injection, interface indirection, or runtime monkey-patching. All add
complexity to production code for the sake of testing.

### CLEAR's approach: compile-time stub injection

Every IO function in CLEAR (network, filesystem) goes through a known set of
runtime functions: `tcpRead`, `tcpWrite`, `accept`, `readFile`, `writeFile`, etc.
The compiler knows which functions have the `EXTERN` or `BLOCKING` effect.

In test mode (`clear test`), the compiler can replace these with stubs:

```
TEST HttpHandler DO
  -- STUB replaces the real implementation for this test scope
  STUB tcpRead RETURNS "GET /api/users HTTP/1.1\r\n\r\n";
  STUB tcpWrite CAPTURES output;

  TEST THAT "handles GET request" DO
    handleClient!(client);
    ASSERT output.contains?("200 OK");
  END
END
```

**How it works:**
1. The compiler sees `STUB tcpRead RETURNS <value>`
2. In the transpiled Zig, calls to `tcpRead` within this TEST scope are replaced
   with a function that returns the stubbed value
3. No production code changes. No interfaces. No dependency injection.

The Zig transpilation makes all CLEAR functions visible (Zig has no access
control within a file). Private functions in CLEAR emit `fn` (not `pub fn`) but
are still callable from test code in the same compilation unit. The transpiler
emits a `// visible for testing` comment on private functions in test mode.

### STUB variants

```
-- Return a fixed value
STUB tcpRead RETURNS "response data";

-- Return different values on successive calls
STUB tcpRead SEQUENCE ["first", "second", ""];

-- Capture what was written
STUB tcpWrite CAPTURES output;

-- Custom function replacement
STUB readFile WITH %(path: String) -> "mock content";

-- Stub a specific method on a type
STUB UserService.validate WITH %(user: User) -> TRUE;
```

### What can be stubbed

| Category | Functions | Effect |
|----------|-----------|--------|
| Network read | `tcpRead`, `socketRead` | BLOCKING |
| Network write | `tcpWrite`, `socketWrite` | BLOCKING |
| Network accept | `accept` | BLOCKING |
| Network connect | `connect` | BLOCKING |
| File read | `readFile`, `listDir`, `listAll` | EXTERN |
| File write | `writeFile` | EXTERN |
| User functions | Any function by name | Any |

The compiler knows which functions have IO effects. A future `clear test --strict`
mode could require ALL IO functions to be stubbed, guaranteeing tests are pure
and deterministic.

### Private function access in tests

CLEAR has three visibility levels: `PUB`, `PRIVATE`, and package (default).

In test mode, ALL functions are accessible:

```
-- In src/user.clear:
PRIVATE FN validateEmail(email: String) RETURNS Bool ->
    RETURN email.contains?("@");
END

-- In test/user_test.clear:
TEST validateEmail DO
  TEST THAT "rejects invalid email" DO
    ASSERT validateEmail("not-an-email") == FALSE;
  END
END
```

**Implementation:** The transpiler already controls visibility via `pub fn` vs `fn`.
In test mode (`--test`), it emits all functions as `pub fn` regardless of their
declared visibility. This is the Java `@VisibleForTesting` pattern, enforced by
the compiler rather than an annotation.

## PROFILE integration

```
TEST MyServer DO
  WHEN "profile" DO
    PROFILE process(real_data);
    -- Output:
    --   PROFILE process:
    --     CPU:  38.2% pthread_rwlock_unlock
    --     Heap: 82.0% intToString (2.1M allocs)
    --     Suggestion: data is @writeLocked -> switch to @locked
  END
END
```

PROFILE blocks run under `clear test --profile` or `clear benchmark --profile`.
They use the existing `alloc-profile.zig` infrastructure and capability-aware
suggestion engine.

## Implementation plan

### Phase 1: TEST/WHEN/TEST THAT (v0.1-pre)

Parser + transpiler changes to support the test DSL structure:
- `TEST name DO ... END` -> Zig `test "name" { ... }`
- `WHEN desc DO ... END` -> nested scope with setup replay
- `TEST THAT desc DO ... END` -> individual test case
- `ASSERT_RAISES` for error testing

Estimated: ~200 lines parser + ~150 lines transpiler.

### Phase 2: BENCHMARK/SMASH keywords (v0.1-pre)

Wire the existing Zig infrastructure into the transpiler:
- `BENCHMARK expr x<N>` -> `CheatLib.benchmark(fn, rt, args, N)`
- `SMASH expr` -> `CheatLib.generateSkewKeys` + timed run + report
- Only run under `clear benchmark`

Estimated: ~100 lines parser + ~80 lines transpiler.

### Phase 3: STUB system (v0.1-pre)

Compile-time function replacement in test mode:
- `STUB fn RETURNS value` -> replace fn body with `return value`
- `STUB fn CAPTURES var` -> replace fn body with `var.append(arg)`
- `STUB fn SEQUENCE [...]` -> return values from array in order
- `STUB fn WITH lambda` -> replace fn body with lambda

Estimated: ~150 lines parser + ~200 lines transpiler.

### Phase 4: PROFILE keyword (v0.1)

Sugar over existing `clear profile` / `clear doctor`:
- `PROFILE expr` -> run with allocation tracking + report suggestions
- Capability-aware suggestion engine (~60 lines)

### Phase 5: Strict test mode (v0.2)

`clear test --strict` requires all IO to be stubbed:
- Compiler scans test bodies for un-stubbed IO calls
- Error: "unstubbed IO in strict mode: tcpRead on line 42"
- Guarantees test determinism

## Design principles

1. **No production code changes for testing.** Stubs are injected by the compiler,
   not by restructuring your code around interfaces.

2. **The compiler is the test framework.** It knows your types, effects, and
   capabilities. It uses that knowledge instead of making you annotate everything.

3. **Correctness and performance in the same file.** TEST THAT for correctness,
   BENCHMARK/SMASH for performance. Same setup, same bindings.

4. **IO is a first-class test concern.** The compiler knows which functions do IO
   (via effects). It can stub them, verify they're stubbed, and warn when they're
   not.

5. **Private is visible for testing.** No `@VisibleForTesting` annotations. The
   compiler handles it. In test mode, everything is accessible. In production,
   visibility is enforced.
