# Unified Native FFI: C and Zig

Status: Functional implementation complete; structured build metadata and advanced lifetime contracts remain follow-up work

## Outcome

CLEAR should use one foreign-function model for both C and Zig:

```clear
EXTERN STRUCT Database {} CLOSE "sqlite3_close" AS "sqlite3"
  FROM "sqlite3" ABI C;

EXTERN FN sqlite3_open(
  filename: String@c,
  MUTABLE database: ?Database
) RETURNS TargetInt FROM "sqlite3" ABI C;
```

The user declares native types and functions in CLEAR. The compiler owns ABI
lowering, symbol declarations, native-library linking, stack trampolines, and
resource cleanup. A C library must not require a hand-written Zig adapter when
its public ABI can be expressed by CLEAR's FFI types.

This extends the existing `EXTERN STRUCT` / `EXTERN FN` strategy. It does not
create a second `CIMPORT`, wrapper-language, or build recipe that users must
learn.

## Why the Current FFI Cannot Bind SQLite Directly

The current implementation describes Zig modules, despite documentation that
calls it a Zig and C FFI:

- `FROM "native"` always lowers to `@import("native")` and a Zig member call;
- the CLI searches for and copies `native.zig`;
- empty `EXTERN STRUCT` declarations alias a type exported by that Zig module;
- `CLOSE` always emits a Zig method call;
- parameters have no C pointer, opaque-handle, or out-parameter model;
- `String` is a Zig slice, not a NUL-terminated C string;
- native link dependencies are supplied only through the
  `CLEAR_EXTRA_LINK_LIBS` escape hatch;
- the build and test paths rediscover FFI dependencies independently with
  source regular expressions.

Consequently, the rejected SQLite example needed `sqlite.zig` to dynamically
load symbols, convert strings, model handles, and adapt out-parameters. Those
are compiler responsibilities, not application code.

## Surface Design

### One declaration shape, explicit ABI

```clear
EXTERN FN sqlite3_step(statement: Statement) RETURNS TargetInt
  FROM "sqlite3" ABI C;

-- Existing Zig-module FFI becomes explicit.
EXTERN FN cwd() RETURNS Dir FROM "std.fs" ABI ZIG;
```

`FROM` continues to identify the native dependency and namespace. `ABI`
defines how types, symbols, calls, and cleanup are lowered.

For compatibility, omitted `ABI` still means the existing Zig-module FFI.
New C declarations must say `ABI C`; changing the default remains a separate
migration that first needs an autofix adding `ABI ZIG` to legacy declarations.

### Calling conventions

`ABI C` selects the target's normal C calling convention. An optional
`CALLCONV` clause handles real platform ABI variants:

```clear
EXTERN FN ExitProcess(code: UInt32) RETURNS Never
  FROM "kernel32" ABI C CALLCONV WINAPI;
```

Initial accepted conventions should be `C` and `SYSTEM`, plus `WINAPI` where
the target supports it. Additional target conventions can be added without
changing the FFI model.

`NAKED` is deliberately not an EXTERN calling convention. A naked function is
a function definition without compiler-generated prologue or epilogue; it is
useful for assembly entry points, not for declaring an imported library
symbol. If CLEAR later supports exported assembly-oriented functions, that is
a separate `EXPORT FN ... CALLCONV NAKED` design with strict body validation.

### Native symbol names

The CLEAR name is the native symbol unless `AS` overrides it:

```clear
EXTERN FN open(path: String@c, MUTABLE database: ?Database) RETURNS TargetInt
  AS "sqlite3_open" FROM "sqlite3" ABI C;
```

This preserves normal CLEAR naming without needing a wrapper function. The
same `AS` concept already exists for external type expressions and should be
normalized into one typed native-symbol field in the AST.

## C Type Model

The compiler must distinguish ABI types from ordinary CLEAR data. Pretending
that a CLEAR slice is a C pointer or that `Int64` is C `long` creates
platform-dependent unsoundness.

### Scalars

Exact-width C integers map directly to exact-width CLEAR integers. C's
target-dependent integer spellings use transparent target-resolved aliases:

