# General Source-Fact Fixtures

These fixtures target FactMine's shared normalized syntax extraction, stateful
syntax enrichment, and local-flow passes.

They are intentionally organized as `general/<scenario>/<language>.<ext>`:

- `general/<scenario>/ruby.rb` is the current seed implementation for a
  scenario that should be reusable across dynamic and static languages.
- This directory does not require one file per language. Add another language
  file only when that language adapter should prove it normalizes equivalent
  syntax into the same shared facts.
- The oracle shape lives in `oracles/general/<scenario>/<language>.json` and
  should describe shared facts, not language-specific parser behavior.
- Language-specific parser quirks belong under `source-facts/<language>/` or
  `syntax-facts/<language>/`, not here.

The goal is to ensure language adapters feed the common fact-mining machinery;
these fixtures should not become a second per-language compiler test suite.
