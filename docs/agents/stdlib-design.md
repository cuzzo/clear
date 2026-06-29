# CLEAR Standard Library Design

Status: design draft.

Date: 2026-06-29.

## Goal

Define the launch and self-host standard library shape for CLEAR without turning
the stdlib into a Ruby compatibility runtime or a Zig wrapper dump.

The first deliverable is public documentation, not implementation. We should
publish the planned stdlib shape on the GitHub Pages site so interested users
can see the direction, but deliberately avoid implementing most of it until the
core contracts are stable. A documented API is a design artifact; it is not a
compatibility promise until explicitly marked stable.

The default implementation language should be CLEAR. Zig belongs at hard
boundaries: syscalls, allocator and arena machinery, process and network
integration, runtime scheduler hooks, byte-level performance kernels, and
libraries where reimplementation would distract from compiler self-hosting.

The public API should borrow the useful parts of Ruby and Elixir:

- Ruby names where they are compact and familiar: `empty?`, `any?`, `map`,
  `select`, `reject`, `join`, `split`, `starts_with?`.
- Elixir's functional bias where it avoids object-model baggage: first-class
  collection transforms, explicit accumulator functions, explicit match
  results, and pipelines.
- Rust/Zig style at capability and system boundaries: explicit ownership,
  explicit failure, explicit allocation/effects, no hidden global state.

CLEAR is closer to C/Zig plus accessible functional programming than to Java or
Ruby. The stdlib should therefore expose structs, free functions, UFCS-friendly
methods, and pipeline primitives. It should not smuggle in classes, mixins,
traits, or implicit dynamic dispatch to make Ruby source feel native.

## Existing Design

Today the stdlib has two different surfaces:

- `src/ast/std_lib.rb` is a compact intrinsic registry. It describes built-in
  functions and methods, their types, Zig templates, allocation behavior,
  ownership behavior, mutating receivers, suspension, bytecode lowering, and
  resource schemas.
- `stdlib/<name>/src/lib.cht` is the first-party package layout. The module
  importer auto-resolves `REQUIRE "pkg:<name>"` after explicit `--pkg` paths.
  At the moment only `pkg:testing` exists, and it is a smoke-test skeleton.

That split is the right direction:

- Source packages should hold normal library APIs that can be authored,
  tested, documented, and eventually self-hosted in CLEAR.
- The intrinsic registry should stay small and boundary-oriented. Its job is to
  attach compiler-known contracts to operations that cannot be expressed as
  ordinary CLEAR yet, or that need direct runtime/Zig support.

Existing intrinsic coverage already includes list/map/set/pool operations,
string helpers, numeric predicates, filesystem helpers, TCP resources,
time/sleep/random, profiling helpers, and testing-oriented predicates. The
stdlib design should migrate higher-level policy out of this registry over
time, not expand it into a general standard library authoring language.

The effects design already points in the same direction. Allocation, blocking,
external calls, file read/write, and network read/write must be tracked by the
compiler. Stdlib APIs should be one of the main places those contracts are made
visible and stable.

The public documentation site already has the right publishing path:

- `docs/` is the source of truth for public site content.
- `docs/agents/` is intentionally excluded from the site and stays internal.
- `tools/gen_site.rb` maps public markdown under `docs/` into Zola content under
  `site/content/docs/`.
- `.github/workflows/pages.yml` runs `ruby tools/gen_site.rb`, then `zola build`
  and deploys `site/public` to GitHub Pages.

Therefore the stdlib plan needs both:

- `docs/agents/stdlib-design.md`: internal implementation, migration, and
  decision record.
- `docs/stdlib.md`: public planned API/spec page rendered by the Zola site.

## External Launch Lessons

Primary references:

- Go 1 release notes: https://go.dev/doc/go1
- Rust 1.0 announcement: https://blog.rust-lang.org/2015/05/15/Rust-1.0/
- Rust `std` crate documentation: https://doc.rust-lang.org/std/
- Zig download history: https://ziglang.org/download/
- Zig language reference stdlib section: https://ziglang.org/documentation/0.16.0/
- Elixir `Enum`: https://hexdocs.pm/elixir/Enum.html
- Ruby `Enumerable`: https://ruby-doc.org/3.4.1/Enumerable.html

