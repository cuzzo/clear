# Standard-library complexity registry audit

## Scope and method

Espalier must remain language-neutral: it consumes normalized complexity facts
and performs symbolic composition. Fact-Mine owns native API identity and its
documented operation cost in `config/stdlib_complexity/<language>.yml`.

The registry now has one reviewable YAML file for every Fact-Mine language:
Ruby, Python, JavaScript, TypeScript, Java, C#, Go, C++, C, Kotlin, Lua, PHP,
Rust, Swift, and Zig. It maps only a concrete standard-library receiver or a
non-redefinable intrinsic. Interface/protocol types, callback pipelines,
allocator-dependent operations, user methods, and unresolved calls deliberately
remain unknown.

Native declaration spellings are also isolated in `src/syntax/<language>.rs`.
The shared nominal parser contains only structural parsing mechanics and
adapter-supplied families; it contains no language/library spelling.

I compared the previous registry revision (`80faaf948`) with the new registry
across all 24 mini corpus repositories and all 11 larger target repositories
(35 total). The baseline additionally carries only the malformed-generic
slicing guard, so an invalid external type cannot make the comparison crash.
The scan uses the repository roots/source roots previously documented for this
corpus. Some mini-repository roots include tests; the figures are therefore a
stable before/after comparison, not a production-only benchmark.

## Results

| Language | Repos | Functions | Complete time: before → after | Delta | Unknown operation/function pairs: before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| C | 4 | 2,165 | 258 → 270 | +12 | 6,761 → 6,454 |
| C++ | 4 | 1,938 | 654 → 654 | 0 | 4,068 → 4,069 |
| C# | 4 | 1,674 | 626 → 623 | -3 | 2,568 → 2,581 |
| Go | 4 | 985 | 271 → 271 | 0 | 3,418 → 3,414 |
| Java | 5 | 2,352 | 680 → 680 | 0 | 4,571 → 4,601 |
| Kotlin | 1 | 3,191 | 1,324 → 1,324 | 0 | 10,353 → 10,353 |
| Lua | 1 | 726 | 78 → 88 | +10 | 2,807 → 2,646 |
| Python | 5 | 1,830 | 406 → 408 | +2 | 4,998 → 4,977 |
| Swift | 1 | 264 | 29 → 29 | 0 | 677 → 677 |
| TypeScript | 6 | 1,696 | 598 → 599 | +1 | 3,118 → 3,048 |
| **Total** | **35** | **16,821** | **4,924 → 4,946** | **+22** | **43,339 → 42,820** |

The small raw gain is expected. Most remaining unknowns are project calls,
callbacks, or unresolved receiver/callee facts—not missing names in a standard
library table. The registry materially improves C and Lua because their
standard-library calls are explicit. The newly conservative C#/Java/C++ parser
does not pretend that `IList`, `List`, `Map`, or ordered containers have a
universal native bound. That makes a few formerly “complete” functions
incomplete, but removes unsound claims rather than regressing an actual known
bound.

## Per-language mapping policy

- **C:** ISO string/memory/search/sort intrinsics only; allocator and project
  helpers remain unknown.
- **C++:** dense `vector`/`array`/`span`, unordered maps/sets and strings;
  ordered and node-based containers remain unknown until their distinct bounds
  are represented.
- **C#:** concrete `List`, Dictionary, HashSet and strings; no interface or
  LINQ inference without receiver/callback facts.
- **Go:** builtin `len`/`cap` plus type-proven slice/map/string operations.
- **Java/Kotlin:** only concrete dense/hash types; interfaces stay unknown.
- **JavaScript/TypeScript:** native Array/Map/Set/string operations and exact
  static intrinsics; no lookalike project methods.
- **Lua/PHP/C:** free/module intrinsics only when the language guarantees their
  binding; PHP polymorphic `Countable` dispatch is intentionally unmapped.
- **Rust/Swift/Zig:** direct concrete standard containers only; traits,
  protocols, lazy iterators, allocator-dependent calls and user containers stay
  unknown.

## Ranked unknown-operation workflow

Espalier now supports:

```sh
espalier --format unknown_operations <source roots...>
```

It emits `espalier.unknown-operations.v1`, grouped by source language and
ranked by actual call occurrence count, affected incomplete functions, and
operation name. Each row includes the exact Fact-Mine evidence-gap frequencies,
locations, and `typed_unmodeled_occurrences` for the registry-review subset.
It is intentionally a review queue rather than a second registry:

1. A documented native call with a proven receiver belongs in that language’s
   Fact-Mine YAML and gets a minimal golden regression.
2. `unresolved_receiver_type` or `unresolved_call_target` means improve type or
   call facts—not add a name mapping.
3. A project helper, callback, protocol/interface call, or input-dependent
   library operation remains unknown until a sound general model exists.

The command was smoke-tested across Python and C source roots and correctly
returned separate ranked groups for both languages.
