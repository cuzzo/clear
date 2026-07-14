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