| CLEAR ABI spelling | Zig lowering | Numeric family |
|---|---|---|
| `TargetInt` | `c_int` | `Int`, `Number` |
| `TargetUInt` | `c_uint` | `UInt`, `Number` |
| `TargetLong` | `c_long` | `Int`, `Number` |
| `TargetULong` | `c_ulong` | `UInt`, `Number` |
| `TargetLongLong` | `c_longlong` | `Int`, `Number` |
| `TargetULongLong` | `c_ulonglong` | `UInt`, `Number` |
| `TargetUInt@size` | `usize` / C `size_t` | `UInt`, `Number` |
| `TargetInt@size` | `isize` / C `ptrdiff_t` | `Int`, `Number` |

These are aliases, not nominal foreign number classes. On a selected target
they resolve to the corresponding exact CLEAR representation. For example,
on LP64 `TargetLong` and `TargetLongLong` resolve to `Int64`; on LLP64,
`TargetLong` resolves to `Int32` while `TargetLongLong` remains `Int64`.
Their resolved identity participates in ordinary arithmetic, comparisons,
generic numeric constraints, collections, and pipelines without conversion.

`TargetUInt@size` and `TargetInt@size` are the only initial target-size
refinements. Integer/pointer conversion is not implied: pointer provenance is
not interchangeable with an integer merely because their storage widths
match.

C `float` and `double` map to `Float32` and `Float64`. There is no
`TargetFloat`. Target-dependent C `long double` is deferred and rejected with
a source diagnostic until CLEAR has a real semantic contract for its excess
precision.

Arrays preserve their real physical element width without C-specific
capability repetition:

```clear
EXTERN STRUCT Samples {
  narrow: [10]TargetInt;
  exact: [10]Int64;
  sizes: [10]TargetUInt@size;
} FROM "samples" ABI C;
```

The enclosing `ABI C` declaration establishes foreign layout. Users never
write `[10]@c TargetInt@c`. A target alias that resolves to `Int64` is the
same layout as `[10]Int64`; one that resolves to `Int32` remains physically
narrow because treating forty bytes as eighty would be unsound.

### Opaque handles

An empty C `EXTERN STRUCT` is an incomplete C type represented in CLEAR by a
non-null handle:

```clear
EXTERN STRUCT Database {} AS "sqlite3" FROM "sqlite3" ABI C;
```

The Zig backend may emit an opaque pointee plus a pointer alias. Semantically,
`Database` is a non-null, non-dereferenceable native handle and `?Database` is
a nullable handle. It is not a zero-sized value and it is not `@boxed`; using
the ownership capability would incorrectly claim that CLEAR allocated and may
destroy the pointee.

A C struct with fields remains a by-value C-layout aggregate:

```clear
EXTERN STRUCT Timespec { seconds: TargetLong, nanos: TargetLong }
  AS "timespec" FROM "c" ABI C;
```

The compiler emits an `extern struct` layout and rejects fields without a
known C ABI. Empty and field-bearing declarations therefore have distinct,
unambiguous meanings under `ABI C`.

### Pointer parameters without a pointer type

Do not add `CPointer<T>` to the initial public type system. Most C pointers
already have a more precise expression in CLEAR's bind-time capability model:

| CLEAR boundary declaration | C ABI meaning |
|---|---|
| `value: T` | `T` by value |
| `BORROWED value: T` | `const T *`, valid only for the call |
| `MUTABLE value: T` | `T *`, valid only for the call |
| `MUTABLE value: ?Handle` | `handle **` out/inout parameter |
| empty C `EXTERN STRUCT Handle {}` | nominal opaque pointer handle |

This is safer and easier than exposing raw pointer construction. The compiler
knows that a borrowed or mutable address cannot escape the native call, while
an opaque handle retains its library-specific nominal identity.

Persistent arbitrary pointers (`void *` contexts, interior pointers, pointer
arrays) should remain unsupported until a real library requires them. If they
do, a restricted foreign-reference capability such as `T@c` is more coherent
with CLEAR than a nominal pointer generic. It must be non-dereferenceable and
non-owning by default. Pointer depth, mutability, lifetime, and cleanup need
explicit contracts rather than recursive pointer-generic spelling.

