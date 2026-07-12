# Bytecode VM Status

The bytecode VM consists of `bc_emitter.rb` (compiles MIR -> bytecode) and
`_bc_runner.clear` (interpreter, written in CLEAR, run as a native binary).
This document tracks the VM's coverage of `transpile-tests/*.clear` (~307
runnable tests after VM_UNSUPPORTED filter) and known issues.

## Latest Coverage (post 2026-04-29 session)

| Bucket | Count |
|---|---:|
| **pass** | **183 / 294 supportable** (62%) |
| fail | 25 |
| panic | 4 |
| heap_corrupt | 19 |
| compile_unimpl | 47 |
| error (timeout-classified) | 11 |
| unknown (warning-misclassified) | 5 |
| unsupported | 13 (infinite-stream, FFI, narrow numerics) |

This session: 178 -> 183 passing. Committed fixes:

- set/map InlineBc :insert / :remove dispatch (66_set, 280_takes_alloc_set).
- @alwaysMutable .get() identity + AST GetField vstack-idx (72_always_mutable).
- @mod NATIVE_CALL :any tagging (eliminated the integer-fit panic family).
- list.remove(i) via new LIST_REMOVE_AT opcode (117_list_remove).
- AST ident loads from typed slot tables when slot_types is :any.
- AST FuncCall uses BC_CALL for compiled helpers; AST StringConcat support.
- WRAP_ADD/SUB/MUL_I64 opcodes for `%+` / `%-` / `%*` (199 fixed in
  semantics; remains in ERROR due to historical-test 10s timeout).
- AST-driven print template path (handles arbitrary method chains in
  `print(expr.method().toString())`).
- Struct field defaults + DEFAULT lit support (244_defaults).
- Arc/Rc data unwrap doesn't shadow user-declared `data` field
  (103_nested_collection_escape).
- AST OR_RESCUE + union unit-variant + map index dispatch (no test
  delta but fixes deeper print-template cases).

## What's Complete

These features compile and execute correctly via the bytecode path:

- **Core types**: Int64 (typed istack), Float64 (typed fstack), String,
  Bool, Nil, list, struct (vector), HashMap (MapRef in pool), Set
- **Collections**: list append/get/set/length, HashMap put/get/contains,
  Set insert/contains
- **Control flow**: IF/ELIF/ELSE, WHILE (with `update` field for FOR),
  FOR i IN range (..= and ..<), FOR x IN list, BREAK, CONTINUE
- **Functions**: helper FNs via BC_CALL, recursion, MUTABLE params, RETURNS
  with HPT promotion, generic `FN identity<T>(x: T)` (type-erased compile)
- **Pattern matching**: MATCH on enums, MATCH on union variants with
  `AS x` payload binding (FieldGet -> cdr dispatch via @union_variant_names),
  MATCH on int / string / WHEN guards
- **Unions**: UNION declarations, variant construction, variant destructuring,
  generic UNION instantiation (Option<T>{Some: ...})
- **Structs**: declarations, field get/set, generic instantiation, receiver-
  typed `find_field_index` so same-named fields across structs disambiguate
- **WITH blocks**: WITH BORROWED, WITH RESTRICT (mut/immut), WITH EXCLUSIVE
  on @locked, WITH SHARED on Arc, alias writeback after the block
- **Error machinery**: RAISE Kind/Type/msg -> RAISE_ERR opcode, OR_ELSE RAISE
  propagation via Value.Error sentinel, single-FN CATCH (kind dispatch via
  GET_ERR_KIND + EQ chain), OR <fallback> via TryCatch
- **Print**: std.debug.print template arg parser respects nested parens,
  iteratively peels Zig wrappers (`try`, `@as`, `@intFromFloat`,
  `CheatLib.intToString`), recursively dispatches `CheatLib.len(EXPR)` /
  `CheatLib.getAt(EXPR, N)` / `obj.field` against known slots
- **Stdlib I/O**: readFile (with file-not-found wrapping), writeFile, split,
  join, trim, indexOf, contains?, substr, startsWith?, endsWith?, charAt,
  toInt, toString, length, count
- **Sort**: BC_SORT opcode for `xs s> ORDER_BY ...`

## What's Known to Not Work

### Compile-time refused (53 tests, `compile_unimpl`)

