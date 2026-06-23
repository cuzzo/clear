# Nil-Kill Architecture

**TODO: Discovery Needed**
- Investigate the broken state of `nil-kill` after its static analysis fact-mining was haphazardly migrated to `espalier`.
- Document how to restore `source_index` functionality and exactly what facts it needs.
- Document how `nil-kill` aggregates and reports its findings.

## Core Rules
1. **Facts Source**: Must get ALL facts from Fact-Mine (Rust implementation).
2. **Zero Parsing**: Must do ZERO parsing of un-normalized AST data.
3. **Zero Legacy**: Zero requirements on Ruby Fact-Mine and Decomplex logic.
