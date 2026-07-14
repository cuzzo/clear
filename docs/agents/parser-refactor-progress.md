# Parser refactor progress and metrics

This is the staged measurement ledger for
[`parser-refactor.md`](parser-refactor.md). Each implementation stage is
committed separately. Analyzer counts are only compared against reports made
with the same command and target file.

## Commands

The repository's locked bundle is not installed in this worktree. The staged
checks therefore use the available direct executables:

```sh
env FACT_MINE_RUST_BINARY=gems/fact-mine/target/debug/fact-mine-rust \
  ruby gems/nil-kill/exe/nil-kill static --root . --language ruby \
  --output tmp/parser-refactor-metrics/STAGE/nil-kill-static.json \
  compiler/ruby/ast/parser.rb

env FACT_MINE_RUST_BINARY=gems/fact-mine/target/debug/fact-mine-rust \
  ruby gems/espalier/exe/espalier --format yaml \
  --output tmp/parser-refactor-metrics/STAGE/espalier.yml \
  compiler/ruby/ast/parser.rb

gems/decomplex/target/debug/decomplex-rust report --language=ruby \
  --format=markdown \
  --output tmp/parser-refactor-metrics/STAGE/decomplex.md \
  compiler/ruby/ast/parser.rb
```

NilKill is deliberately run in static-only mode: no collection or inference.
The Decomplex Ruby executable cannot be used because this branch does not
contain `gems/decomplex/lib/decomplex`; the shipped Rust report executable is
used directly.

## Stage 0: baseline

Commit baseline: `486dbfc2` (before parser changes).

| Measure | Baseline |
| --- | ---: |
| Parser lines | 4,889 |
| `T.cast` sites | 50 |
| `T.must` sites | 161 |
| `T.unsafe` sites | 6 |
| NilKill methods | 182 |
| NilKill fields | 8 |
| NilKill hash shapes | 31 |
| NilKill array shapes | 1,461 |
| NilKill collection index lookups | 105 |
| NilKill hash-record blockers | 86 |
| NilKill dead nil checks | 1 |
| NilKill deterministic guards | 2 |
| Espalier functions | 182 |
| Espalier state slots | 8 |
| Espalier complete time results | 9 |
| Espalier incomplete time results | 173 |
| Espalier methods with known `O(2^N)` component | 95 |
| Espalier methods with known `O(N)` stack component | 96 |
| Decomplex total candidates | 438 |
| Decomplex convergence units | 84 |
| Decomplex root-cause clusters | 38 |
| Decomplex state-based branch findings | 69 |
| Decomplex scoped-state-restoration findings | 4 |
| Decomplex weighted-inlined-complexity findings | 81 |
| Decomplex decision-pressure contracts | 5 |
| Decomplex declared-type-pressure findings | 1 |

The replay stress input nests value blocks in calls:

```clear
f({ f({ f(); 0 }); 0 });
```

Adding one wrapper adds ten source bytes but approximately doubles parse time.
On this baseline, nesting depths 7 through 10 took 0.029, 0.063, 0.121, and
0.238 seconds. Espalier independently reports the receiver-cursor replay as a
known `O(2^N)` time component and `O(N)` live-stack component.

The directly runnable parser specs pass: 93 examples, 0 failures. The locked
bundle is missing MessagePack, SimpleCov, and Sorbet, so the canonical parser
compatibility, SimpleCov, and Sorbet commands cannot run in this environment.
New units will additionally be checked with Ruby's built-in line coverage so
the refactor does not depend on the unavailable SimpleCov wrapper.

## Stage observations

This section is extended at every implementation stage with metric deltas,
new-code findings, and detector gaps. A lower raw finding count is not treated
as success unless the corresponding parser contract actually improved.

### Stage 1: checked boundaries and typed AST defaults

The lexer now owns checked textual, integer, and float payload accessors. The
parser uses them at typed payload sites instead of reconstructing the
kind/value invariant with casts. The nine reviewed return contracts are now
non-nil, as are the immediately enclosing EXTERN and visibility dispatchers.
Program language mode, struct field tokens, and parser-produced `comptime` and
`tight` flags now have typed defaults.

| Measure | Baseline | Stage 1 | Delta |
| --- | ---: | ---: | ---: |
| Parser `T.cast` sites | 50 | 8 | -42 |
| Parser `T.must` sites | 161 | 94 | -67 |
| Parser `T.unsafe` sites | 6 | 6 | 0 |
| NilKill calls | 3,768 | 3,648 | -120 |
| NilKill array shapes | 1,461 | 1,419 | -42 |
| NilKill hash shapes | 31 | 31 | 0 |
| NilKill hash-record blockers | 86 | 86 | 0 |
| Espalier complete/incomplete time results | 9 / 173 | 9 / 173 | 0 / 0 |
| Espalier known `O(2^N)` component | 95 | 95 | 0 |
| Espalier known `O(N)` stack component | 96 | 96 | 0 |
| Decomplex candidates | 438 | 440 | +2 |
| Decomplex convergence units | 84 | 91 | +7 |
| Decomplex root-cause clusters | 38 | 39 | +1 |