### Go

Go 1 treated the standard library as a stable product foundation. Its launch
surface included broad batteries: archives, compression, crypto, encoding
packages such as JSON/XML/CSV, `fmt`, `io`, `os`, `path/filepath`, `net`,
`http`, `regexp`, `strconv`, `strings`, `sync`, `time`, and `testing`. Go also
used the Go 1 moment to regularize package names and APIs, then made stability
the central promise.

Lesson for CLEAR: launch stability matters more than breadth. A broad stdlib is
useful, but only after the language's ownership, capability, effect, error,
string, and package contracts are stable. Do not copy Go's package count before
copying its commitment to boring, consistent behavior.

### Rust

Rust 1.0 launched around a smaller, systems-oriented core: `Option`, `Result`,
`Vec`, `String`, slices, iterators, collections, formatting, I/O, filesystem,
networking, paths, process, threads, synchronization, time, and macros. Rust's
1.0 announcement emphasized stability after pre-1.0 churn, while leaving many
higher-level libraries to crates.

Lesson for CLEAR: a strong core plus package ecosystem beats a huge unstable
stdlib. CLEAR should copy Rust's explicit error and ownership posture, but not
copy trait-heavy API designs that conflict with CLEAR's "structs plus UFCS"
direction.

### Zig

Zig's early public history was pre-1.0 and intentionally unstable; the official
download page lists 0.1.1 in 2017 with language reference and source release,
while standalone standard-library docs appear in later release rows. Current
Zig documentation describes std as common algorithms, data structures, and
definitions, and the stdlib is rendered from the local compiler distribution
with `zig std`.

Lesson for CLEAR: Zig's useful influence is not API breadth. It is explicit
allocation, explicit platform boundaries, compile-time specialization, and a
small amount of runtime magic. CLEAR should use Zig as the model for boundary
honesty, not for exposing every low-level helper directly to users.

## Design Principles

1. Document first, implement second. Public stdlib docs should mark planned,
   prototype, and stable APIs distinctly so people can track the direction
   without being invited to depend on unfinished surfaces.
2. Implement in CLEAR unless the boundary forces Zig.
3. Keep zero-cost translations zero-cost. Do not add a Grumpy-style runtime to
   support source-language behavior that CLEAR does not want.
4. Make effects part of stdlib contracts. File, network, process, allocation,
   blocking, randomness, and time are observable capabilities, not casual
   helpers.
5. Prefer deterministic compiler tooling. Map/set iteration and filesystem
   traversal need explicit sorted variants when output order matters.
6. Use UFCS and pipelines as the ergonomic layer. A function should be usable as
   `map(xs, fn)` and `xs.map(fn)` or `xs |> MAP { ... }` where the compiler can
   lower it efficiently.
7. Avoid object-model compatibility. No classes, mixins, singleton classes,
   dynamic method tables, or hidden `respond_to?` equivalents in stdlib APIs.
8. Make nil/failure explicit. Prefer `?T`, `Result`/error unions, or named
   failure-return APIs over implicit Ruby exceptions or global match state.
9. Preserve byte/string clarity. Unicode text and byte buffers must have
   distinct contracts even when backed by `[]u8`.
10. Keep the prelude small. Pervasive names should be limited to primitives,
   predicates, basic formatting, and collection operations that read naturally.

## Documentation First

The first stdlib epic is a documentation pipeline and public spec, not a
library implementation.

The source of truth should be public markdown under `docs/`, because the
existing GitHub Pages workflow already publishes that through Zola. The initial
page should be `docs/stdlib.md`, and later expansion can split it into
`docs/stdlib/*.md` if the Zola generator gains nested section support.

The public docs should include:

- A clear "planned, not stable" banner.
- A package map for `core`, `collections`, `string`, `bytes`, `regex`,
  `scanner`, `fs`, `path`, `json`, `cli`, `process`, `env`, `time`, `random`,
  `math`, `testing`, and `network`.
