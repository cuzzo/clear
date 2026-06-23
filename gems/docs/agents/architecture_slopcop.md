# SlopCop Architecture

**TODO: Discovery Needed**
- Document the exact facts consumed from `Fact-Mine` (`syntax-facts` / `branch_arms`).
- Document how SlopCop aggregates and classifies coverage gaps.
- Document SARIF reporting structure migrated from Decomplex.

## Core Rules
1. **Facts Source**: Must get ALL facts from Fact-Mine (Rust implementation).
2. **Zero Parsing**: Must do ZERO parsing of un-normalized AST data.
3. **Zero Legacy**: Zero requirements on Ruby Fact-Mine and Decomplex logic.