The unchanged complexity values are expected: this stage corrects data
contracts and does not alter recursive parser control flow. NilKill's raw fact
counts reflect the eliminated casts and assertions, but it has no concise
headline for “reviewed false-nilable signatures corrected”; the nine method
signatures must currently be compared directly.

Decomplex's apparent regression is a detector bug, not new parser mutation.
It classifies the read-only `Token#text!` validation accessor as hidden
mutation solely because its Ruby name ends in `!`. That adds 125 alleged
mutation calls, increases False Simplicity from 67 to 69 categories, and pulls
seven additional methods into convergence. The changed-files Espalier report
correctly records that `text!`, `integer!`, and `float!` write no state.
Decomplex should consume effect facts or otherwise distinguish a raising
checked accessor from a mutating bang method before using the signal for
cross-detector convergence.

Validation: 103 focused parser/contract examples pass; all 480 top-level
`transpile-tests/*.clear` fixtures lex and parse; Ruby built-in coverage reports
zero uncovered executable lines in the new token/AST contract methods. The
canonical full compiler, MessagePack compatibility, SimpleCov, and Sorbet
gates remain unavailable because the locked bundle is absent.

### Stage 2A: named struct-literal fields

Generic and ordinary struct literals now share one parser for
`ParsedStructField` records. Field name, value, and diagnostic token remain
attached until the final value/token maps are built; the former anonymous
`[[name, value], token]` pair and duplicate grammar branches are gone.

| Measure | Stage 1 | Stage 2A | Delta |
| --- | ---: | ---: | ---: |
| Parser methods | 182 | 184 | +2 |
| Parser `T.must` sites | 94 | 90 | -4 |
| NilKill array shapes | 1,419 | 1,420 | +1 |
| NilKill hash-record blockers | 86 | 88 | +2 |
| NilKill struct declarations | 3 | 4 | +1 |
| Espalier known `O(2^N)` component | 95 | 97 | +2 |
| Decomplex candidates | 440 | 441 | +1 |
| Decomplex convergence units | 91 | 92 | +1 |
| Decomplex root-cause clusters | 39 | 36 | -3 |
| Decomplex weighted-inlined findings | 81 | 82 | +1 |

The source contract improved materially, but no current headline metric
represents “semantic tuple replaced by named record” or “duplicated grammar
branch unified.” NilKill counts the honest `Array[ParsedStructField]` as one
more array shape and the two genuine output maps as hash blockers. Espalier
propagates the pre-existing replay SCC to the two new helpers, increasing the
number of methods labelled with an exponential known component without any
new replay or branch multiplicity. Decomplex's inlined metric deliberately
keeps extracted helper cost visible, but consequently does not reflect this
improved local contract either. FactMine does at least expose the additional
typed struct declaration.

Validation: 104 focused examples pass; all 480 top-level CLEAR fixtures parse;
the new record-building helpers have zero uncovered executable lines.

### Stage 2B: named capability records

Capability sigil metadata, joined expression capabilities, and element
capabilities are now explicit `T::Struct` records. Parser code reads named
fields instead of indexing symbol-keyed hashes, and the mutable join state is
confined to `CapJoin` and `ElementCapability` accumulators. The shared sigil
tables remain genuine lookup maps.

| Measure | Stage 2A | Stage 2B | Delta |
| --- | ---: | ---: | ---: |
| Parser lines | 4,916 | 4,944 | +28 |
| Parser `T.must` sites | 90 | 83 | -7 |
| NilKill calls | 3,651 | 3,626 | -25 |
| NilKill hash shapes | 31 | 29 | -2 |
| NilKill array shapes | 1,420 | 1,407 | -13 |
| NilKill collection index lookups | 105 | 73 | -32 |
| NilKill hash-record blockers | 88 | 65 | -23 |
| NilKill struct declarations | 4 | 7 | +3 |
| Espalier complete/incomplete time results | 9 / 175 | 10 / 174 | +1 / -1 |
| Espalier known `O(2^N)` component | 97 | 97 | 0 |
| Espalier known `O(N)` stack component | 98 | 98 | 0 |
| Decomplex candidates | 441 | 439 | -2 |
| Decomplex convergence units | 92 | 93 | +1 |
| Decomplex state-based branch findings | 69 | 70 | +1 |
| Decomplex False Simplicity findings | 69 | 65 | -4 |

NilKill reflects this contract improvement well: semantic hash shapes,
indexing, and hash-record blockers all fall substantially while three named
struct declarations appear. Espalier appropriately leaves recursive
complexity unchanged and gains one complete local result.

Decomplex removes four False Simplicity findings and no longer reports
eliminable nil-guard pressure in the capability join and branch-prefix
methods. Its headline convergence and state-branch counts nevertheless rise
because it treats reads of `const` fields on immutable `SigilAttrs` values as
branches over mutable object state. That is a detector gap: FactMine exposes
the `T::Struct` and `const` declarations, so Decomplex should distinguish a
local immutable value record from receiver/parser lifecycle state. Property
setters on the two deliberately local accumulators are real writes, but they
should likewise not imply hidden non-local mutation without escape or receiver
state evidence.

Validation: 80 focused parser/contract examples pass; all 480 top-level CLEAR
fixtures parse; Ruby built-in coverage reports all 81 changed executable
parser lines covered.
