# minivm Gap Analysis

Generated 2026-04-08 against 233 transpile-tests.

## Summary

| Status | Count | % |
|--------|-------|---|
| PASS | 108 | 46% |
| Interpreter runtime bug (Invalid free / Segfault) | 41 | 18% |
| Assertion failure (wrong result) | 56 | 24% |
| Unhandled AST node -> crash | 14 | 6% |
| Transpiler crash (Ruby exception) | 3 | 1% |
| Other (race condition, Zig compiler bug) | 11 | 5% |

## Interpreter Runtime Bugs (41 tests)

28 "Invalid free" and 13 "Segfault" tests. All have valid S-expression output
(0 unhandled nodes). The bug is in the interpreter's memory management -- likely
in pool-based environment deallocation or Value cleanup.

Fixing this single class of bug recovers ~41 tests.

## Unhandled AST Nodes (14+ tests)

Unhandled nodes emit `;; unhandled: ...` comments, leaving variables undefined
and causing index-out-of-bounds or wrong results downstream.

| Node Type | Occurrences | Description |
|-----------|-------------|-------------|
| CopyNode | 43 | Struct/value copying -- translate as identity |
| UnionVariantLit | 24 | Inline union construction -- needs tagged-vector emit |
| ConcurrentOp | 13 | Parallel pipelines -- no VM equivalent |
| TestBlock | 10 | TEST blocks -- emit as sequential evaluation |
| ThenChain | 7 | `x \|> f \|> g` chaining -- emit as nested calls |
| StaticCall | 6 | Type::method() calls |
| BgStreamBlock | 6 | Background streams -- no VM equivalent |
| ResolveNode | 5 | Promise resolution |
| LinkNode | 5 | Resource linking |
| WindowOp | 4 | Pipeline WINDOW -- already handled, but emit_pipe missing case |
| ShardOp | 2 | Pipeline SHARD -- no VM equivalent |
| RecoverOp | 2 | Pipeline RECOVER -- emit as try/catch |
| JoinOp | 1 | Pipeline JOIN -- already handled, but emit_pipe missing case |
| OrExit | 1 | OR EXIT |

## Assertion Failures by Category (56 tests)

### Pipeline predicates dropped (~10 tests)

Tests: 08_where, 65_collection_query_ops, 66_aggregation_ops, 66_take_while,
109_pipeline_chaining, 110_pipeline_reduce, 68_pool_find, 99_soa_pool

The scheme_transpiler emits `(list-count nums)` instead of
`(list-count nums (lambda (_) (> _ 3.0)))`. The predicate expression after the
pipeline operator is lost. Likely a parser change the transpiler hasn't adapted to.

### Capability system (~8 tests)

Tests: 40_locked, 41_locked_return, 42_write_locked, 43_write_locked_return,
72_always_mutable, 100_auto_lock, 170_shared_locked_struct, 184_with_restrict_mutable

No support for @locked, @shared:locked, @alwaysMutable, WITH EXCLUSIVE,
WITH RESTRICT. These are compile-time concepts -- translate as identity
(WITH EXCLUSIVE = just run the body, @locked = ignore the qualifier).

### Struct mutation semantics (~8 tests)

Tests: 04_stack_return, 20_subfield_move, 21_subfield_return,
22_heap_subfield_move, 34_multiowned_struct_field, 89_frame_alloc,
90_list_return, 92_var_mutated_sroa

Structs are vectors in the VM. Copy-vs-reference semantics and nested field
assignment are not propagating correctly. `vector-set!` on a copied struct
may mutate the original, or nested field paths may not resolve.

### Integer division (~3 tests)

Tests: 65_int_division, 110_integer_overflow, 100_for_range

Scheme `/` returns rationals, not truncated integers. Need @divTrunc semantics
for Int64 division. Also inclusive range boundary off-by-one.

### String methods (~5 tests)

Tests: 67_string_utf8, 68_string_raw, 72_string_escapes, 186_string_replace_case

Missing native functions: codepointCount, charAt, bytes(), split() (partial),
replace(), toUpper(), toLower(), raw string byte access.

### Enum comparison (~3 tests)

Tests: 51_enum, 56_match_enum_exhaustive, 72_union_method_visibility

Enum `!=` not working (symbol inequality). Exhaustive match with enum variants
produces wrong dispatch order.

### Collection methods (~4 tests)

Tests: 25_index, 66_set, 78_hashmap_methods, 48_multidim_array

Set insert/remove/contains? and HashMap delete/keys/values methods missing
or have wrong semantics. INDEX grouping output format incorrect.

### Compound assignment on fields (~3 tests)

Tests: 101_compound_assign, 112_control_flow_shorthand, 64_big_struct_return

`+=` on struct fields not desugared correctly for nested paths. FOR-EACH
shorthand not recognized.

### Range semantics (~2 tests)

Tests: 187_range_slice, 100_for_range

Inclusive vs exclusive range boundary errors. Range slicing not implemented.

### Other (~10 tests)

Various edge cases: GIVE/COPY union semantics, reassignment from self,
error snapshots, catch blocks, bounded streams.

## Transpiler Crash (3 tests)

Tests: 64_sharded_collections, 67_thread_pinning, 71_tap_skip

Line 694 in scheme_transpiler.rb: `emit_pipe` calls `right.expression` on
EachOp and TapOp nodes, which have `.body` instead. One-line fix.

## Highest-Leverage Fixes

| Fix | Tests Recovered | Effort |
|-----|-----------------|--------|
| Interpreter memory bug (Invalid free / Segfault) | ~41 | Hard (Zig debugging) |
| Pipeline predicate emission | ~10 | Easy (transpiler fix) |
| Unhandled CopyNode + UnionVariantLit | ~10 | Easy (identity + tagged vector) |
| Transpiler EachOp/TapOp crash | 3 | Trivial (one-line) |
| Capability as identity | ~8 | Easy (ignore qualifiers) |
| Integer division truncation | ~3 | Easy (add native fn) |
| String methods | ~5 | Medium (add native fns) |

Fixing all of the above takes the pass rate from 108/233 (46%) to ~188/233 (81%).