- API sketches with status tags: `planned`, `prototype`, `intrinsic today`,
  `self-host required`, and `stable`.
- Effect and capability notes on every host-facing package.
- Examples that read like CLEAR, but are labelled illustrative unless they
  compile today.

Do not generate real `stdlib/<pkg>/src/lib.cht` packages for every planned
surface yet. A wide stub package tree would make it look like the stdlib is
available and would encourage early dependency on APIs we still expect to
change. Until a package is ready for compiler or launch use, the public docs
should be the artifact.

The implementation gate for a documented API is:

1. The relevant language decision gates in this document are resolved.
2. The API has at least one compiler self-host or launch use case.
3. The package has integration tests through `REQUIRE "pkg:<name>"`.
4. The public docs can mark the API `prototype` or `stable` without misleading
   users.

## Package Shape

First-party packages should follow the existing layout:

```text
stdlib/
  collections/src/lib.cht
  string/src/lib.cht
  fs/src/lib.cht
  path/src/lib.cht
  regex/src/lib.cht
  json/src/lib.cht
  cli/src/lib.cht
  testing/src/lib.cht
```

They should be imported as:

```clear
REQUIRE "pkg:collections";
REQUIRE "pkg:fs" AS fs;
```

Core/prelude functions may remain compiler-known for now, but new non-boundary
stdlib work should prefer source packages. A package API that cannot be written
in CLEAR should call one or more narrow intrinsics rather than becoming a large
intrinsic row itself.

## CLEAR vs Zig Boundary

| Area | Prefer CLEAR | Use Zig only for |
| --- | --- | --- |
| Collection transforms | `map`, `filter`, `reject`, `reduce`, `sortBy` wrappers and policies | Backing storage primitives, hashing kernels, sort kernels if needed |
| Strings | API composition, trimming/splitting policy, formatting wrappers | UTF-8 validation/iteration kernels, allocation-heavy builders |
| Regex/scanner | Explicit `Match` and `Scanner` API surface | Regex engine, DFA/NFA execution, byte scanning hot loops |
| Files/path | Path API, ordering policy, error normalization | Syscalls, open/read/write/stat, platform path quirks |
| Network | TCP/UDP resource wrappers, capability gating | Sockets, poll/epoll/io_uring integration, TLS primitives |
| Process/env | Typed option parser, command descriptions | Spawn/exec/wait, env access, stdio pipes |
| Time/random | Duration/time wrappers, deterministic test hooks | OS clocks, entropy, crypto RNG |
| Testing | Assertions, diffs, fixtures, golden/oracle helpers | Test runner integration, leak hooks, process isolation |

## Critical Components

### Core And Prelude

Launch surface:

- `Bool`, integer and float helpers, `String`, byte slices, ranges, `?T`,
  result/error union conventions, `NIL`, `TRUE`, `FALSE`.
- Basic predicates: `nil?`, `present?`, `empty?`, `any?`, `zero?`,
  `positive?`, `negative?`, `between?`, `closeTo?`.
- Formatting and printing: `format`, `print`, `debugPrint`, `toString`,
  `toInt`, `toFloat`.
- Assertions that are useful outside `pkg:testing`: `ASSERT`, `panic`,
  `unreachable`.

Self-host requirement: P0. The compiler code already depends heavily on
strings, booleans, optionals, arrays, maps, predicates, and diagnostics.

Decision gate: whether `Result` is a named stdlib type, native error union
syntax, or both. The stdlib should not invent an ad hoc error convention before
the compiler settles the public error model.

### Collections

Launch data structures:

- Fixed arrays and slices.
- Growable list/vector.
- Hash map and set.
- Ordered map/set or sorted views where deterministic output matters.
- Range.
- Pool/slab for compiler and runtime structures.
- Queue/deque only if the compiler or scheduler needs it before launch.

Launch transforms:

| Operation | Ruby/Elixir influence | CLEAR direction |
| --- | --- | --- |
| `each` | Ruby block iteration | Side-effect loop/pipeline, returns `Void` |
| `map` | Ruby `map`, Elixir `Enum.map` | Allocate new list, final block expression is value |
| `select`/`filter` | Ruby `select`, Elixir `filter` | Allocate new list where predicate is true |
| `reject` | Ruby `reject` | Implement as inverse filter, no special runtime |
| `filterMap` | Ruby `filter_map` | Map optional values and compact non-nil results |
| `flatMap` | Ruby/Elixir `flat_map` | Concatenate mapped collections with visible allocation |
| `reduce`/`fold` | Elixir `reduce`, Ruby `inject` | Explicit accumulator type and return |
| `any?`/`all?` | Ruby predicates | Short-circuit where possible |
| `find` | Ruby `find` | Return `?T`; no exception or sentinel |
| `sortBy` | Ruby `sort_by` | Stable sort for compiler output |
| `keys`/`values`/`pairs` | Ruby hash helpers | Deterministic sorted variants for tool output |

Self-host requirement: P0. The ruby-to-clear audit shows `each`, `map`,
`any?`, `filter_map`, `select`, `flat_map`, `find`, `reject`,
`each_with_object`, `sort_by`, `map!`, `sum`, `each_key`, `each_value`, and
`each_pair` are direct coverage drivers.

Implementation direction:

- Write transform APIs in CLEAR over a small iterator protocol or compiler
  pipeline primitive.
- Keep backing storage and mutation primitives intrinsic until CLEAR can express
  the same allocation and ownership contracts.
- Add sorted/deterministic variants before relying on map/set traversal for
  compiler output.

Decision gates:

- Iterator model: external iterator structs, compiler-lowered pipelines, or
  both.
- Generic constraints without traits/interfaces. If CLEAR avoids traits, the
  stdlib needs a practical generic story for collection element operations.
- Mutation convention for `map!`-style operations. Prefer explicit mutation
  names and reject aliasing hazards.

### Strings, Bytes, Regex, And Scanner

Launch surface:

- `String` as UTF-8 text.
- `Bytes` or raw byte slices for byte-oriented compiler/runtime work.
- `length`/`codepointCount` and `bytes` as distinct operations.
- `split`, `splitLines`, `join`, `trim`, `startsWith?`, `endsWith?`,
  `contains?`, `indexOf`, `replace`, `downcase`, `upcase`.
- String builder for repeated concatenation.
- `format`/interpolation lowering with explicit allocation.
- `Regex` with compiled pattern values and explicit `Match` results.
- `Scanner` with `scan`, `peek`, `eos?`, `matched`, `pos`, and manual advance.

Self-host requirement: P0/P1. Lexer/parser code needs byte scanning,
StringScanner-like state, interpolation support, regex escaping, and explicit
match captures.

Implementation direction:

- Write most string API composition in CLEAR.
- Keep UTF-8 decode/validate and scanner hot loops in Zig initially.
- Regex can bind to Zig/runtime implementation first, but the CLEAR API must not
  expose Ruby's global match state. `Regexp.last_match`, `$1`, and equivalent
  behavior should translate to explicit `Match` values or be TODOed.

Decision gates:

- Unicode contract: which operations are byte-indexed, codepoint-indexed, or
  grapheme-aware.
- Regex subset: define unsupported constructs up front and fail closed.
- Whether scanner is a core package or `pkg:regex` sibling.

### Math, Numeric, And Random

Launch surface:

- `min`, `max`, `abs`, `floor`, `ceil`, `round`, `log`, `exp`, `sqrt`,
  trigonometry if needed for launch examples.
- Parse/format helpers for integers and floats.
- Checked arithmetic helpers if they are not native syntax.
- `random`, `randomInt`, and seedable deterministic RNG for tests.

Self-host requirement: P1/P2. The compiler needs numeric parsing, integer
formatting, counters, and stable test randomness more than broad math.

Implementation direction:

- Thin CLEAR wrappers over compiler/Zig numeric primitives.
- Crypto-quality randomness should be a capability/effectful host boundary.
- Deterministic RNG should be pure CLEAR if practical.

Decision gate: how CLEAR names and exposes checked, wrapping, saturating, and
overflow-trapping arithmetic.

### Files, Directories, And Paths

