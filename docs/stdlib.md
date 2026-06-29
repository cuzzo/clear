# CLEAR Standard Library

Status: planned public specification, not a stable API.

This page describes the standard library CLEAR intends to grow into. Most of
these APIs are intentionally not implemented yet. We want the design visible
early, but we do not want users depending on unstable packages before the error,
effect, capability, string, and package contracts are nailed down.

The short version:

- Most stdlib code should be written in CLEAR.
- Zig is reserved for syscalls, runtime integration, allocator boundaries,
  scheduler hooks, cryptography/entropy, and small performance kernels.
- API style should feel closer to Elixir/Ruby collection ergonomics plus
  Rust/Zig boundary explicitness.
- CLEAR has structs, free functions, UFCS, and pipelines. The stdlib should not
  recreate classes, mixins, inheritance, or dynamic Ruby-style method lookup.

## Status Tags

| Tag | Meaning |
| --- | --- |
| `planned` | Intended shape, not implemented or stable. |
| `prototype` | Some implementation exists, but the API may change. |
| `intrinsic today` | Exists as a compiler/runtime intrinsic rather than a source package. |
| `self-host required` | Needed for the compiler self-host path. |
| `stable` | Compatibility promise. No API on this page is stable yet. |

## Publishing Model

This page is the first stdlib deliverable.

Public docs live under `docs/` and are published to the GitHub Pages site by the
existing Zola pipeline:

```text
docs/stdlib.md
  -> ruby tools/gen_site.rb
  -> site/content/docs/stdlib.md
  -> zola build
  -> GitHub Pages
```

Implementation comes later. We will avoid creating broad package stubs until a
package has a concrete compiler self-host or launch use case and the relevant
design decisions are settled.

See also:

- [Modules and build system](modules.md)
- [Collections](collections.md)
- [Pipelines](pipelines.md)
- [Sharing capabilities](sharing-capabilities.md)
- [Tense composition](tense-composition.md)

## Package Map

| Package | Status | Purpose |
| --- | --- | --- |
| `core` / prelude | `prototype`, `self-host required` | Primitive values, predicates, formatting, basic conversion. |
| `collections` | `planned`, `self-host required` | Lists, slices, maps, sets, ranges, pools, transforms. |
| `string` | `planned`, `self-host required` | UTF-8 text helpers, builders, search, split/join. |
| `bytes` | `planned`, `self-host required` | Byte buffers and byte-level parsing. |
| `regex` | `planned`, `self-host required` | Regex values with explicit match results. |
| `scanner` | `planned`, `self-host required` | Stateful text/byte scanner for lexers and parsers. |
| `fs` | `planned`, `self-host required` | File read/write/stat/resource APIs. |
| `path` | `planned`, `self-host required` | Path join, normalize, basename, dirname, glob policy. |
| `json` | `planned`, `self-host required` | JSON parse/generate/pretty-generate. |
| `cli` | `planned`, `self-host required` | Typed command-line option parsing. |
| `process` | `planned` | Spawn, capture, exit status, stdio pipes. |
| `env` | `planned` | Environment and current-directory access. |
| `time` | `planned`, `self-host required` | Monotonic time, wall time, duration, sleep. |
| `random` | `planned` | Secure randomness and deterministic test RNGs. |
| `math` | `prototype` | Numeric functions and checked arithmetic helpers. |
| `testing` | `prototype`, `self-host required` | Assertions, diffs, expected errors, fixtures, oracle tests. |
| `network` | `prototype` | TCP resources first; broader network later. |
| `encoding` | `planned` | CSV, binary encode/decode, later TOML/YAML if justified. |
| `crypto` | `planned` | Hashing and cryptographic primitives. |
| `compress` | `planned` | Compression/archive support, post-core. |

Package imports should use the existing package form:

```ruby
REQUIRE "pkg:collections";
REQUIRE "pkg:fs" AS fs;
```

## Core And Prelude

Status: `prototype`, `self-host required`.

Core should stay small. It is for primitives and operations that nearly every
program needs:

