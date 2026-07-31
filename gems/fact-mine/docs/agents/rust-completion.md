# Rust Big-O completion

Rust reports far fewer complete bounds than Go or Java. Go and Java spell types
at the binding site, so declaration-based resolution works; Rust infers them, and
every gap in consuming what the compiler already knows surfaces as an unpriced
operator or an open parameter.

Measured on `gems/decomplex` + `gems/fact-mine` (8950 functions, both SCIP
indexes attached): 54.6% complete, 12.9% parametric, 32.5% incomplete.

## How to measure

Never measure Rust on `gems/fact-mine` alone while editing it: it is its own
corpus, so edits shift line numbers and every lambda identity with them. Two
measurements taken across an edit are not comparable. `gems/decomplex` is stable
unless you edit it.

```
rust-analyzer scip . --output <crate>.scip      # per crate
ruby -Ilib measure.rb <decomplex.scip> <fact-mine.scip>
```

Group incomplete functions by *which call* produced each blocking symbol, then
sample the real source lines. Every defect found so far came from that tally.
The tally ranks reliably; it does **not** predict yield, because a function
usually carries several blockers and clearing one class rarely flips it. Recent
estimates of 75, 421 and 616 functions delivered 0, 8 and 100.

Also measure blockers *per function*: of 2907 incomplete, 1390 have no unpriced
call of their own (purely transitive - they resolve as their callees resolve)
and ~1000 have exactly one.

The heading below overstates its case. Measured since: attaching the whole Rust
stdlib index is worth +1.1 points on `gems/decomplex`, and indexing the sibling
crate it calls most is worth +2.4. Both are real; neither is dominant, and the
category they were meant to clear does not move, because what a dependency index
supplies is declarations and what that category is missing is costs. See
[`inference-language-completion.md`](inference-language-completion.md) for the
cross-language measurement and the ranked plan.

## A contributing cause: dependency declarations are absent

An index carries `SymbolInformation` only for the crate it indexes. Dependencies
appear as bare symbol names on references, with no declaration attached, so the
type of anything they return or hold is unavailable:

    node.kind() == "block"        // kind() -> &str, unknown: O(N) unpriced
    start.row + 1                 // Point#row -> usize, unknown: O(1) unpriced

Verified: fact-mine's index holds 2717 tree-sitter symbols and zero signatures
for them (`grep 'fn kind'` finds nothing). Project code has no such problem - a
probe comparing two project call results resolves complete today - so this is a
missing input, not a resolution defect.

This is why Rust trails Go here rather than anything about inference: the Go
corpora call their own code plus a stdlib the registry models, while fact-mine
is tree-sitter and serde heavy.

Indexing the dependency itself supplies exactly what is missing:

    cd ~/.cargo/registry/src/*/tree-sitter-0.25.8 && rust-analyzer scip .
    # pub fn kind(&self) -> &'static str
    # pub row: usize

Attaching that index measured fact-mine incomplete 2548 -> 2523. That is one
dependency; `core` and `alloc` carry ~67000 symbols by comparison.

`apply_json` refuses it: an index joining to none of the analyzed methods is
rejected, which is right for a mis-scoped `scip-go .` and wrong for a dependency
that is foreign by construction. The guard cannot tell the two apart, and a test
pins the current behaviour deliberately. Intent has to come from the caller - a
`--scip-dependency-index` flag that skips the coverage check and contributes
declarations only. Note the flag is parsed in one subcommand block while the
preload runs in another; the two scopes need joining.

## Open work

### 1. Cross-file record shapes are order-dependent

A record is declared in one file and read in every other. `record_project_fields`
(`syntax.rs`) records shapes at `parse_file`, and `fact_for_method` merges them
into `field_types`. Correct, but racy: `incremental.rs` parses and builds facts
per candidate in one `parallel::map_ordered`, so a read only resolves when the
declaring file happens to be parsed first. A cached candidate never parses at
all, so its shapes never register.

This still gates `node.r#type == "CALL"` and similar, the largest remaining `==`
class. SCIP cannot substitute: it carries no signature for these fields (verified
- zero `Node#type` entries in the index).

The fix is two passes over candidates:

1. shapes only - cache hit: load the shard and take `shard.fields`, which already
   carries them; miss: parse and record.
2. `extract_local` per candidate as today.

The open question is document retention. Keeping every parsed document alive
between passes costs memory; re-parsing on miss costs a second parse per file on
a cold cache. Measure the cold-cache parse cost before committing to either -
this tool's analysis speed matters, and the regression may outweigh the gain.

### 2. Purely transitive incompletes

1390 of 2907. No fix of their own; they resolve as the leaves above resolve.
Re-measure this bucket after any leaf fix rather than attacking it directly.

### 3. Function-reference callbacks

~60 parametric functions from `value.and_then(Value::as_array)`,
`loc.split(':').map(ToOwned::to_owned)`. `named_callback_argument`
(`aggregator.rb`) resolves a callback only when the callee is a *project* method
with declared `callback_params`, then looks the argument up among project
functions. These have external callees and external callbacks, so it returns nil
immediately, and espalier cannot reach fact-mine's external cost registry. Needs
work across both gems.

## Shape of the defects already fixed

Each was a knowable cost or type left unresolved, not a missing capability:

- calls whose cost does not depend on the implementation (`to_string`,
  `AsRef::as_ref`, `Path::new`, `into_iter`) listed as reflective
- a blanket trait symbol outranking a receiver the registry could price
  (`.clone()`)
- a member read not resolved to the type its record declares
- a callback parameter surviving in a summary's rendered string, and again in
  its space bound - a bound is complete only when both close
- a field named after a keyword dropped entirely, so nothing reading it typed
- local symbols merged across documents, where an index names them per document
- an unclosed bound compared against a registry contract, aborting workspace
  analysis outright
- negation requiring its operand's type, when whatever produced that value is a
  call priced where it happens