### Mutable and out parameters

Reuse CLEAR's existing `MUTABLE` parameter contract:

```clear
EXTERN FN sqlite3_open(
  filename: String@c,
  MUTABLE database: ?Database
) RETURNS TargetInt FROM "sqlite3" ABI C;
```

At a C boundary, a mutable parameter is passed by address. The caller writes:

```clear
MUTABLE database: ?Database = NIL;
result = sqlite3_open(":memory:", database);
```

This lowers to the C equivalent of `sqlite3 **`. It does not require a second
`OUT` syntax. Existing annotation rules already require a mutable lvalue; MIR
lowering must begin honoring that contract for EXTERN calls as it does for
ordinary calls.

If later analysis needs to distinguish input/output initialization, optional
`OUT` and `INOUT` refinements may be added to `MUTABLE`, but they are not
required for the first implementation.

### C strings

`String` cannot silently mean `char *`: it is a length-carrying CLEAR/Zig
slice and may contain embedded NUL bytes. Express the foreign representation
as the bind-time capability `String@c` rather than adding a nominal `CString`
type.

- `String@c` guarantees NUL termination and no embedded NUL;
- a string literal can satisfy `String@c` without allocation;
- a runtime `String` requires an explicit checked conversion to `String@c`;
- that conversion is fallible on allocation and embedded NUL and owns its
  temporary storage for the surrounding lexical scope;
- a returned `String@c` remains a borrowed foreign view and cannot escape
  unless its lifetime is tied to a parameter/handle or it is copied into a
  CLEAR `String`;
- mutable C buffers use a mutable byte collection plus an explicit length,
  never `String@c`.

Phase one may accept literals only and issue a fixable diagnostic for runtime
`String` arguments until the checked conversion lands. It must not pass a slice header
where C expects a pointer.

### Function pointers and callbacks

Callbacks need the same function-type syntax with an ABI marker:

```clear
FN(OpaqueContext, TargetInt, String@c, String@c) -> TargetInt CALLCONV C
```

The implemented spelling is `CALLCONV C` on the function type. A non-capturing
CLEAR function is adapted to a synchronous C callback using the active runtime
for the duration of the native call. A callback that escapes/retains the call,
or a callback error that crosses C, is rejected or trapped. Context-bearing,
capturing, and retained callbacks need explicit lifetime contracts and remain
follow-up work.

Variadic C functions are also deferred. C default argument promotions and
target-specific varargs rules make untyped forwarding unsound.

## Cleanup and Ownership

`CLOSE` should keep the same user-facing resource behavior for both ABIs:

```clear
EXTERN STRUCT Statement {} CLOSE "sqlite3_finalize" AS "sqlite3_stmt"
  FROM "sqlite3" ABI C;
```

For `ABI ZIG`, `CLOSE "deinit"` remains a method cleanup. For `ABI C`, cleanup
is a free native function that receives the handle as its first parameter.
The resource schema must record a typed close plan (`method` versus
`extern_function`) rather than infer it in the emitter.

Cleanup must support nullable resources created through out-parameters:

- do nothing while the optional is `NIL`;
- call the closer once when it contains a handle;
- preserve reverse lexical cleanup (`Statement` before `Database`);
- transfer cleanup responsibility on `MOVE`/`RETURN` exactly as native Zig
  resources do;
- reject an incompatible closer signature at annotation time.

Foreign handles are borrowed/non-owning unless their declaration has `CLOSE`
or a function explicitly returns ownership. In a later phase, parameter and
return annotations should express `BORROWS`, `TAKES`, and returned-lifetime
ties using the same ownership contracts already used by CLEAR functions.

Capabilities wrap the CLEAR handle, not the foreign object. The first version
should reject synchronization/ownership capabilities on C handles unless the
declaration includes a future explicit foreign thread-safety contract. A lock
around a pointer does not make the pointed-to C object safe.

## Errors and Effects