| API | Status | Notes |
| --- | --- | --- |
| `Bool`, integers, floats, `String`, `?T` | `prototype` | Primitive language types. |
| `nil?`, `present?` | `intrinsic today` | Optional checks. |
| `empty?`, `any?` | `intrinsic today` | Collection/string presence checks. |
| `zero?`, `positive?`, `negative?`, `between?`, `closeTo?` | `intrinsic today` | Numeric predicates. |
| `toString`, `toInt`, `toFloat`, `toNumber` | `intrinsic today` | Conversion helpers. |
| `format` | `planned` | Preferred formatting API. |
| `print`, `debugPrint` | `intrinsic today` / `planned` | Basic output; debug form should be explicit. |
| `ASSERT`, `panic`, `unreachable` | `planned` | Assertion and termination surface. |

Open design point: CLEAR needs to settle whether fallible APIs expose native
error unions, a named `Result`, or both.

## Collections

Status: `planned`, `self-host required`.

Launch collection types:

| Type | Status | Notes |
| --- | --- | --- |
| Slice | `prototype` | Borrowed view over contiguous values. |
| List/vector | `intrinsic today` | Growable contiguous collection. |
| Map/hash | `intrinsic today` | Hash map; deterministic views required for compiler output. |
| Set | `intrinsic today` | Hash set; deterministic views required for compiler output. |
| Range | `prototype` | Numeric iteration and slicing. |
| Pool/slab | `intrinsic today` | Stable handles and compiler/runtime structures. |
| Queue/deque | `planned` | Add when compiler or scheduler code needs it. |

Planned transform surface:

| API | Status | Return/behavior |
| --- | --- | --- |
| `each` | `self-host required` | Side-effect iteration, returns `Void`. |
| `map` | `self-host required` | Allocates a new list from final block expression. |
| `select` / `filter` | `self-host required` | Keeps items whose predicate is true. |
| `reject` | `self-host required` | Inverse filter. |
| `filterMap` | `self-host required` | Maps to `?T`, keeps non-nil values. |
| `flatMap` | `self-host required` | Maps to collections and flattens. |
| `reduce` / `fold` | `self-host required` | Explicit accumulator. |
| `any?`, `all?` | `self-host required` | Short-circuit predicates. |
| `find` | `self-host required` | Returns `?T`. |
| `sum`, `count` | `self-host required` | Numeric and predicate aggregation. |
| `sort`, `sortBy` | `self-host required` | Stable sort for compiler/tool output. |
| `keys`, `values`, `pairs` | `self-host required` | Map traversal; sorted variants needed. |
| `indexed` | `self-host required` | Replacement for `each_with_index`. |
| `withObject` / `foldInto` | `self-host required` | Replacement for `each_with_object`. |

Illustrative shape:

```ruby
names = users
    |> SELECT { _.active?() }
    |> MAP { _.name };
```

Open design points:

- Iterator model without classes or traits.
- Generic specialization model for collection functions.
- Deterministic iteration defaults versus explicit sorted views.
- Mutation naming for `map!`-style operations.

## Strings And Bytes

Status: `planned`, `self-host required`.

Strings are UTF-8 text. Byte buffers are byte data. The stdlib should keep that
distinction visible even when both are backed by `[]u8`.

| API | Status | Notes |
| --- | --- | --- |
| `length` | `intrinsic today` | String/list length; exact string semantics still need naming clarity. |
| `bytes` | `intrinsic today` | Byte length. |
| `codepointCount` | `intrinsic today` | UTF-8 codepoint count. |
| `byteAt` | `intrinsic today` | Byte-level access. |
| `charAt` | `intrinsic today` | Codepoint/text access. |
| `substr` | `intrinsic today` | Slice/copy behavior depends on string ownership. |
| `split`, `splitLines`, `join` | `intrinsic today` / `planned` | Compiler self-host needs line and token splitting. |
| `trim`, `startsWith?`, `endsWith?`, `contains?`, `indexOf` | `intrinsic today` | Search/predicate helpers. |
| `replace`, `downcase`, `upcase` | `intrinsic today` | Initial versions are byte/ASCII oriented. |
| `StringBuilder` | `planned` | Avoid repeated concatenation allocation. |
| `format` / interpolation | `planned` | Explicit allocation and formatting rules. |

