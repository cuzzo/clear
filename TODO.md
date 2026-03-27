# CLEAR TODO

## v0.1-pre: Architectural Preview

Goal: A working Mal (Make-a-Lisp) Level 4 interpreter that proves CLEAR isn't brittle.
The scheme/mal interpreter exercises unions, pattern matching, closures, recursion,
error propagation, string manipulation, and HashMap iteration — all at once.

### Milestone: Mal Interpreter Compiles and Runs

**P0 — Blocks compilation** (interpreter.cht won't even parse/transpile without these):
- [ ] String escape sequences in lexer (`\"`, `\n`, `\t`, `\\`)
- [ ] String indexing `s[i]` returns a single character (String or Byte)
- [ ] `String.substring(start, end)` or equivalent slice syntax
- [ ] `toNumber(string) RETURNS ?Float64` — parse string to number
- [ ] MATCH payload extraction for union variants (`Value.Number(n) -> n`)
- [ ] Union variant construction with payload from expressions (`Value.Lambda(params, body, env)`)
- [ ] `@indirect` on union variant fields (heap-allocate recursive types)
- [ ] `@shared` on struct construction (`Env{...} @shared`)
- [ ] Error union propagation through WHILE loops (`RAISE` inside loop body)

**P1 — Blocks test suite passing** (compiles but tests fail without these):
- [ ] Additional native math: `-`, `*`, `/` (currently only `+`)
- [ ] Comparison operators on Value: `=`, `<`, `>`, `<=`, `>=`
- [ ] `ELSE IF` inside MATCH branches (or rewrite interpreter to avoid)
- [ ] HashMap key iteration (`FOR k IN map DO`) — DONE, just shipped
- [ ] FOR range loop — DONE, just shipped
- [ ] `OR BREAK` inside WHILE (error-to-break coercion)
- [ ] `readForm!(r)` syntax (mutation suffix on fallible call)
- [ ] `.length()` on dynamic arrays/lists
- [ ] Optional field access (`inner.Outer.?`)

**P2 — Nice to have for demo** (interpreter works but demo is limited):
- [ ] stdin REPL (read line from stdin)
- [ ] More native functions (`-`, `*`, `/`, `=`, `pr-str`, `prn`, `str`)
- [ ] String concatenation with `+` (operator overloading on String type)

### Milestone: @sharded KV Benchmark

**DONE:**
- [x] PartitionedStringMap — true shared-nothing, zero locks, zero atomics
- [x] Cross-scheduler routing via RemoteCall + WaitGroup
- [x] spawnPinned — round-robin fiber distribution across schedulers
- [x] Auto-pin BG blocks that capture @sharded maps
- [x] Unified StringMap API — @sharded is a one-line declaration change
- [x] Functions accept any HashMap variant via anytype (no @sharded in params)
- [x] Zig-level scaling test: 1.9x on 2 cores
- [x] Benchmark: 1.35s (Rust 4.76s = 3.5x slower, Go 14.08s = 10x slower)

### Milestone: FOR Loop

**DONE:**
- [x] FOR i IN (start..=end) DO ... END — inclusive range
- [x] FOR i IN (start..<end) DO ... END — exclusive range
- [x] FOR x IN collection DO ... END — arrays, lists, maps
- [x] ..= alias for inclusive range (Rust-style)
- [x] Nested FOR loops with unique counter variables

---

## Previously Completed

- [x] Basic Types: Struct, List, Number, String
- [x] Constants: TRUE/FALSE/NIL
- [x] Immutable declaration (`x = value`), mutable (`MUTABLE x = value`)
- [x] BinaryOps, UnaryOps
- [x] IF/THEN/ELSE/ELSE_IF/END; WHILE/DO/END
- [x] Function definitions, calls, closures
- [x] Zig transpiler
- [x] Capabilities: multiowned, shared, alwaysMutable, indirect
- [x] WITH Block: scoping capabilities, lock ordering
- [x] Ownership tracking, escape analysis
- [x] MATCH/START/END with union/enum support
- [x] ENUM and UNION types
- [x] EXTERN FN / EXTERN STRUCT (FFI)
- [x] REQUIRE "pkg:name" (package management)
- [x] Pipeline operators: s> SELECT, WHERE, EACH, SUM, MIN, MAX, etc.
- [x] HashMap @sharded(N), @sharded(N):locked, @sharded(N):writeLocked
- [x] Pool collections with generational handles
- [x] SOA layout for cache-optimal iteration
- [x] CONCURRENT parallel pipelines
- [x] String concat, toString, indexOf
- [x] FOR range and FOR-each loops

---

## v0.1 Release

After v0.1-pre is stable (Mal interpreter works, @sharded benchmark passes):

- [ ] stdin/stdout REPL
- [ ] Runtime line numbers in error messages
- [ ] String interning
- [ ] Tail-call optimization (@tco attribute)
- [ ] IMPORT (C headers via Zig FFI)
- [ ] Execution tracing / debugger hooks
- [ ] Seeded Wyhash default (Hash DoS protection) + fix double-hashing
- [ ] @fastTrusted capability (opt-in unsalted hash for trusted keys)

---

## v0.2+

- [ ] Native @regex capability
- [ ] Sealed interfaces / protocols (replace massive UNION types)
- [ ] Weak pointers for cycle-safe reference counting
- [ ] SYS_SPAWN (isolated processes)
- [ ] IO: File & Network (io_uring based)
- [ ] @cow (copy-on-write) capability
- [ ] Automatic @indirect on recursive union variants
- [ ] Co-routines & yield/generators
