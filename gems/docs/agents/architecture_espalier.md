# Espalier Architecture

**TODO: Discovery Needed**
- Document the exact facts consumed from `Fact-Mine`.
- Document how Espalier aggregates and analyzes these facts.
- Outline the skipped tests due to partial Fact-Mine Rust migration and how they map to the architecture.

## Core Rules
1. **Facts Source**: Must get ALL facts from Fact-Mine (Rust implementation).
2. **Zero Parsing**: Must do ZERO parsing of un-normalized AST data.
3. **Zero Legacy**: Zero requirements on Ruby Fact-Mine and Decomplex logic.