Open design points:

- Byte-indexed, codepoint-indexed, and grapheme-aware operation names.
- Whether `String` can hold invalid UTF-8.
- Builder ownership and allocator behavior.

## Regex And Scanner

Status: `planned`, `self-host required`.

Ruby-style global match state should not exist in CLEAR. Regex APIs should
return explicit match values.

| API | Status | Notes |
| --- | --- | --- |
| `Regex.compile(pattern)` | `planned` | Fallible compile with explicit error. |
| `regex.match(text)` | `planned` | Returns `?Match`. |
| `Match#captures`, `Match#range`, `Match#text` | `planned` | Explicit match result object. |
| `escapeRegex(text)` | `self-host required` | Needed for Ruby `Regexp.escape` shapes. |
| `Scanner.new(text)` | `self-host required` | Replacement for Ruby `StringScanner`. |
| `scan`, `peek`, `advance`, `eos?`, `matched`, `pos` | `self-host required` | Lexer/parser support. |

Open design points:

- Regex subset and unsupported-pattern diagnostics.
- Whether scanner belongs in `pkg:scanner` or under `pkg:string`.
- Match result allocation and lifetime.

## Files, Directories, And Paths

Status: `planned`, `self-host required`.

Host-facing filesystem APIs must carry file effects and explicit failure.

| API | Status | Notes |
| --- | --- | --- |
| `readFile(path)` | `intrinsic today` | Reads full file. |
| `readLines(path)` | `self-host required` | Can be built from `readFile` plus `splitLines`. |
| `writeFile(path, content)` | `intrinsic today` | Writes full file. |
| `appendFile(path, content)` | `planned` | Needed by tooling eventually. |
| `File.open`, `File.create`, `fileReadAll`, `fileWrite` | `intrinsic today` | Resource-style file APIs. |
| `fileExists?`, `regularFile?`, `dirExists?`, `symlinkExists?` | `self-host required` | Migration pressure from Ruby compiler. |
| `fileSize`, `fileModifiedTime` | `intrinsic today` / `self-host required` | Metadata. |
| `joinPath`, `expandPath`, `baseName`, `dirName`, `relativePath` | `self-host required` | Path manipulation. |
| `listDir`, `listAll`, `globPaths`, `walkDir` | `intrinsic today` / `self-host required` | Directory traversal; deterministic ordering matters. |

Open design points:

- Linux-first versus cross-platform path behavior.
- Sorted directory/glob results by default or explicit sorted variants.
- Public error type for filesystem failures.

## JSON And Encoding

Status: `planned`, `self-host required`.

| API | Status | Notes |
| --- | --- | --- |
| `Json.parse(text)` | `self-host required` | Dynamic JSON value first; typed decode later. |
| `Json.generate(value)` | `self-host required` | Stable object ordering for compiler metadata. |
| `Json.prettyGenerate(value)` | `self-host required` | Tooling output. |
| `Csv.read`, `Csv.write` | `planned` | Post-core unless a tool requires it. |
| Binary encode/decode helpers | `planned` | Compiler cache and bytecode use cases. |
| TOML/YAML | `planned` | Defer until package/config needs are concrete. |

Open design points:

- Untyped JSON value representation.
- Schema-directed decode API.
- Deterministic map ordering during generation.

## CLI, Process, And Environment

Status: `planned`, `self-host required` for CLI basics.

| API | Status | Notes |
| --- | --- | --- |
| `argv` | `intrinsic today` | Current process arguments. |
| `Cli.parse(spec, argv)` | `self-host required` | Typed option parser. |
| `envGet`, `envSet`, `currentDirectory` | `planned` | Effectful host access. |
| `Command{ argv, env, cwd }` | `planned` | Process description. |
| `run(command)`, `capture(command)` | `planned` | Spawn and capture output/status. |

Open design points:

- Package-level permissions for env and process access.
- Whether subprocess APIs are ordinary stdlib or tooling-only.

