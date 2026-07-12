<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# Stdlib Design Principles

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


## Core Goal

The stdlib's first architectural goal is composability with CLEAR's
effects, capabilities, and tense system.

Stdlib APIs should compose across:

- pure/stateless functions;
- stateful handles such as files, sockets, scanners, builders, and streams;
- capability-wrapped values such as `@locked`, `@shared`, and `@local`;
- effectful boundaries such as file IO, network IO, process execution,
  time, randomness, allocation, and blocking;
- tense-aware values, including snapshots, live state, historical values,
  derived state, and streamed/current values where the language supports
  them.

The user should be able to start with a high-level stateless API and only
add state, effects, capabilities, or tense-specific machinery when the
program actually needs it.

## High-Level Default

After composability, the stdlib's highest user-facing priority is to feel
as high-level as possible.

This is true even when a traditional systems language would consider the
API too convenient. CLEAR should expose Ruby/Elixir-level ergonomics by
default and expose systems-level detail only when that detail is needed
for correctness, performance, or capability control.

We deviate from high-level interfaces for major flaws:

- hidden unbounded memory growth in common usage;
- impossible or misleading resource lifetime semantics;
- data races or capability violations;
- effect/capability behavior that the compiler cannot track;
- performance cliffs that are large, common, and hard to diagnose;
- APIs that make deterministic compiler output unreliable;
- APIs that prevent a lower-level zero-cost path from existing.

Ordinary systems-language preference is not enough by itself. "Zig would
make the allocator explicit" or "Java would force a stream object" may be
true, but those are not automatically good CLEAR user interfaces.

## IO And Streams

File and network IO are the test case. CLEAR should not make ordinary IO
as hard as Java or Zig.

```ruby clear illustrative
text = fs.read("config.clear") OR_ELSE RAISE;
lines = fs.readLines("users.txt") OR_ELSE RAISE;
fs.write("out.txt", report) OR_ELSE RAISE;
```

Pipelines should default to using streams internally where that is the
efficient strategy, especially for IO and large inputs. A pipeline can be
collected implicitly by its destination type, or explicitly with a
terminal such as `COLLECT_LIST`, `COLLECT_SET`, `COLLECT_MAP`, or
`AS_STREAM`.

```ruby clear illustrative
users = (fs.readLines("users.csv") OR_ELSE RAISE)
    |> MAP { parseUser(_) }
    |> SELECT { _.active?() };
```

The implementation may stream `users.csv` line by line. Because the
assignment target is a list, the final value collects into that list.

Users who want a stream, map, set, or another collection request it
explicitly:

```ruby clear illustrative
active_stream = (fs.readLines("users.csv") OR_ELSE RAISE)
    |> MAP { parseUser(_) }
    |> SELECT { _.active?() }
    |> AS_STREAM;

users_by_id = (fs.readLines("users.csv") OR_ELSE RAISE)
    |> MAP { parseUser(_) }
    |> COLLECT_MAP { _.id => _ };

unique_domains = (fs.readLines("emails.txt") OR_ELSE RAISE)
    |> MAP { domainOf(_) }
    |> COLLECT_SET;
```

The exact names are not final. The principle is final: stream internally
where practical, collect from the explicit terminal or destination type,
and never insert hidden sorts or other semantic work during collection.

Ordering is explicit. Directory scans and globbing should be unsorted
streams unless the user asks otherwise:

```ruby clear illustrative
files = fs.glob("src/**/*.clear") OR_ELSE RAISE;
sorted = files |> ORDER_BY _;
```

A future `SORT` shorthand may sort by the singular value, but that
depends on the traits/interfaces or duck-typed ordering decision. Today
`ORDER_BY` is the explicit sortable pipeline operator.

## Key Decisions Before Self-Host Implementation

1. Confirm pipeline result defaults: stream internally where practical;
   collect according to explicit terminal or destination type.
2. Choose explicit collection target syntax: `AS_STREAM`, `COLLECT_LIST`,
   `COLLECT_MAP`, `COLLECT_SET`, and typed collection targets.
3. Define the named error taxonomy and future `Result` relationship;
   prototype stdlib APIs use native `!T` fallibility and `OR`
   propagation.
4. Decide which effects are public stdlib contracts for self-host
   packages: file read/write, process/env, network read/write, time,
   random, allocation, blocking, and extern.
5. Decide package capability permissions for files, network, processes,
   environment, clocks, and randomness.
6. Decide resource lifetime and stream lifetime rules.
7. Decide the stateless/stateful naming convention.
8. Decide the string/bytes split and deterministic ordering defaults.
