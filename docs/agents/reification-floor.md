# Reification-Misses: the irreducible floor

decomplex tier-1 `Reification Misses` ("an existing predicate reinvented
inline -- invariant #16"). Driven **83 -> 18** across byte-identical commits
(P4u25..P4u24c, branch `epic-66-decomplex-r2`). Earlier I wrongly called this
"dry" at 83; it was not. It is now at its genuine floor: the remaining 18 each
have **no predicate-bearing receiver at that point**, so reifying is an
API/architecture change, not a byte-identical predicate substitution.

## The 18 (each verified, not assumed)

| count | sites | why irreducible |
|--:|---|---|
| 9 | `promotion_plan.rb` 798/799/801/829/866 (classify_sync / classify_heap_provenance / classify_heap_struct_plain) | `sync` is a **method parameter** (`def self.classify_*(ti, ..., sync = nil)`), the resolved sync-axis Symbol deliberately decoupled from `ti`. No object whose `.locked?`/`.versioned?`/`.write_locked?` could be called. |
| 3 | `capabilities.rb` 1395/1405 (finalize_capability_audit!) | `sync = info[:sync]` where `info` is a **Hash** (`info[:line]`, `info[:ownership]`, `info[:mutated]`). A Hash field, not a Type/SymbolEntry. |
| 2 | `parser.rb` 2936 (parse_type_annotation) | parse-time locals (`sync`, `layout` built from tokens) **before any Type/SymbolEntry exists**. The predicates live on Type/SymbolEntry, which are constructed later. |
| 1 | `escape_analysis.rb` 821 (param_accepts_caller_sync?) | `sync` is a **Symbol parameter** (`sig { params(..., sync: Symbol) }`). |
| 1 | `with_match_check.rb` 303 (family_of_arg) | `sym` is **duck-typed**: the unit spec passes a raw `Object` with only `#sync`. `sym.local?` raised `NoMethodError` (caught by the spec gate, reverted). |
| 1 | `annotator.rb` 1238 (analyze_control_flow_branches) | `state == :moved` -- `state` is a dataflow **Symbol local**, not an object. |
| 1 | `mir_lowering.rb` 6846 | `sync` bare Symbol local. |

## Why these are tool false-positives, not unfinished work

decomplex matches the *syntactic pattern* `<expr> == :symbol` against a known
predicate's body. It is "AST-only, intra-procedural, no CFG / no points-to"
(its Run Summary), so it **cannot tell that `<expr>` is a passed Symbol param,
a Hash field, or a parse-time local** rather than a Type/SymbolEntry. Every
genuine object-receiver reinvention HAS been reified (atomic?/indirect?/
atomic_ptr?/locked?/local?/write_locked?/multiowned?/versioned?/pool?/
set_collection?/symbol?/void?/bc_target?/fixed?/rc_stored?/AST.call?/
AST.root_identifier across Type, SymbolEntry, CapabilityWrap, Param,
FunctionReturn). The residual 18 would each require an API change (thread the
object through instead of extracting/passing the Symbol) -- a behavior-risk
refactor, explicitly out of the byte-identical decomplexity contract, and the
exact class of finding a receiver-type-aware decomplex would suppress
(tracked: task #29).

**Honest status:** 83 -> 18 is the floor reachable byte-identically. Not zero;
each of the 18 is individually justified above. Re-running
`ruby gems/decomplex/exe/decomplex report src` will continue to show 18 until
either (a) the API refactors in the table are done deliberately, or (b)
decomplex gains receiver-type analysis (#29).
