# CLEAR Gems

The projects in this directory are not merely RubyGems. They are
analysis, quality, and developer-tooling subprojects built for the CLEAR
compiler and runtime.

Some are packaged as Ruby gems because Ruby is the genesis compiler
implementation language and gives us a convenient CLI/library boundary.
Others may contain Rust, Zig, TypeScript, or language-neutral tooling.
The shared purpose is not "publish Ruby libraries"; it is to make CLEAR
quality work scalable.

## Projects

- `decomplex`: static complexity and duplicated-decision analysis.
- `boobytrap`: risk ranking from coverage, branch gaps, churn, and structural evidence.
- `slopcop`: sloppiness and guardrail reporting.
- `nil-kill`: nil/type-pressure evidence.
- `auto-type`: automated type and nilability rewrites driven by analyzer evidence.
- `espalier`: architecture and public-surface analysis.
- `lineage`: source/test/quality lineage UI and ingestion tooling.
- `zig-mutants`: mutation testing for Zig runtime/lib code.
- `sql-cov`: dynamic and schema-aware SQL branch coverage and logic hazard analysis.

## Contribution Rules

Use the repository-level [../CONTRIBUTING.md](../CONTRIBUTING.md) first.
Then check the local `README.md` and `CONTRIBUTING.md` in the gem you
are changing.

General expectations:

- analyzer output should be stable and documented;
- new metrics need focused positive and negative tests;
- parser/provider code should be language-aware, not Ruby-shaped by
  accident;
- report-only analyzers should not silently grow autofix behavior;
- docs should state whether multi-language support is mature,
  experimental, or planned.
