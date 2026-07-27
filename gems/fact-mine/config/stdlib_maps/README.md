# Standard-library map support

`support.yml` is the machine-readable compatibility inventory for maintained
SCIP languages. `bundled` means the standard library is produced by a
`fact-mine.stdlib-map.v1` manifest and its generated artifact is discovered
automatically at FactMine build time. `blocked` means publishing a bundle would
violate the exact source/consumer identity contract; the required upstream
capability is recorded instead of silently shipping an unsafe approximation.

The shared producer supports pinned local or Git sources, sparse checkouts,
selected-file staging for indexers that scan an entire workspace, language-owned
build commands, exact indexer validation, parser/recovery soundness gates,
optional exact-prefix relocation, producer joins, consumer comparisons, and
atomic publication. None of those stages branches on a language.

Current publishable mappings:

| Language | Source | Indexer | Exact symbols |
|---|---|---|---:|
| Go | Go 1.22.2 core surface | scip-go 0.2.7 | 322 |
| Rust | Rust 1.96.0 `core`/`alloc`/`std` | rust-analyzer 1.96.0 | 1,543 |
| Java | JDK 21.0.12 `java.lang`/`java.util` | scip-java 0.12.3 | 2,598 |
| Python | CPython 3.11.9 selected pure-Python core | scip-python 0.6.6 | 200 |

The checked-in exact-symbol consumers prove that the generated data changes
the final function result, not merely call metadata:

| Consumer | Before | After | Delta |
|---|---:|---:|---:|
| Java 21 `BitSet.toLongArray()` | 0/1 complete | 1/1 complete | +1 |
| Python 3.11 `OrderedDict.move_to_end()` | 0/1 complete | 1/1 complete | +1 |

On Commons CLI, the Java bundle joins 12 call sites but changes no complete
function count (321/524 before and after) because those functions either were
already complete through a fallback or retain other evidence gaps. This is
still useful canonicalization, but it is not reported as completeness impact.

The remaining SCIP languages are deliberately fail-closed:

- C# consumer symbols are versioned, but the validated corpus was produced by
  an unreproducible `scip-dotnet 0.1.0-SNAPSHOT`; there is no exact producer
  build to pin.
- Kotlin standard-library symbols from scip-java use `maven . .`, so a bundle
  cannot distinguish Kotlin releases.
- C and C++ standard-library symbols from scip-clang use `cxx . .`; neither
  libc/libstdc++ identity nor version is present.
- TypeScript and JavaScript built-ins resolve to versioned TypeScript `.d.ts`
  declarations. Those files have no executable bodies, while the real
  implementations belong to a particular JS engine and release.

These are compatibility failures, not requests for manual overrides. Move an
entry to `bundled` only after its required identity/body capability exists and a
manifest passes the same producer and consumer checks.
