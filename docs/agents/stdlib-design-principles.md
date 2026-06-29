# CLEAR Stdlib Design Principles

Status: design principles.

Date: 2026-06-29.

## Core Goal

The stdlib's first architectural goal is composability with CLEAR's effects,
capabilities, and tense system.

Stdlib APIs should compose across:

- pure/stateless functions;
- stateful handles such as files, sockets, scanners, builders, and streams;
- capability-wrapped values such as `@locked`, `@shared`, `@local`, and
  future package permissions;
- effectful boundaries such as file IO, network IO, process execution, time,
  randomness, allocation, and blocking;
- tense-aware values, including snapshots, live state, historical values,
  derived state, and streamed/current values where the language supports them.

The user should be able to start with a high-level stateless API and only add
state, effects, capabilities, or tense-specific machinery when the program
actually needs it.

## User-Facing Priority

After composability, the stdlib's highest user-facing priority is to feel as
high-level as possible.

This is true even when a traditional systems language would consider the API
"too convenient" or "not explicit enough." CLEAR is not trying to make every
program read like Zig, C, or Rust. CLEAR should give users Ruby/Elixir-level
ergonomics by default and expose systems-level detail only when that detail is
needed for correctness, performance, or capability control.

The default bias is:

- Prefer a high-level interface when the lower-level interface mainly exposes
  implementation mechanics.
- Prefer Ruby/Elixir-style convenience when the operation has an obvious safe
  default.
- Prefer explicit systems controls only when hiding them would create a major
  correctness, performance, or security flaw.
- When a harder API is necessary, make it only slightly harder than the
  high-level path and explain what additional control the user is getting.

This means the stdlib should not force users to think about allocators, readers,
writers, buffers, file descriptors, backpressure, stream lifetimes, socket
polling, or scheduler integration for common code. Those concepts should exist,
but they should be opt-in.

## What Counts As A Major Systems Flaw

We should deviate from a high-level API only for major flaws, not for ordinary
systems-language taste.

Major flaws include:

- hidden unbounded memory growth in common usage;
- impossible or misleading resource lifetime semantics;
- data races or capability violations;
- effect/capability behavior that the compiler cannot track;
- performance cliffs that are large, common, and hard to diagnose;
- APIs that make deterministic compiler output unreliable;
- APIs that prevent a lower-level zero-cost path from existing.

Non-major reasons are not enough by themselves:

- "Zig would make the allocator explicit."
- "Java would force a stream object."
- "Rust would encode this as a trait-heavy iterator stack."
- "C would expose the buffer and length."

Those can be valid implementation details. They are not automatically good
CLEAR user interfaces.

## IO And Streams Are The Test Case

File and network IO are the clearest examples.

CLEAR should not make opening files or doing file/network IO as hard as Java or
Zig for ordinary users. A user should be able to write obvious high-level code:

```ruby
text = fs.read("config.clear");
lines = fs.readLines("users.txt");
fs.write("out.txt", report);
```

The same principle applies to pipelines. The pipeline system should default to
using streams internally where it can, because streaming is the right execution
strategy for IO and large inputs. But the default result should still be the
collection high-level users expect: usually a list.

Illustrative shape:

```ruby
users = fs.lines("users.csv")
    |> MAP { parseUser(_) }
    |> SELECT { _.active?() };
```

The implementation should be free to stream `users.csv` line by line. The user
should not need to opt into streaming just to avoid a bad implementation. But
because the pipeline result is not explicitly requested as a stream, the final
value should collect into a list.

If the user wants a stream, hashmap, set, or another collection, they should ask
for it explicitly:

```ruby
active_stream = fs.lines("users.csv")
    |> MAP { parseUser(_) }
    |> SELECT { _.active?() }
    |> AS_STREAM;

users_by_id = fs.lines("users.csv")
    |> MAP { parseUser(_) }
    |> COLLECT_MAP { _.id => _ };

unique_domains = fs.lines("emails.txt")
    |> MAP { domainOf(_) }
    |> COLLECT_SET;
```

The exact names are not settled. The principle is settled:

- streams are a preferred internal execution strategy;
- lists are the default collected result for high-level pipelines;
- other result shapes are explicit;
- systems programmers can request stream/control forms without fighting the
  high-level API.

This is the kind of tradeoff CLEAR should make repeatedly. A systems language
might require explicit stream types everywhere. CLEAR should infer and use the
efficient strategy internally, then return the ergonomic shape by default.

## Stateless And Stateful Pairs

Many stdlib areas need both stateless and stateful APIs.

The stateless form should be the default:

```ruby
content = fs.read("input.txt");
tokens = scanner.scanAll(source);
json = Json.parse(text);
```

The stateful form should appear when it buys something real:

```ruby
file = fs.open("input.txt");
stream = file.lines();
scan = Scanner.new(source);
builder = StringBuilder.new();
```

The stateful form should not be the only way to do common work. It exists for
large inputs, incremental processing, resource reuse, backpressure, explicit
cleanup, and performance-sensitive code.

## Effects And Capabilities Should Be Visible, Not Noisy

The compiler should know that `fs.read` has a file-read effect, allocates, and
can fail. The user should not have to spell all of that at every call site.

Preferred posture:

- Effects are inferred for normal code.
- Public package boundaries document effects.
- Strict modes can require effect declarations.
- Capability permissions are visible where they matter, especially package and
  host boundaries.
- High-level APIs remain high-level unless the user opts into strict control.

For example, `fs.read("config.clear")` should be easy. In a restricted package
or strict build, the compiler can still require that the package is allowed to
perform file reads.

## Naming Bias

Prefer names that read naturally in pipelines and UFCS:

- Ruby/Elixir-style collection names: `map`, `select`, `reject`, `filterMap`,
  `flatMap`, `find`, `any?`, `all?`, `reduce`, `sortBy`.
- Ruby-style predicates when they are compact and obvious: `empty?`,
  `present?`, `nil?`, `startsWith?`, `endsWith?`.
- Systems names only at systems boundaries: `open`, `close`, `flush`, `sync`,
  `readInto`, `writeAll`, `reserve`, `capacity`.

Avoid names that force users to learn the backing implementation before they
can write ordinary code.

## Defaults

Default choices should be optimized for high-level users:

| Area | Default | Explicit lower-level path |
| --- | --- | --- |
| Pipeline result | collect to list | `AS_STREAM`, `COLLECT_MAP`, `COLLECT_SET`, fixed array |
| File read | read whole text or lines | open handle, stream lines, read bytes, read into buffer |
| Network read | message/bytes helper where possible | socket/client resource and stream control |
| Strings | UTF-8 text operations | byte buffers and byte indexing |
| Errors | ergonomic fallible call syntax | explicit result/error handling |
| Effects | inferred and documented | strict declarations and package permissions |
| Allocation | implicit safe allocation | reserve/capacity/allocator-aware APIs |
| Mutation | immutable/new collection transforms | explicit mutating names |

The lower-level path must exist. It should not be the first thing users see.

## Key Decisions Before Self-Host Implementation

The self-host project can implement a lot with existing intrinsics and thin
source packages, but these decisions should be made before most stdlib work
lands:

1. **Pipeline result defaults.** Confirm that pipelines use streams internally
   where practical and collect to lists unless the user explicitly requests a
   stream, map, set, fixed array, or other result shape.
2. **Explicit collection request syntax.** Choose names and syntax for
   `AS_STREAM`, `COLLECT_LIST`, `COLLECT_MAP`, `COLLECT_SET`, and typed
   collection targets.
3. **Error model.** Decide whether fallible stdlib APIs expose native error
   unions, a named `Result`, ergonomic `try`, or a combination.
4. **Effect visibility.** Decide which effects are public stdlib contracts for
   self-host packages: file read/write, process/env, network read/write, time,
   random, allocation, blocking, and extern.
5. **Capability permissions.** Decide how packages declare or receive authority
   to touch files, network, processes, environment, clocks, and randomness.
6. **Resource lifetime model.** Decide how high-level APIs auto-close resources
   and how stateful handles express cleanup, ownership, borrowing, and escape.
7. **Stream lifetime and backpressure.** Decide how streams interact with file
   handles, sockets, fibers, scheduler suspension, and collection boundaries.
8. **Tense integration.** Decide how stdlib APIs expose snapshots, live views,
   historical values, and streamed current values without making ordinary APIs
   noisy.
9. **Stateless/stateful API pairing.** Decide the naming convention for simple
   convenience functions versus explicit handle/builder/scanner/stream APIs.
10. **String and bytes split.** Decide byte indexing, codepoint indexing,
    invalid UTF-8 handling, and conversions between `String` and byte buffers.
11. **Deterministic ordering.** Decide whether map/set iteration, directory
    listing, globbing, JSON object generation, and diagnostic output sort by
    default or require explicit sorted variants.
12. **Generic and iterator model.** Decide how collection functions specialize
    without importing a class/trait/interface model that CLEAR does not want.
13. **Mutation convention.** Decide how mutating collection/string operations
    are named and how aliasing/capability hazards are rejected.
14. **Docs stability labels.** Decide the public status vocabulary for planned,
    prototype, self-host required, intrinsic today, and stable APIs so docs do
    not imply premature compatibility.

These decisions should not block every tiny wrapper, but they should block wide
stdlib implementation. We can publish the shape in docs first, then implement
only the self-host subset once the defaults are coherent.