## Time, Random, And Math

Status: `prototype` / `planned`.

| API | Status | Notes |
| --- | --- | --- |
| `Instant.now`, `Duration` | `planned` | Monotonic timing. |
| `Timestamp.now` | `intrinsic today` through `timestampMs` | Wall-clock time. |
| `sleep(duration)` | `intrinsic today` | Scheduler-aware suspension. |
| `fileModifiedTime(path)` | `self-host required` | Filesystem metadata bridge. |
| `random`, `randomInt` | `intrinsic today` | Secure random by default. |
| deterministic RNG | `planned` | Tests and reproducible tooling. |
| `min`, `max`, `abs`, `floor`, `ceil`, `round`, `sqrt`, `log`, `exp` | `intrinsic today` / `planned` | Numeric helpers. |
| checked/wrapping/saturating arithmetic | `planned` | Names and semantics need design. |

Open design points:

- Timezone/calendar scope for launch.
- Secure randomness capability/effect.
- Arithmetic overflow naming and default behavior.

## Testing And Diagnostics

Status: `prototype`, `self-host required`.

`pkg:testing` exists as a package-resolution smoke test today. The real package
should support compiler and stdlib oracle testing.

| API | Status | Notes |
| --- | --- | --- |
| `ASSERT`, equality assertions | `planned` | Core test assertions. |
| Approximate float assertions | `planned` | `closeTo?`-style testing. |
| Expected compile/runtime error assertions | `self-host required` | Compiler tests need this. |
| Diffs for strings, arrays, structs, maps | `self-host required` | Useful failure output. |
| Fixtures and golden files | `self-host required` | Oracle tests. |
| Test filtering | `planned` | CLI runner support. |
| Leak/profile hooks | `planned` | Runtime integration. |

Open design point: test declarations could be compiler syntax, library calls,
or a mix. We should not freeze `pkg:testing` until that is settled.

## Network

Status: `prototype`, not self-host critical.

| API | Status | Notes |
| --- | --- | --- |
| `TCPServer.listen(port)` | `intrinsic today` | Resource API. |
| `TCPClient.connect(host, port)` | `intrinsic today` | Resource API. |
| `accept`, `tcpRead`, `tcpWrite` | `intrinsic today` | Scheduler-aware operations. |
| UDP | `planned` | Only when examples/tools require it. |
| HTTP/TLS | `planned` | Post-core; do not rush into launch. |

Open design points:

- Package-level network permissions.
- TLS and certificate store policy.
- Async/scheduler API boundaries.

## Capability And Effect Policy

Stdlib APIs must make host effects visible:

| Area | Effects/capabilities |
| --- | --- |
| Files | `FILE_READ`, `FILE_WRITE`, allocation, possible blocking/suspension. |
| Network | `NETWORK_READ`, `NETWORK_WRITE`, suspension. |
| Process/env | process spawn, environment read/write, stdio capture. |
| Time/random | non-determinism; sleep suspends. |
| Collections/strings | allocation and mutation. |
| Locks/concurrency | blocking and scheduler interaction. |

Package docs should state these effects even before STRICT mode requires public
effect declarations.

## Stabilization Gate

An API should not move from `planned` to `prototype` until:

1. The relevant language decision points are resolved.
2. A compiler self-host or launch use case needs it.
3. It can be tested through `REQUIRE "pkg:<name>"`.
4. It does not require Ruby compatibility machinery.
5. The public docs can describe failure, allocation, ownership, and effects
   honestly.

An API should not move to `stable` until:

1. It has integration tests and examples.
2. The implementation is mostly in CLEAR unless a boundary justifies Zig.
3. The error and effect contracts are documented.
4. The name and behavior fit CLEAR even when translated from Ruby source.

## Initial Work Order

1. Keep this public spec visible and update it as decisions settle.
2. Inventory current intrinsics and assign each to a planned package owner.
3. Implement only the source packages needed by compiler self-hosting.
4. Use ruby-to-clear coverage audits to pick the next stdlib surface.
5. Promote APIs from `planned` to `prototype` only when tests and docs agree.
