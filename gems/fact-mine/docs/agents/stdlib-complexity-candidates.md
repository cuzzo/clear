# Standard-library complexity candidate inventory

## Conclusion

A large YAML catalogue is useful hygiene, but it is not the lever that turns
most incomplete Espalier results into complete bounds. A configuration may only
model a call when Fact-Mine has already proved both its native API identity and
the receiver/input shape that gives the operation a documented bound. Most
incomplete calls in the corpus are project calls, callbacks, interface/protocol
dispatch, or calls with unresolved receiver/callee identity.

The correct source of future mappings is the machine-readable review queue:

```sh
espalier --format unknown_operations <source roots...>
```

Each row now preserves exact per-operation call occurrences and includes
`typed_unmodeled_occurrences`. That field is the upper-bound queue for a
registry review: it means Fact-Mine resolved a type but emitted no normalized
cost. It does **not** mean that the operation is standard library or safely
mappable; project types and protocol calls are intentionally present for human
triage.

## Corpus evidence

The 35-repository corpus currently contains these type-proven but unmodeled
call occurrences:

| Language | Calls | Distinct operations | Interpretation |
| --- | ---: | ---: | --- |
| C++ | 462 | 206 | Mostly template/projection gaps and fmt project types |
| C# | 848 | 325 | Mostly Serilog/project writers and sinks |
| Go | 445 | 179 | Reflection/project calls plus a useful core-package subset |
| Java | 847 | 446 | Project writers/models plus a useful JDK static subset |
| Python | 630 | 253 | Typed project/parser values and generic-wrapper normalization gaps |
| TypeScript | 143 | 117 | Inferred project values and static built-in subset |
| Other scanned languages | 0 | 0 | Their primary gap is unresolved receiver/callee identity, not a missing registry row |
| **Total** | **3,375** | **1,526** | An upper-bound review queue, not 1,526 safe mappings |

A conservative namespace-shaped scan finds roughly 2,453 call occurrences
across 511 distinct operation spellings. This is deliberately only a discovery
heuristic: it includes calls such as C++ template helpers and JavaScript APIs
that can invoke user hooks, so it must never feed YAML automatically.

## Candidate families

| Language | Good candidates after identity is proven | Must stay unknown or need a richer model |
| --- | --- | --- |
| C | `strcpy`, `strncpy`, `strcat`, `strcmp`, `memset`, plus other ISO string/memory primitives | allocators, syscalls, platform APIs, project helpers; two-input searches stay unknown until the operation algebra can represent `O(N*M)` time with `O(1)` auxiliary space |
| C++ | direct `std` algorithms (`find`, `copy`, `lower_bound`, `sort`) and direct container methods | template forwarding/casts, ordered containers until their separate model, allocator-dependent APIs |
| Go | `strings`/`bytes` scans and materializers, `sort`, `slices`, `maps`, primitive `errors`/`time`/`atomic` calls | `fmt` where rendered size is not modeled, reflection, synchronization wall time, arbitrary interfaces |
| Java | `Math`, primitive wrappers, concrete `String`/`Arrays`/`Collections` calls | `List`/`Map` interfaces, user `equals`/hashing, reflection/class loading, IO |
| C# | `Math`, primitive/string operations, concrete array helpers and selected pure `Path` transforms | streams/text writers, serializers, LINQ callbacks, interface dispatch |
| Python | proven builtin `str`, `list`, `dict`, `set`, `bytes`, and selected `collections` operations | regex (backtracking), duck-typed/module-overridable calls, filesystem/IO |
| JavaScript / TypeScript | primitive numeric/string/Array/Map/Set operations with a proven intrinsic receiver | `Object.assign`, JSON, promises and prototype APIs that can invoke getters, setters, proxies, or user hooks |
| Kotlin / Swift | concrete standard collection and string methods once declaration/literal types are normalized | protocol/sequence/lazy collection and extension dispatch |
| Rust / Zig | direct concrete containers and documented string/slice helpers | traits, iterators, allocators and user containers |
| PHP / Lua | core functions/modules with non-overridable identity and explicit input-size semantics | polymorphic Countable/metatable/framework APIs, IO |

## Why the first registry pass completed only 22 functions

Completeness is conjunctive: one unresolved call makes a function incomplete.
The initial registry correctly improved normalized lower-bound facts and
removed 519 unknown operation/function pairs, but most affected functions had
another unresolved project or callback call. Therefore the 22 increase in
complete bounds is evidence that standard-library names are not the primary
bottleneck, not evidence that the registry is ineffective.

## Follow-up conservative expansion

The subsequent exact-native expansion added ISO C string/memory calls, Go
`strings`/`bytes`/`slices`/`maps` operations, Java arrays/collections/math,
C# array/math/path/string APIs, and Python string/bytes operations. It also
fixed C's synthetic bare-call receiver so configured C intrinsics actually
reach the registry.

Against the same 35-repository corpus, it raises complete time bounds from
4,946 to 5,036 (+90) and reduces unknown operation/function pairs from 42,820
to 42,224. The TypeScript pair count deliberately increases by 44 because
`Object.keys`/`values`/`entries` were removed: proxies and getters can execute
user code, and global binding identity is not yet proven. The detailed graph
and timing feasibility evidence is in
[`minimal-call-graph-feasibility.md`](minimal-call-graph-feasibility.md).

## Priority order

1. Preserve exact call provenance and use `typed_unmodeled_occurrences` to
   review only calls whose type is already known.
2. Add small, documented native families with high corpus frequency—especially
   Go `strings`/`bytes`, Java JDK pure statics, C ISO strings, and proven Python
   builtin string operations.
3. Fix language-adapter call projection/type normalization where it prevents a
   genuine native call from reaching the registry (notably C++ direct `std`
   functions, Kotlin/Swift concrete collections, and Python literal strings).
4. Keep interfaces, callbacks, IO, reflection, user hooks, and project calls
   unknown. Making those look complete would be less useful than an explicit
   partial bound.

The durable goal is a high-quality native core catalogue plus better facts—not
a huge unsound name list.
