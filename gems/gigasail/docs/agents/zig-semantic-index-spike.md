# Zig Semantic-Index Spike

Measured 2026-07-16 against the 32-file production import closure in
[`zig-production-sources.txt`](zig-production-sources.txt), using Zig and ZLS
0.16.0. This is a feasibility measurement, not a production indexer.

FactMine currently accounts for 747 of 4,707 eligible calls: 715 exact project
targets and 32 modeled operations (15.87%). The spike queried ZLS
`textDocument/definition` at every one of the 3,960 unresolved normalized call
sites. It deliberately did not turn definitions into trusted FactMine targets.

| Result | Calls | Share of unresolved |
| --- | ---: | ---: |
| Project production declaration | 1,423 | 35.93% |
| Zig standard-library declaration | 2,182 | 55.10% |
| Compiler/ZLS builtin declaration | 7 | 0.18% |
| No definition | 278 | 7.02% |
| Call-message position needs range repair | 70 | 1.77% |

ZLS supplied a semantic definition for 3,612 of 3,890 queried positions
(92.85%), or 91.21% of all currently unresolved calls when range misses are
included. Representative project targets included `release`, `add`, `deinit`,
`ensureOwnership`, and `unlock`; representative stdlib targets included
`Allocator.rawFree`, `Thread.yield`, Linux `errno`, and C `closedir`.

If a producer preserves these definitions faithfully, exact project-target
coverage has a measured path from 15.19% to approximately 45.42%. If reviewed
Zig stdlib cost models cover the compiler-proven external identities, total
call accounting has a measured ceiling near 92.6%. Those two figures must not
be conflated: a modeled stdlib call is not an exact project target.

## Decision

Fund a Zig producer, but implement it as a thin ZLS-to-SCIP bridge rather than
adding Zig dispatch inference to FactMine. The bridge should emit documents,
declaration/reference occurrences, exact source ranges, symbols, and any
implementation relationships ZLS can prove. Shared SCIP ingestion, candidate
bounds, generated summaries, and Big-O closure remain language-neutral.

The first production milestone should index this fixed corpus and require:

- exact target-span oracles for project calls;
- explicit Zig stdlib identities without embedded cost guesses;
- stable handling of imports, comptime aliases, generic instantiations, and
  builtins;
- no positional fallback when ZLS returns no definition;
- separate exact, modeled, candidate-set, and unresolved metrics.

The 278 no-definition calls and 70 range misses are the bounded residual
investigation. They do not justify reproducing Zig type inference inside the
shared resolver.
