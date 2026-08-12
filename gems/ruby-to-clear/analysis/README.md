# True Clean Transpilation Verifier

This directory implements the gate model in
`../docs/agents/true-clean-transpilation-audit.md`. It evaluates every
`compiler/ruby/**/*.rb` file from freshly generated CLEAR and never treats
checked-in generated CLEAR as evidence of success.

Run the complete raw and autofix-assisted audit from the repository root:

```bash
ruby gems/ruby-to-clear/analysis/bin/ruby-to-clear-verify --jobs 2 --autofix
```

Use `--only` while developing a specific translation:

```bash
ruby gems/ruby-to-clear/analysis/bin/ruby-to-clear-verify --only 'ast/parser\.rb$'
```

To recheck only roots that failed G3 in an earlier report while still
regenerating a dependency-consistent shadow tree for the entire corpus:

```bash
ruby gems/ruby-to-clear/analysis/bin/ruby-to-clear-verify \
  --g3-from-report gems/ruby-to-clear/analysis/results/latest.json \
  --jobs 32
```

This runs G0-G2 for the full corpus, runs G3 only for prior failures, and
skips G4. Unlike `--only`, generated dependencies are never inherited from
the checked-in tree.

For the normal edit loop, reuse a completed full-run report and name the
changed corpus source paths:

```bash
ruby gems/ruby-to-clear/analysis/bin/ruby-to-clear-verify \
  --changed compiler/ruby/mir/lowering/expressions.rb \
  --reuse-report gems/ruby-to-clear/analysis/results/latest.json \
  --jobs 32
```

`--changed` content-checks and reuses unchanged G0-G2 artifacts, then
retranspiles the changed source's `require_relative` reverse closure and
recompiles its generated `REQUIRE` reverse closure (including any cyclic
package group). The compiler still receives the complete generated dependency
tree. It is therefore a dependency-closed scoped check, not `--only` with
missing dependencies hidden. A change to the compiler frontend discards
inherited G3/G4 statuses; only roots selected by this invocation are current.
Add `--g3-only` for the quickest lowering-only feedback; otherwise changed
runs build only selected roots that newly pass G3. Changed mode defaults to a
90-second per-process cap; use `--timeout SECONDS` when investigating a known
slow closure. Full runs retain the manifest timeout.

The verifier writes machine-readable and human-readable summaries to
`analysis/results/latest.json` and `analysis/results/latest.md`. Complete
commands, stdout, stderr, raw generated CLEAR, emitted Zig, and autofixed
copies live under `tmp/ruby-to-clear-verify/<revision>-<manifest>/`.

The manifest also declares native Zig modules needed by generated `EXTERN`
declarations. The verifier copies those modules beside each shadow source for
the single-file G4 build, matching `clear test`'s module-discovery contract.

The headline definition is strict: a file is cleanly transpiled only when its
raw output passes G1 through G4. G5 behavioral compatibility remains
unmeasured unless a manifest unit defines a differential oracle. Autofix
success is reported separately and never increases the raw clean percentage.

Both reports include raw and post-autofix diagnostic inventories. The
inventory counts every diagnostic observed before a compiler process stops,
groups normalized messages into clusters, and reports affected roots
separately from emitted instances. When a generated source location identifies
a provider, it also separates direct provider failures from dependent roots
that merely amplify that failure. These are lower bounds because each compiler
invocation can fail before revealing later diagnostics.

`--only` is a development shortcut. It removes and regenerates only matching
roots, so their imported generated dependencies may still come from the
checked-in compiler tree. Headline corpus statistics must always be produced
without `--only`.

## Finding regressions without the CLEAR compiler

This verifier is fail-fast and serialized behind shared providers: one bad line
in a corpus-wide import such as `ast/type.clear` fails every dependent root and
hides their own diagnostics, so a cold run reveals only the next single
blocker. Recovering a known-better revision one blocker per cold run is too
slow to be a feedback loop.

`tools/rtoc_regression_scan.rb` answers the same question from generated CLEAR
alone. It extracts per-function binding facts -- whether a name was declared,
its declared type, and whether its initializer carried a materialization marker
(`COPY`/`KEEP`/`GIVE`/`OWN`/`TRY`/`UNWRAP`/`CAST`) -- and reports only facts the
golden revision had and the current output lost. Equality would be the wrong
oracle because output shape legitimately changes; a dropped fact never is.

```bash
# Freeze an oracle from a known-good run's raw tree (already checked in as
# tools/rtoc_golden_facts.json.gz).
ruby tools/rtoc_regression_scan.rb \
  --golden tmp/ruby-to-clear-verify/<rev>-<manifest>/raw/compiler/src \
  --emit-facts tools/rtoc_golden_facts.json.gz

# Whole corpus, regenerated with the current gem (~5 min on 32 cores).
ruby tools/rtoc_regression_scan.rb --facts tools/rtoc_golden_facts.json.gz \
  --regen gems/ruby-to-clear/analysis/results/latest.json --new tmp/rtoc-scan --jobs 32

# One provider, for the edit loop (seconds).
ruby tools/rtoc_regression_scan.rb --facts tools/rtoc_golden_facts.json.gz \
  --regen gems/ruby-to-clear/analysis/results/latest.json --only 'ast/type\.clear'
```

`--regen` replays each unit's recorded `transpile` argv, so `--strict`,
`--helper-config`, and `--cfg-facts` match what this verifier passes. Calling
the library in-process instead drops those inputs and reports differences the
verifier never sees.

Always regenerate into your own `--new` directory. Reading a
`tmp/ruby-to-clear-verify/<rev>/raw` tree while a verify run is writing it
compares against half-regenerated output and produces meaningless counts.