| Cluster | Count | Theme |
|---|---:|---|
| InlineZig/RawZig init not in VM path | 20 | Lambda closures, range streams, concurrent stream constructors, file/tcp resources, sharded collections, thread pinning, bounded streams |
| InlineZig/RawZig in expression position | 16 | Concurrent pipelines/bindings, sharded values inline, batch windows, concurrent select/where/pin/prune/raise, `91_hashmap_numeric` |
| InlineZig expr not supported | 5 | indirect_field_cleanup, extern_std_ffi, index_inf_stream, pipeline_fusion, soa_pool |
| InlineZig not supported | 4 | shared_sharded_map, hashmap_methods, sharded_map, striped_map |
| RawZig not supported | 3 | shard_pipeline, shard_numeric_keys, concurrent_each |
| `MIR::LambdaExpr` unhandled | 2 | lambda_inferred_type, fn_type |
| MIR/AST length mismatch | 2 | reentrant, var_mutated_sroa |
| RawZig expr | 2 | or_exit_unified, error_context |

These need per-template VM emission shims; they are the bulk of the tail.
None require architectural changes — each template adds 1–N tests.

### Runtime assertion failures (35 tests)

Concentrated themes (with the test count each blocked on):

| Theme | Count | Why |
|---|---:|---|
| Concurrency (locks/BG/multi-fiber/retry) | 10 | Phase-2 fiber scheduler not in VM. `100_auto_lock`, `101_compound_assign`, `170_shared_locked_struct`, `262_with_on_timeout`, `263_with_lock_contention`, `264_multi_lock_sort`, `267_retry_resolves`, `268_multi_lock_sort_forced_contention`, `270_mixed_capabilities_with_sort`, `95_local` |
| Pipeline polymorphism (s> ops) | 7 | `25_index` (INDEX), `66_set` / `66_take_while`, `67_window`, `68_join` (JOIN), `71_tap_skip` (TAP+SKIP), `101_for_each`, `101_pipeline_binding` — needs SELECT/WHERE/INDEX/JOIN/WINDOW/TAP per-op VM dispatch |
| Streams (open_stream / split_stream) | 4 | `75_open_stream`, `225_split_stream`, `226_split_stream_clone_edges` — needs generator-fiber state machine |
| CATCH grammar tail | 4 | `175_tco_try_catch` (TCO chain), `271_catch_unified` (kind+type+filter, multi-OR), `77_error_snapshot` (snapshot.X access), `78_snapshot_ambiguous` (`s>` validator) |
| Bare-message asserts (no message) | 3 | `103_nested_collection_escape` (HashMap field on returned struct), `185_borrowed_iterator` (generic SliceIter<T>), `187_range_slice` (string slicing `msg[0..4]`) |
| Misc one-offs | 7 | `117_list_remove` (no in-place mutation), `121_list_prstr` (recursive prStr default), `169_indexed_field_reassign_cleanup`, `201_capability_passthrough`, `64_weak_ref` (LINK/RESOLVE), `72_always_mutable`, `86_then_chain` (BG THEN closure capture) |

### Timeouts (15 tests)

Mostly tests that exercise frame-arena scaling (`188_frame_arena_bounded`,
`200_frame_peak_large_alloc_loop`, `205_frame_peak_list_build_in_fn`,
`216_loop_carry_nested`, `217_loop_carry_overflow_blocks`) — those benchmark
patterns assume Zig's allocator / GPA arena and don't translate to VM op
counts. Plus 6 lazy-stream tests (`220–223_lazy_*`, `218_yield_string_stream`,
`227_variable_stream_pipelines`, `237_tap_inf_stream`, `76_inf_stream`)
blocked on lazy iterator state. Plus `198_line_parse_startswith`,
`253_while_bind`, `255_bind_cleanup_heap`.

### Other (8)

5 [no output] (`14_hashmap`, `167_nested_list_index_field`,
`200_frame_peak_large_alloc_loop`, `244_defaults`, `74_service_benchmark`)
plus 3 `free(): invalid pointer` (heap corruption — see below).

## Heap Corruption Bugs (`free(): invalid pointer`)

Affected tests: `15_select`, `18_split_join`, `68_string_raw`. All call
`s.split(",")` (15, 68 directly; 18 transitively via readFile().trim()
crashing the post-fix path).

### What's confirmed

