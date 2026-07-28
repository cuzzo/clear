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
opaque semantic-environment attestations, optional exact-prefix relocation or
generated exact symbol bridges, producer joins, consumer comparisons, and
atomic publication. None of those stages branches on a language.

`compatibility` claims are exact string key/value pairs produced by a manifest
or a language-owned probe. The shared join does not interpret keys such as
runtime artifact digest, target triple, sysroot, or ABI; it merely requires the
consumer profile to carry every claim required by the bundle. A
`fact-mine.symbol-bridge.v1` sidecar maps analyzed implementation symbols to
consumer declaration symbols. This is the common mechanism for declaration-only
or cross-language runtimes, and the bridge digest is retained in the generated
summary. Bridge commands run after the producer profile and unrelocated summary
exist, and may use `{profile}` and `{producer_summary}` in addition to the
standard manifest substitutions.

When implementation and consumer source require different SCIP producers, a
manifest may declare `summary.consumer_indexers`. The generated summary retains
the implementation indexer as producer provenance but activates only for one
of those exact consumer `tool@version` identities. The symbol bridge remains
responsible for proving each cross-indexer declaration identity.

Current publishable mappings:

| Language | Source | Indexer | Exact symbols |
|---|---|---|---:|
| Go | Go 1.22.2 core surface | scip-go 0.2.7 | 322 |
| Rust | Rust 1.96.0 `core`/`alloc`/`std` | rust-analyzer 1.96.0 | 1,543 |
| Java | JDK 21.0.12 `java.lang`/`java.util` | scip-java 0.12.3 | 2,598 |
| Python | CPython 3.11.9 selected pure-Python core | scip-python 0.6.6 | 200 |
| C# | .NET 10.0.10 CoreLib collections/string/array | scip-dotnet 0.2.14 | 316 |
| Kotlin | Kotlin/JVM 2.2.0 stdlib | semanticdb-kotlinc 0.6.0 + patch | 85 |
| C++ | libstdc++ 13.3.0 selected C++17/C++20 surfaces | scip-clang 0.4.0 | 772 unique |

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

- C standard-library symbols from scip-clang use `cxx . .`.
  `c/semantic_environment.rb` now closes the missing consumer identity by
  attesting the libc binary and release, effective public headers, compiler,
  target, semantic flags, preprocessor macros, and scip-clang binary. The
  remaining blocker is an implementation producer: the matching patched glibc
  source must be configured and indexed under that same environment before a
  bundle can be published.
- TypeScript and JavaScript built-ins resolve to versioned TypeScript `.d.ts`
  declarations. Those files have no executable bodies, while the real
  implementations belong to a particular JS engine and release.
  `javascript/semantic_environment.rb` now pins the Node binary and release,
  V8 release, native-module ABI, and scip-typescript binary for both languages.
  This removes runtime identity as an excuse for a guessed declaration model;
  the remaining producer must analyze the matching V8/Node bodies and generate
  the declaration bridge while retaining callback and reflective cost
  parameters.
- PHP built-ins can be connected to their `php-src` C implementations through
  the generic cross-indexer symbol bridge, and
  `php/scip-php-exact-version.patch` replaces scip-php's hard-coded `0.0.1`
  metadata with its exact source revision. A PHP 8.4.21 producer trial
  nevertheless exported zero of 70 analyzed `zif_*` string built-ins under the
  source-proof policy. Weak scalar coercion can invoke user object handlers,
  while Zend allocation depends on allocator state and hooks; both costs must
  remain parametric. Publishing the apparent native helper cost would silently
  discard those executable paths, so PHP remains fail-closed until generated
  summaries can carry and compose those runtime cost parameters.

These are compatibility failures, not requests for manual overrides. Move an
entry to `bundled` only after its required identity/body capability exists and a
manifest passes the same producer and consumer checks. Missing version text in
a SCIP symbol is no longer itself a blocker: a reproducible environment
attestation may supply the missing compatibility identity without weakening the
exact-symbol join.

The C# manifest works around scip-dotnet 0.2.14's stale
`0.1.0-SNAPSHOT` SCIP metadata without trusting that text: its language-owned
index recipe checks the released CLI version, and its compatibility sidecar
pins both the installed indexer binary and .NET reference-assembly digests.
The generated runtime bundle maps only exact, assembly-qualified consumer
symbols. On the current Serilog production corpus the released indexer itself
raises completion from 755/888 (85.02%) to 765/888 (86.15%); the generated
bundle has zero additional count impact because all overlapping calls already
had complete fallback models, and it produces no complete/complete
disagreements.

The three C++ manifests preprocess bounded libstdc++ surfaces under the exact
consumer compiler configuration before SCIP indexing. Because scip-clang uses
unversioned `cxx . .` symbols, each bundle requires an opaque language-owned
attestation of the compiler binary, target, C++ standard, macro set, effective
generic and architecture-specific header overlays, and scip-clang binary.
Only exact-bound `std::` rows cross the generated identity bridge. C++ template
functions with unmodeled implicit construction, assignment, or destruction
fail the generic source-export gate through the C++ behavior interface rather
than being published as O(1). The eventpp, plog, and proxy audits join 2, 30,
and 4 calls respectively with zero complete/complete disagreements; all were
already covered by complete fallback models, so their function-completion
counts do not change.