C return codes are not CLEAR/Zig error unions. `RETURNS !T` remains valid for
`ABI ZIG`, where the callee really returns a Zig error union. An `ABI C`
declaration must initially return its raw status/result and check it in CLEAR:

```clear
status = sqlite3_step(statement);
ASSERT status == 100 OR status == 101, "SQLite step failed";
```

The compiler must reject `RETURNS !T ... ABI C` until a typed status mapping is
declared. A later `CHECKS` contract may translate a status convention into a
CLEAR error without a wrapper, but it must name the success rule, error kind,
and payload rather than assuming that zero/nonzero has one universal meaning.

Existing `EFFECTS` and g0 behavior are shared across ABIs. Native calls remain
trampolined to the OS stack unless declared `EFFECTS :safe`. Allocation for
checked runtime `String@c` conversion and ownership transfer must be visible
to effect analysis.

## Linking and Headers

For `ABI C`, `FROM "sqlite3"` identifies a system-library dependency and a
symbol namespace. The build planner links it once. `FROM "c"` identifies the
target C runtime and does not add a second arbitrary library.

The current CLI uses one shared scanner for `clear build` and `clear test`, so
both paths infer the same C libraries and link flags. This makes the explicit
ABI path usable now, including versioned-only system libraries, but source
scanning is not the desired final architecture.

The compiler should next emit structured native dependency metadata:

```text
NativeDependency
  name
  abi
  link_name
  headers
  include_dirs
  defines
  frameworks
  static_or_dynamic
```

The CLI should consume this metadata through the existing proposed
`ClearBuild::Plan`. It must not keep extending source regexes or require
`CLEAR_EXTRA_LINK_LIBS` for normal user code. `clear build`, `clear run`,
`clear test`, coverage, and package builds must use the same plan and cache
key.

The preferred import form is header-driven:

```clear
EXTERN FROM HEADER "sqlite3.h"
  LINK "sqlite3"
  ABI C;
```

The compiler invokes Zig's C translator for the selected target and expands
supported declarations into the same typed `EXTERN` contracts used by manual
declarations. It imports functions, target/exact-width scalars, C-layout
structs, opaque typedef handles, strings, scalar/out pointers, fixed fields,
and synchronous callbacks. Unsupported declarations are left unavailable
rather than guessed; handwritten declarations remain the escape hatch for
adding semantic cleanup and lifetime contracts.

Header import and handwritten declarations share the same `ExternSource`,
type contracts, MIR nodes, link plan, and validation. Header import is not a
second FFI strategy. A handwritten declaration, including one carrying
`HEADER` metadata, is currently accepted as a trusted ABI assertion. Explicit
verification of handwritten declarations against a header remains follow-up;
the header-driven directive avoids that mismatch class by generating the
declarations from Zig's translated C model.

Header target, include paths, defines, and calling-convention flags must match
the final build target. The generated manifest is cached by header contents,
transitive dependency metadata, Zig version, target triple, include paths,
and defines.

Package manifests remain the right home for non-portable include directories,
pkg-config packages, vendored C sources, frameworks, and defines. Simple
system libraries should need only the CLEAR declaration.

## Compiler Architecture

Do not add more stringly fields to `ExternFnDecl` and `FunctionSignature`.
Introduce immutable contracts:

```text
ExternSource
  dependency
  abi                 # c | zig
  symbol
  callconv
  header

ExternTypeContract
  source
  native_name
  representation      # opaque_handle | c_struct | zig_type
  close_plan

ExternFunctionContract
  source
  params
  return_type
  effects
```

Then carry these records unchanged through parsing, signature registration,
annotation, MIR lowering, and build planning.

MIR needs structural nodes for foreign declarations, not raw Zig snippets:

- `MIR::ExternTypeDecl`;
- `MIR::ExternFnDecl`;
- `MIR::ExternCall` (or an ABI field on the existing trampoline);
- typed pointer/out-argument operands;
- `MIR::NativeDependency` metadata outside executable statements.

The MIR checker should verify ABI-compatible types, pointer direction,
ownership contracts, close signatures, and that every call argument matches
the declared boundary representation. The Zig emitter then has a mechanical
job: emit a Zig module import for `ABI ZIG`, or a linker-visible `extern fn`
and C-layout type for `ABI C`.

