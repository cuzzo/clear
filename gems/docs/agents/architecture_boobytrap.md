# Boobytrap Architecture

**TODO: Discovery Needed**
- Document the exact facts consumed from `Fact-Mine` (`decomplex-rust facts` for structural deviance).
- Document how Boobytrap calculates churn and combines it with structural deviance.

## Core Rules
1. **Facts Source**: Must get ALL facts from Fact-Mine (Rust implementation).
2. **Zero Parsing**: Must do ZERO parsing of un-normalized AST data.
3. **Zero Legacy**: Zero requirements on Ruby Fact-Mine and Decomplex logic.
