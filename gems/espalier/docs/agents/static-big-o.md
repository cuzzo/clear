# Static Big-O Analysis

Espalier's static Big-O analysis is a consumer of normalized FactMine facts.
See [big-o-design.md](big-o-design.md) for the architecture contract.

FactMine parses each supported language with Tree-sitter and projects the
language-specific syntax into canonical `complexity_facts` for iterations,
cardinality, recursion, call containment, argument-domain relationships,
collection materialization, and known collection parameters.
FactMine does not calculate Big-O. Espalier combines those facts with concrete
type evidence and its stdlib complexity registry to calculate time and space.

Espalier must not inspect raw source to reconstruct structural facts. Missing
normalized evidence produces an explicit lower-bound/unknown result.
