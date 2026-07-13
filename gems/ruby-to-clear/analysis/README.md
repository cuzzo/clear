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

`--only` is a development shortcut. It removes and regenerates only matching
roots, so their imported generated dependencies may still come from the
checked-in compiler tree. Headline corpus statistics must always be produced
without `--only`.