- The crash is **build-mode-dependent** in the *runner itself*:
  - Default debug build (`./clear build _bc_runner.clear --use-c-allocator`):
    crashes with `double free or corruption (out)`.
  - GPA debug build (no `--use-c-allocator`): **passes**.
  - `--safe` (LLVM ReleaseSafe + GPA): **passes**.
  - `--optimized --use-c-allocator` (LLVM ReleaseFast + libc): crashes.

- Simple reproductions of the lowering shape that the runner uses
  (`MUTABLE parts: Value[]@list = List[]; ... RETURN Value{ List: parts };`)
  **work correctly** in isolation. Tested four progressively closer
  reductions; all pass.

- The runner's generated Zig (`zig/.clear-transpile-cache/...`) shows the
  expected escape-analysis output for the split path: `parts` declared
  `ArrayListUnmanaged(Value).empty`, deferred cleanup with `cleanupAlloc`
  (which skips frame pointers), deep-copy via `dupeUnionValue` into a fresh
  `rt.heapAlloc().alloc(Value, len)` buffer, errdefer cleanup, and
  `promoteDeep` before return. The structure looks correct.

- The MIR checker accepts the runner's source without flagging anything.

### What's not yet known

- Whether the bug is in (a) the optimizer's interaction with libc's malloc
  (false positive), (b) escape analysis missing a specific path that only
  manifests with the runner's full Value union (18 variants, several with
  `@indirect`), or (c) the lowering for a specific operation (`@indirect`
  field cleanup, `MUTABLE pool: Env[N]@pool` threading, mutual recursion
  between `eval!` / `evalList!` / `applyNative` / `exec!`).

- Where in the runner the double-free first occurs. valgrind under the
  `--use-c-allocator` debug build did not catch a clean error site —
  valgrind suppresses libc's malloc check, so the runner ran past the
  abort and only reported scheduler-shutdown invalid writes (231384
  errors, 2 contexts, all in `Scheduler.freeStack` / `Scheduler.deinit`).

### Likely a compiler issue

The pattern strongly suggests a compiler bug:

1. The MIR checker's 7 invariants verify per-function pairing
   (`AllocMark` ↔ `Cleanup`, allocator match, loop rewind) but do not
   verify that **two cleanup paths can't both free the same heap pointer**.
2. The bug is build-mode dependent — debug GPA tolerates it, libc doesn't.
   That's the classic shape of a real heap bug that GPA's free-fill /
   double-free check happens to absorb but libc detects.
3. Per CLAUDE.md INV-13/INV-14, the lowering is supposed to make these
   decisions correctly upstream (`MoveMark`, `ErrCleanup`, inheriting
   cleanup from source). The runner exposes a gap somewhere in that chain
   that simple repros can't reach.

### Recommended next steps

The architectural correct fix is to **catch the bug at compile time**, not
add another runtime guard. Plan:

1. **Bisect the runner**: comment out variants of `Value` (`Pair @indirect`,
   `Tco @indirect`, `Lambda { ... envId: Id<Env> }`, `Error { errMsg, errKind }`)
   one by one. The variant that, when removed, makes the bug disappear is
   the trigger.
2. **Reduce surface area**, don't add more invariants. If the trigger is
   a missed escape on `@indirect` cleanup or pool-threaded params, the fix
   should remove the special case or unify it with the existing path —
   not add another invariant to `mir_checker.rb`.
3. Skip step 4 (cleanupCheck) — runtime detection only confirms the bug
   happens; it doesn't tell us where. Compile-time prevention is what
   matters.

## Architectural Constraints

The VM is a *parallel* backend, not a fork: it consumes the same MIR that
the Zig backend consumes. Bugs that require new MIR nodes or invariant
changes affect both backends and must respect the safety contract in
CLAUDE.md (INV-1..INV-16, plus the role boundaries in `MIRLowering` /
`MIRChecker` / `MIREmitter`).

The VM-side responsibilities of `bc_emitter.rb`:

- Pure consumer of MIR + AST stamps.
- No reverse-derivation of ownership info from node shape.
- All template strings (`std.debug.print`, `WITH BORROWED const ref = X;`,
  CatchWrapper Zig source) are parsed structurally — the lowering must
  emit them in a stable form.

The runner (`_bc_runner.clear`) is itself a CLEAR program subject to the same
checker, so bugs in the runner's own lowering are real compiler bugs.
