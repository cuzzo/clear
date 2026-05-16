# deslop-bugs

Findings from the nil-kill / SlopCop complexity-reduction pass
(tracker items #45-#64). Records CLEAR transpiler bugs encountered and
methodological findings.

## CLEAR transpiler bugs encountered

None. Every change made (and every change considered) was validated
against `bundle exec prspec spec/`, `./clear test transpile-tests/`
(548/548, 0 leaks), and the stable fuzz matrix (141/141, 0 fail / 0
leak / 0 mir-error). No transpiler miscompilation, leak, or
MIR-checker regression was observed.

## Pre-existing flaky spec (not introduced here)

`spec/fmt_verifier_spec.rb` fails exactly one (nondeterministic)
example under parallel `prspec` but passes 12/12 when run serially
(`bundle exec rspec spec/fmt_verifier_spec.rb`). Pre-exists on the
`origin/nil-kill-prod` base. Out of scope for this pass; flagged so it
is not mistaken for a regression. The per-item gate used here is
"prspec failures confined to that one flaky fmt example; serial run of
related specs green; transpile-tests + fuzz unchanged."

## Methodological finding: only "always Type" verdicts are safe blind collapses

nil-kill's Union Decomplexity list ranks contracts by how many
`is_a?(Type)` guards collapse if the contract is given a concrete
type. Two distinct verdict classes appear, and only one is a safe
*standalone* deslop commit:

1. **"always `Type`: collapse, all N die"** (runtime evidence: the
   producer is non-nilable `Type`). The guards are provably dead;
   deleting them is behavior-preserving. SAFE standalone commit.
   - #56 `Type#accepts_fn_type?` (`other_type`) -- done, commit
     916cd5caf.
   - #55 `MIRLowering#build_drop_entry!` (`ti`) -- done, commit
     d4507ea99.

2. **Nilable / union producers** (`{NilClass, Type}`,
   `T.nilable(Type)`, heterogeneous) **or "producers unattributed"**
   (no runtime trace). The `is_a?(Type)` check is a *correct
   nil/Type discriminator* or a *load-bearing coercion*, NOT a dead
   guard. Verified by static inspection -- these sites source from the
   nilable `.type_info` / `.full_type` contract, e.g.:
   - `ti = node.type_info rescue nil; ti.provenance = :heap if
     ti.is_a?(Type)` (EscapeAnalysis#per_fn_scan!, #52)
   - `ti = source.type_info rescue nil; ti = Type.new(ti) if ti &&
     !ti.is_a?(Type)` (BorrowChecker#_collect_share_moves, #58)
   - `inner_ti = Type.new(inner_ti) unless inner_ti.is_a?(Type)`
     (CleanupClassifier, #54 -- the guard IS the coercion)

   Deleting these guards introduces NoMethodError-on-nil at compile
   time. They are NOT standalone deslop commits.

### Why #45-#54, #57-#64 are deferred (not done)

These reduce to a single root: the `.type_info` / `.full_type` /
`.type` / `.return_type` / `:type` contracts are legitimately
`T.nilable` (a node has no `type_info` before Pass 1 annotation). The
guards are correct. The genuine complexity reduction is to **tighten
the producer** so the contract is non-nilable at every post-annotation
read site -- nil-kill's PropagationGap program. That is a multi-commit
*typing program per contract* (make every producer assign a `Type`,
prove no pre-annotation read, then the guards become provably dead and
collapse mechanically), not 18 quick guard deletions. Forcing the
deletions to "complete 20 items" would be metric-gaming that ships
compiler bugs -- precisely the anti-pattern in
`docs/retrospective`.

Recommended next step for these: run them as the dedicated
contract-tightening program (one contract at a time: `.type_info`
first, 59 guards), each contract its own series of producer-side
commits ending in the mechanical guard collapse, full gates between.

## Source-fix attempt: producers passing bare Symbols to full_type=

The correct strategy (per the user) is to fix the *source*: 120
sites across 5 files do `node.full_type = :Sym`, which `full_type=`
(ast.rb:309) silently launders via `Type.new(val)`. Passing `Type`
at the producer is runtime-identical *iff* the receiver's
`full_type=` is the laundering `AST::Locatable` setter.

- **SAFE / landed**: `src/backends/pipeline_rewriter.rb` (62 sites).
  Receivers are uniformly freshly-built `AST::Locatable` nodes ->
  `.full_type = :Sym` -> `.full_type = Type.new(:Sym)` is provably
  identical. All gates green. Commit f29524a10.
- **UNSAFE / reverted**: `annotator.rb` (35), `pipe_analysis.rb`
  (14), `test_annotation.rb` (8), `function_analysis.rb` (1). A
  blanket `:Sym -> Type.new(:Sym)` here regressed 1799 specs +
  collapsed transpile-tests. Root cause: `.full_type` in these files
  has **heterogeneous receivers** and many readers compare the value
  with `== :Sym` / `case ... when :Sym`. (Note `full_type=` already
  normalized symbols, so symbol-equality readers were *already*
  reading a `Type` for Locatable nodes -- meaning the breaking sites
  are receivers whose `full_type`/`full_type=` is NOT the laundering
  setter: a plain accessor / Struct / Hash-shape that genuinely
  stores and reads the raw Symbol.)

Conclusion: the source fix is correct in principle but cannot be a
blanket caller rewrite. It requires per-receiver typing: identify
which `full_type` carriers are `AST::Locatable` (laundering setter,
safe to convert) vs other carriers (raw-Symbol contract, must
instead be typed at *their* definition or left). That per-receiver
discrimination is the actual program -- the mechanical transform is
not a substitute for it.

## Outcome of the 20-item pass

**Done (11 items), all gate-verified standalone commits** (specs:
pre-existing flaky fmt only; transpile 548/548 0 leaks; fuzz 141/141
0 fail/leak/mir-error):

- #45 `.type_info` -- 22 producers -> Type at the Locatable seam +
  `visit_Slice` returns(Symbol)->.void slop fix + 14 reader guards
  collapsed. (3b90fd4b6, aba4b1f26, c79bf07d6, 6544881b4)
- #46 `.full_type` -- same @type_object seam; 14 reader guards
  collapsed. (b8e60bab8)
- #52(partial),#58,#60,#61,#62,#63 -- `.type_info`-sourced
  single-method locals; dead coercions removed, guards -> nil-safe.
  (e658b0622)
- #54 `.wrapped_type` -- structurally nil|Type; 2 dead coercions
  removed. (c5749215e)
- #55,#56 -- nil-kill "always Type" param collapses. (d4507ea99,
  916cd5caf)

The unifying safe pattern: a contract whose **producer is
structurally `nil|Type`** (the `Locatable#full_type=` laundering
seam, or `wrapped_type`'s own ctor) -- there the `is_a?(Type)` is a
redundant nil-check and collapses behavior-preservingly.

**MAJOR BLOCKER -- remaining 9 (#47,#48,#49,#50,#51,#53,#57,#59,#64).**
These contracts are *genuinely heterogeneous*; `is_a?(Type)` is a
real, load-bearing discriminator, NOT a redundant nil-check:

- `.type` (#47): producers `{Type, Symbol, NilClass,
  T.nilable(Type), FunctionSignature, String}`. `node.type.is_a?(Type)
  ? node.type : Type.new(node.type)` legitimately coerces a Symbol;
  `FunctionSignature`/`String` are NOT `Type.new`-able. Collapsing
  changes behavior / crashes.
- `.return_type` (#48): `{T.nilable(Type), Type, Symbol, Hash, Proc}`
  -- `Hash`/`Proc` are not Types.
- `final_type` (#50): `Symbol|Type` *by design* -- finalize_storage!
  normalizes a raw type spec; the discriminator is the whole point.
- `:type`/`:resolved_type` hash-keys (#49,#53), match-binding
  (#51): heterogeneous hash values.
- `expected_type` (#57), `source_type` (#59): genuinely nilable /
  no runtime evidence of always-Type.

Collapsing any of these is **not behavior-preserving**. Each needs
its own deep per-contract retype program (find the `@ivar=` / hash
writer, give it a real `Type`, handle the non-Type members like
`FunctionSignature`/`Proc`/`Hash` explicitly) -- a #45-scale-or-larger
*semantic* change per contract, with real miscompilation risk. That
is the major blocker: forcing these collapses to "finish 20" would
ship compiler bugs (the exact anti-pattern in docs/retrospective).
They are left as pending, scoped, with this rationale, rather than
faked. No CLEAR transpiler bugs were introduced anywhere in the pass.
