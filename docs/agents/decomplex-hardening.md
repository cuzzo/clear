# decomplex hardening: suppress the receiver/CFG false-positive floor

Scoping note for task #29. decomplex is "AST-only, intra-procedural, no CFG /
no points-to" (its Run Summary). That omission produces a measurable, named
false-positive floor we hit empirically this epic. **It is NOT undecidable for
these specific classes** -- Rice's theorem bars *exact* "is this a real bug",
but each pattern below is a syntactic/dataflow shape that a bounded analysis
suppresses. Evidence and the precise fix per detector:

## 1. Reification-Misses (`predicate_alias.rb` + `miner.rb`) -- receiver-type FP

**Evidence:** the irreducible floor of 18 (docs/agents/reification-floor.md). decomplex
flags `<expr> == :sym` whenever `:sym` matches a known predicate's body,
*regardless of what `<expr>` is*. All 18 residual `<expr>` are NOT the
predicate's class: a passed Symbol param (cleanup_classifier ×9, escape_analysis),
a Hash field `info[:sync]` (capabilities ×3), parse-time locals before the
type exists (parser ×2), a duck-typed `Object` (with_match_check), a dataflow
Symbol (annotator).

**Fix (no CFG needed -- pure AST/heuristic):** before emitting a
Reification-Miss for `recv == :sym`, require `recv` to be plausibly the
predicate's receiver type:
- skip when `recv` is a bare local/param whose nearest binding is a method
  parameter or a `Hash#[]` / `[:key]` access (no object).
- skip when `recv` is a parse-stage local (file is the parser and no
  Type/SymbolEntry construction dominates).
- only emit when `recv` is `self`/`@ivar` of the predicate's class, or a
  local whose assignment RHS is a constructor/accessor of that class.
This alone removes the entire current 18 floor.

## 2. Derived-State-Staleness (`derived_state.rb`) -- 3 named CF/identity FPs

**Evidence:** docs/agents/state-drift-audit.md S4 (sampled, patterns real; coverage
unquantified). The `b = f(a); a reassigned; b not recomputed` heuristic
misfires on:

| FP class | fix | needs |
|---|---|---|
| `x = if/case…end` -- every var inside the conditional treated as a "derived-from" of x | treat a conditional-expression RHS as a single opaque def of x; don't emit derived-from edges into its arms | pure AST |
| def in arm A, "reassign" in arm B (mutually exclusive) | a basic-block CFG: only pair def/reassign that share a path | CFG (basic blocks + reachability) |
| `v = o.getter; … v2 = o.getter` (same pure read) | value-number pure, argument-free reader calls; equal calls are not a "reassignment" | def-use + purity heuristic (annotate known pure getters) |
| `expected = …` as distinct independent bindings in a huge visitor | scope/SSA: distinct defs in disjoint regions are distinct variables | def-use / SSA |

The first is pure-AST and cheap; the rest need a per-method basic-block CFG +
def-use (SSA-lite). decomplex already builds the method AST in
`site_extractor.rb`; a linear-scan basic-block builder + reaching-defs is a
bounded addition (no points-to, no interprocedural).

## Recommendation / priority
1. **Reification receiver guard** (pure AST, kills the 18 floor, low effort) --
   highest value/effort; do first. After it, Reification-Misses ~0 is
   *measured*, not asserted.
2. **DSS `x=if/case` guard** (pure AST) -- removes the dominant DSS FP class.
3. **DSS basic-block CFG + reaching-defs** -- removes the branch-disjoint /
   independent-binding classes; this is what makes the tier-2 count
   *trustworthy* and finally answers "are the residual DSS real?" (currently
   unknown -- see state-drift-audit S4).

Not in scope of the byte-identical compiler epic: this is gem work in
`gems/decomplex/lib/decomplex/{predicate_alias,miner,derived_state,
site_extractor}.rb`, with its own self-tests. Tracked as #29; left as a scoped
proposal (the epic's contract is the compiler, not the tool).
