# Standard-library complexity mappings

Fact-Mine owns the language-specific standard-library spellings used to emit
normalized complexity facts. Espalier consumes only those facts and performs
language-neutral symbolic algebra; it must not load a per-language operation
table or infer a cost from source text.

Each supported Fact-Mine language has a `<language>.yml`. It maps a normalized
receiver family (`Array`, `Hash`, `Set`, `String`, or a concrete nominal
library type) and method spelling to one of:

- `constant`
- `logarithmic`
- `linear_scan`
- `linear_materialize`
- `sort`
- `pairwise`

An `Intrinsic` section maps a standard-library free function (`strlen`) or a
fully qualified static call (`Collections.sort`). A qualified mapping never
matches a same-named unqualified call, and a bare mapping is reserved for a
language's non-redefinable core functions. This prevents a project helper such
as `sort` or `len` from silently receiving a library cost.

## Per-language scope and safety boundary

| Language | Mapped native surface | Deliberately left unknown |
| --- | --- | --- |
| Ruby | Array, Hash, Set, String, and Sorbet-safe core constructors | user methods and dynamic dispatch |
| Python | concrete `list`, `dict`, `set`, `str` methods | bare built-ins whose argument type is unresolved or user-overridable |
| JavaScript / TypeScript | concrete Array, Map, Set, string, and selected `Array`/`Object` statics | prototype-patched/custom receivers and generated-code helpers |
| Java | ArrayList/Vector, HashMap, HashSet, String, Arrays/Collections statics | List/Map/Collection interfaces and TreeMap/TreeSet: their implementation cost is not universal |
| C# | `List`, Dictionary, HashSet, String, selected BCL statics | IEnumerable/IList interfaces and LINQ operations with callback costs not yet modeled |
| Go | builtin `len`/`cap` and typed slice/map/string shapes | reflection, interfaces, and package APIs without a stable intrinsic contract |
| C++ | vector/array/span, unordered map/set, basic string, selected `std` algorithms | list/deque and ordered map/set, whose contracts differ from dense/hash collections |
| C | ISO C string/memory/search/sort functions | project helpers and allocation functions whose cost depends on allocator/input provenance |
| Kotlin | concrete ArrayList/HashMap/HashSet/String | List/Map interfaces and sequence/lambda pipelines |
| Swift | Array/Dictionary/Set/String | lazy sequences, protocol existentials, and user-defined collection conformers |
| Rust | Vec, HashMap, HashSet, String | trait-based iterators and BTree collections unless their separate logarithmic model is added |
| Zig | ArrayList, hash maps, string helpers | allocator-dependent and user container APIs |
| PHP | documented core array/string functions | framework helpers and polymorphic Countable calls without proven core binding |
| Lua | qualified `table` and `string` module functions | arbitrary table/metatable methods |

The distinction is intentional: an absent mapping produces an evidence gap and
a ranked Espalier unknown-operation entry. Adding a mapping is appropriate only
when the language guarantees both the receiver/API identity and the bound.

Adding a mapping requires a minimal Fact-Mine/Espalier golden fixture that
proves both the emitted fact and rendered time/space result. Unknown calls are
deliberately left unmapped and are emitted with an evidence-gap reason rather
than guessed by a downstream analyzer.