## Phased Implementation

### Phase 1: Contracts and migration — complete for explicit ABI

1. Add `ABI C|ZIG`, `CALLCONV`, and function `AS` parsing with source spans.
2. Replace `module_alias`/parallel extern fields with typed contracts.
3. Preserve omitted `ABI` as Zig for compatibility; a future migration can
   autofix declarations to explicit `ABI ZIG` before changing the default.
4. Preserve existing Zig FFI output and tests exactly.

### Phase 2: Core C ABI — complete

1. Add transparent target integer aliases, `@size`, opaque C handles,
   field-bearing C structs, and `String@c`.
2. Add structural MIR C type/function declarations.
3. Lower `MUTABLE` C parameters by address.
4. Support literal-to-`String@c` coercion; diagnose runtime strings clearly.
5. Reject unsupported C shapes (`!T`, capabilities, callbacks, varargs,
   non-ABI fields) before Zig compilation.

### Phase 3: Native linking — functionally complete on CLI paths

1. Infer explicit C dependencies with one shared CLI helper.
2. Link system libraries consistently in build, run, test, and coverage.
3. Remove the normal-path need for `CLEAR_EXTRA_LINK_LIBS`.
4. Follow up by returning dependencies with transpilation output and putting
   them in `ClearBuild::Plan` and the cache signature.

### Phase 4: Resource cleanup and SQLite — complete

1. Add free-function close plans and nullable resource cleanup.
2. Implement the SQLite example entirely in `main.clear` using opaque
   `Database`/`Statement` handles, prepared statements, integer binding and
   querying, constraint error-code handling, and automatic cleanup.
3. Keep the example below 200 CLEAR lines and self-checking with stable `PASS`
   output.

### Phase 5: Implemented completeness

1. Header import/verification for the supported ABI subset.
2. Synchronous non-capturing C callback function types and trampolines.
3. Pointer/count conversion to a bounded borrowed view via `.view(count)`.
4. Target aliases inside ordinary CLEAR collections and numeric families.

Still deferred: checked runtime `String` to `String@c` conversion, explicit
returned-lifetime ties, retained/context callbacks, constants/globals,
enums/unions, long double, and carefully scoped varargs.

## Tests and Acceptance Criteria

The core implementation is accepted when:

- the SQLite example contains no `.zig`, `.c`, custom build script, linker
  environment variable, or dynamic-loader code;
- `./clear test examples/sqlite/main.clear` finds and links SQLite from its
  declarations and prints the expected `PASS` lines;
- the same source passes examples-only coverage and the normal CI integration
  path;
- existing Zig FFI tests pass after explicit `ABI ZIG` migration;
- parser tests cover ABI/callconv/symbol clauses and fixable migration errors;
- integration tests compile a tiny checked-in C fixture covering scalars,
  opaque handles, a field-bearing struct, nullable pointers, mutable
  out-parameters, and cleanup;
- unsupported retained callbacks, varargs, C `!T`, and unbounded direct
  pointer indexing remain outside the accepted boundary;
- build/run/test/coverage infer identical native dependencies through the
  shared CLI path; structured compiler-emitted metadata is the follow-up;
- new compiler Ruby lines have 100% LoC coverage, preferring CLEAR-source
  integration specs and transpile tests.

## Follow-on: Graph Representation Benchmark

The current graph benchmark is not an end-to-end comparison of the two CLEAR
language designs. `bench_node.clear` exercises `@node` through the full CLEAR
frontend and backend, but the reported `LINK`/`RESOLVE` results come from
`bench_clear_runtime.zig`, a hand-written runtime harness.

After C FFI is complete, add a matching CLEAR-source `LINK`/`RESOLVE`
benchmark and run it beside `bench_node.clear` with identical node count,
edge-generation formulas, read/write rounds, checksums, optimization mode,
allocator, CPU pinning, and reporting. Keep the Zig runtime harness only as a
lower-level control. The benchmark report must label frontend-to-backend CLEAR
results separately from direct runtime microbenchmarks.