Launch surface:

- `readFile`, `readLines`, `writeFile`, `appendFile`, `deleteFile`.
- `File.open`, `File.create`, `fileReadAll`, `fileWrite`, resource close.
- `fileExists?`, `regularFile?`, `dirExists?`, `symlinkExists?`.
- `fileSize`, `fileModifiedTime`, permissions where needed.
- `joinPath`, `expandPath`, `baseName`, `dirName`, `relativePath`.
- `listDir`, `listAll`, `globPaths`, recursive walk.

Self-host requirement: P0. The Ruby compiler uses `File.exist?`, `File.join`,
`File.expand_path`, `File.readlines`, `File.read`, `File.basename`,
`File.dirname`, `Dir.glob`, `Dir.exist?`, `File.write`, `File.mtime`, and
related helpers.

Implementation direction:

- Use Zig/syscall intrinsics for IO and metadata.
- Write path normalization, sorting, filtering, line splitting, and glob result
  policy in CLEAR when possible.
- Make file APIs effectful: `FILE_READ`, `FILE_WRITE`, and allocation should be
  visible to the compiler.

Decision gates:

- Cross-platform path semantics at launch. Linux-only is acceptable if stated;
  silent partial portability is not.
- Error model: return `!T`, `Result<T, FsError>`, or raise compiler-known
  errors. Pick one public convention before expanding APIs.
- Determinism: decide whether directory/glob results are sorted by default or
  require `sortedGlobPaths`.

### Network

Launch surface:

- TCP listen/connect/accept/read/write/close.
- UDP only if examples or runtime tests require it.
- DNS and HTTP should be separate packages and probably post-self-host unless
  tool distribution requires them.

Self-host requirement: not P0. Existing runtime has TCP intrinsics, but the
compiler self-host does not need broad networking.

Implementation direction:

- Resource wrappers in CLEAR.
- Socket integration, scheduler waits, TLS, and platform-specific polling in
  Zig/runtime.
- Effects should distinguish `NETWORK_READ` and `NETWORK_WRITE`.

Decision gate: package-level capability permissions for network access.

### Process, Environment, And CLI

Launch surface:

- `argv` and typed argument parsing.
- `envGet`, `envSet` if needed, `currentDirectory`.
- `Command` description with argv/env/cwd/stdin/stdout/stderr.
- `run`, `capture`, and exit status values.
- `pkg:cli` option parser with typed specs.

Self-host requirement: P1/P2. The transpiler audit only shows small
`OptionParser` pressure now, but compiler tooling, test harnesses, and build
scripts will need process execution and argument parsing.

Implementation direction:

- CLI parser in CLEAR.
- Spawn/exec/env in Zig/runtime.
- Prefer typed option specs over Ruby block-driven parsers.

Decision gates:

- Security/effect model for environment and process access.
- Whether subprocess APIs are available in ordinary stdlib or only tooling
  profiles.

### Time And Date

Launch surface:

- `Instant`/monotonic time for durations.
- `Timestamp`/wall time for logs and file metadata.
- `Duration`.
- `sleep` as a scheduler-aware operation.
- File mtime conversion helpers.

Self-host requirement: P1. `File.mtime` appears in migration pressure; broader
date/time formatting can wait.

Implementation direction:

- OS clocks in Zig/runtime.
- Duration arithmetic and formatting in CLEAR.

Decision gate: wall-clock/time-zone scope. Launch should avoid full calendar and
timezone support unless a direct compiler/tooling requirement appears.

### Encoding And Serialization

Launch surface:

- JSON parse/generate/pretty-generate.
- CSV if used by diagnostics or tooling.
- Binary encode/decode helpers for compiler caches and bytecode.

Self-host requirement: P1. `JSON.parse`, `JSON.generate`, and
`JSON.pretty_generate` are low-count but real compiler/tooling dependencies.

Implementation direction:

- Parser/generator in CLEAR if performance is acceptable.
- A Zig JSON kernel is acceptable as an interim boundary if it avoids blocking
  self-hosting, but the public API should be typed and deterministic.

Decision gates:

- Untyped JSON value representation.
- Stable object key ordering for generated metadata.
- Whether decode should prefer schema-directed typed decoding over dynamic maps.

### Testing, Diagnostics, And Tooling

Launch surface:

- `pkg:testing` with assertions, equality diffs, approximate float checks,
  expected errors, fixtures, golden files, and test filtering.
- Oracle/integration test helpers for compiler output.
- Diagnostic formatting helpers shared by compiler and tests.
- Profiling hooks that are clearly debug/tooling APIs.

Self-host requirement: P0/P1. Ruby-to-CLEAR coverage is intentionally driven by
oracle tests, and compiler self-hosting needs a native way to prove generated
CLEAR behaves correctly.

Implementation direction:

- Assertions and diffs in CLEAR.
- Test runner hooks, leak detection, process isolation, and profiler snapshots
  in runtime/Zig where necessary.

Decision gate: test declaration syntax and whether `pkg:testing` is purely a
library or partly compiler-lowered.

### Concurrency And Capability Helpers

Launch surface:

- The language owns capabilities: `@local`, `@locked`, `@writeLocked`,
  `@shared`, `@multiowned`, `@indirect`, `@alwaysMutable`.
- Stdlib should expose small utility functions around channels/queues/sleep
  only where they preserve the language's capability model.

Self-host requirement: limited. The compiler uses concurrency and profiling
internals, but broad user-facing concurrency APIs can follow the capability
architecture instead of leading it.

Implementation direction:

- Prefer compiler/language features for locks and ownership.
- Use stdlib wrappers for queues, work pools, channels, and timers only when
  there is a clear source-level API.

Decision gate: whether channels/streams are core language constructs, stdlib
types, or later packages.

## Launch MVP

The launch stdlib should contain enough to write serious command-line tools and
compiler code without stabilizing a huge surface.

| Priority | Component | Launch commitment |
| --- | --- | --- |
| P0 | Core/prelude | primitives, option/result/error convention, predicates, format/print |
| P0 | Collections | list, slice, map, set, range, transforms, deterministic sorted views |
| P0 | Strings/bytes | UTF-8 string, byte operations, split/join/trim/search/replace/builder |
| P0 | File/path/dir | read/write/stat/list/glob/path helpers with effects |
| P0 | Testing | assertions, diffs, expected errors, oracle/golden helpers |
| P1 | Regex/scanner | explicit match results, scanner state, safe regex subset |
| P1 | JSON | parse/generate/pretty with stable output |
| P1 | CLI/process/env | typed options, argv, env, subprocess capture |
| P1 | Time/random | monotonic/wall time, duration, deterministic and secure RNG |
| P2 | Network | TCP resources with capability/effect contracts |
| P2 | Encoding extras | CSV and binary encoding helpers |
| P3 | HTTP/TLS/compression/crypto | only after core semantics are stable |

## Self-Host Required Surface

For the compiler self-host, implement the following before expanding into
general-purpose launch niceties:

1. File/path/dir APIs used by the Ruby compiler: read, read lines, write,
   existence checks, path join/expand/basename/dirname, glob, directory exists,
   mtime, symlink helpers if still present.
2. Collections and transforms used by the transpiler output: list, map, set,
   `each`, `map`, `select`, `reject`, `filterMap`, `flatMap`, `find`, `any?`,
   `all?`, `sum`, `count`, `sortBy`, `keys`, `values`, `pairs`,
   indexed iteration, and accumulator iteration.
3. Strings and scanners for lexer/parser code: byte access, codepoint count,
   split lines, substring, replace, regex escape, explicit match result,
   scanner position and matched text.
4. JSON for metadata and tooling.
5. CLI and process helpers for compiler commands and test harnesses.
6. Testing package robust enough for oracle translation tests.
7. Diagnostic formatting and source-span helpers.

This is the minimum practical stdlib for self-hosting, not the full launch
stdlib.

## Decisions To Make Before Implementing Only Self-Host Needs

These should be settled before building a narrow compiler-only stdlib, because
they affect public API shape and will be expensive to unwind:

1. Error convention: native error unions, named `Result`, or a combination.
2. Effect names and enforcement for file, network, process, env, time, random,
   blocking, allocation, and extern calls.
3. Capability permissions for packages: how a package declares it may read
   files, write files, open sockets, spawn processes, or read environment.
4. Unicode/string indexing semantics.
5. Byte buffer type and conversion rules between `String` and bytes.
6. Iterator/pipeline model for collection transforms without traits or classes.
7. Generic specialization model for collection functions and maps/sets.
8. Deterministic ordering policy for maps, sets, directory listings, globbing,
   JSON objects, and diagnostics.
9. Regex subset and explicit match-result data model.
10. Package visibility, versioning, and stdlib compatibility promise.
11. Test declaration lowering: compiler syntax vs `pkg:testing` library calls.
12. Intrinsic registry ownership: what remains intrinsic after source packages
    exist.

## Roadmap

### Phase 0: Public Stdlib Spec Site

- Add `docs/stdlib.md` as the public planned stdlib spec.
- Keep `docs/agents/stdlib-design.md` as the internal decision record.
- Use the existing Zola path: `ruby tools/gen_site.rb` generates
  `site/content/docs/stdlib.md`, and GitHub Pages publishes it via
  `.github/workflows/pages.yml`.
- Add status labels to every listed package/API so unfinished surfaces are not
  mistaken for supported code.
- Do not create package implementations for speculative APIs in this phase.

### Phase 1: Boundary Inventory

- Audit `src/ast/std_lib.rb` and classify each entry as core/prelude,
  source-package wrapper, or permanent intrinsic.
- Add a short owner comment to permanent intrinsics explaining why CLEAR source
  cannot express it yet.
- Keep `pkg:testing` as the package smoke test and add one more trivial package
  to prove multi-package stdlib resolution.

### Phase 2: Self-Host Foundation

- Build `pkg:collections`, `pkg:string`, `pkg:fs`, `pkg:path`, and
  `pkg:testing` around existing intrinsics.
- Add oracle tests that use the same API shapes emitted by `ruby-to-clear`.
- Keep all APIs deterministic unless explicitly documented otherwise.
- Do not add Ruby compatibility shims. The transpiler should emit CLEAR-shaped
  APIs or TODO comments.

### Phase 3: Scanner, Regex, JSON, CLI

- Add `pkg:scanner` or `pkg:regex` with explicit match state.
- Add JSON parse/generate with stable object output.
- Add typed CLI option parsing.
- Add enough process/env APIs for compiler tooling, with effects.

### Phase 4: Launch Hardening

- Freeze naming and compatibility for P0/P1 packages.
- Move high-level policy out of `src/ast/std_lib.rb`.
- Add effect declarations to public package APIs when STRICT mode supports it.
- Add docs and examples for the launch API, not just compiler self-host usage.

### Phase 5: Optional Breadth

- Network beyond TCP basics.
- HTTP/TLS.
- Compression/archive.
- Crypto.
- CSV/YAML/TOML.
- Advanced time/date.

These should wait until the core effect, capability, string, error, and package
contracts are stable.

## Immediate Next Work

1. Publish the planned stdlib spec at `docs/stdlib.md` so the Zola site exposes
   the roadmap without creating usable packages prematurely.
2. Verify `ruby tools/gen_site.rb` can generate the public page for the GitHub
   Pages workflow.
3. Create a machine-readable inventory of current intrinsic registry entries:
   name, types, allocation, mutating receiver, effect/suspension, backing Zig
   helper, and proposed package owner.
4. Convert the self-host stdlib TODO into package-level issue lists under this
   design:
   `collections`, `string`, `fs`, `path`, `regex/scanner`, `json`, `cli`,
   `testing`.
5. Implement only the source-package wrappers needed by the self-host path after
   the public spec and relevant decision gates exist.
6. Add integration tests that compile small CLEAR programs using each package
   through `REQUIRE "pkg:<name>"`.
7. Use the ruby-to-clear audit as the coverage driver: if the transpiler can
   emit a direct CLEAR stdlib call for a safe Ruby shape, add that stdlib shape
   before hand-porting compiler code.
