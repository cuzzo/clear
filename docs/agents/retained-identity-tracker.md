# Retained Identity v4 - Historical Implementation Tracker

> **Superseded:** `retained-identity-design.md` is now v5. The statuses below
> record what was implemented and tested for v4's all-Rc kept-parameter model;
> they are not acceptance evidence for v5's carrier-polymorphic
> `COPY_OR_KEEP`/`UNIQUE` design. Further implementation must begin with a
> migration audit identifying which v4 facts, lifecycle work, and tests remain
> valid without normalizing plain values to Rc handles.

Historical design: this tracker implemented the former v4 declaration-sited
cost model. Update it only to record migration or removal of that work; new v5
work must cite `docs/agents/retained-identity-design.md` and receive a new
tracker section after the migration audit.

Legend: `todo` | `in-progress` | `done` | `blocked(<reason>)`

## Phase A - lexer-oracle critical path

| ID | Item | Design section | Status |
| --- | --- | --- | --- |
| A1 | Keep-analysis: `kept_identity` param fact, single writer, destination-driven transitive fixpoint | Implementation plan A1 | done |
| A2 | Handle ABI: `Rc(T)` / `?Rc(T)` slots for kept params; payload deref on reads; NIL -> null | Implementation plan A2 | done |
| A3 | Edge derivation in MIRLowering: (source model x destination model) -> RcRetain / handle move / move+rcCreate / dupeValue+rcCreate / null | Implementation plan A3 | done (retain, GIVE move, born-as-Rc, zero-config NIL; @value is B1) |
| A4 | Declaration-sited diagnostic: MUTABLE-unique kept+used-after, anchored at declaration with model menu | Implementation plan A4 | done (KEPT_IDENTITY_NEEDS_MODEL) |
| A5 | Checker: RcRetain/RcCreate balance under existing LEAK/ORPHAN framing; no new heuristics | Implementation plan A5 | done (existing invariants caught every lowering bug during A3; no new checker rules added) |
| A6 | Born-as-Rc promotion: escape-analysis reason `:kept_identity`, immutable bindings, at declaration | Implementation plan A6 | done (E3d apply_kept_identity_placement!) |
| A7 | GIVE demoted to checked assertion, COPY to forced-copy override at keep edges | Implementation plan A7 | in-progress (GIVE deferred validation done; COPY override PENDING and now the blocker: the committed pre-native lexer.clear spells `COPY budget OR_ELSE fresh` at its keep edge and fails G4 until COPY-override lowering lands or the lexer is regenerated in the native shape) |

## Phase A test expansion (lands BEFORE the code it proves)

| ID | Item | Design section | Status |
| --- | --- | --- | --- |
| T1 | Fuzz template `kept_identity_matrix.rb`: full cross-product (caller model x destination x post-call use x arity x error paths), every cell registered, no quarantine; README ledger updated | Test expansion 1 | done (82 cells, high-risk profile, kept_identity_mutable_model mutant killed delta 12) |
| T2 | Semantic fuzz family `kept_identity` + mutation gate kills in edge-derivation/keep-analysis code | Test expansion 2 | todo |
| T3 | transpile-tests: 62x_kept_identity_{shared,value,last_use,default,two_params,error_path}.clear | Test expansion 3 | done except @value (B1): 619-625 shared/transitive/last-use/born-as-Rc/two-params/error-path/optional-default |
| T4 | Specs: annotator inference, declaration-anchored diagnostics, MIR retain/elision/balance, COST assertions on emitted Zig (no rcRetain in elision case, one body for two kept params, no dupeValue under shared model), CLI integration | Test expansion 4 | done (compiler/spec/kept_identity_spec.rb: 13 examples incl. 5 cost proofs); CLI :integration case pending |
| T5 | zig/rc-keep-edge-test.zig: retain/release balance, pointer identity, failure injection, counting-allocator memory assertions | Test expansion 5 | done (4 tests, registered in zig/build.zig, full zig suite green) |
| T6 | Keep-edge benchmark pinning the cost table; profile shows no memcpy/dupeValue hotspot under shared model | Test expansion 5 | todo |

## Phase B - menu completion and library rules

| ID | Item | Design section | Status |
| --- | --- | --- | --- |
| B1 | `@value` model: declaration sigil, deep-copy at keep edges | Phase B B1 | todo |
| B2 | Fortress/EXTERN assertions: `EFFECTS RETAINS p` checked both directions; `REQUIRES p: SHARED` family constraint | Phase B B2 | todo |
| B3 | Translator: value-vs-identity metadata stops forcing `@multiowned` returns; bare owned returns + binding-site wrappers | Phase B B3 | todo |
| B4 | `@cow` reserved: parse + reject "not yet implemented" | Phase B B4 | todo |

## Phase C - deferred

| ID | Item | Design section | Status |
| --- | --- | --- | --- |
| C1 | `@shared` (Arc, atomic) family member + comptime shape instantiation; Loom + Hammer obligations | Phase C C1 | todo |

## Acceptance gates

| ID | Gate | Status |
| --- | --- | --- |
| G1 | Full fuzz matrix green, no quarantine; semantic family kills its mutants | GREEN: full matrix 3744 cells 0 failures; kept_identity_matrix 105 cells, all 17 rejection cells now REQUIRE their diagnostic code (diagnostic_code_required) |
| G2 | Lexer behavioral oracle passes with shared-budget corpus incl. interpolation nesting; generated lexer G1-G4 clean with no translator changes for the keep path | GREEN: smoke 13/13 mismatches 0 AND full corpus 79/79 batches mismatches 0 with the regenerated native-shape lexer |
| G3 | Cost specs prove: no monomorphization, no runtime dispatch, elision works, allocation counts match the table | GREEN: kept_identity_spec cost proofs (1 retain shared model, 0 retains two-param last-use, born-as-Rc rcCreate at decl) |
| G4 | `bundle exec prspec spec/`, `./clear test transpile-tests/`, full fuzz matrix, zig unit suite all green | GREEN: prspec 7248/0, transpile 618/618 0 leaks, fuzz matrix 0 failures, sorbet clean |

## Review response (2026-07-22)

| Issue | Status |
| --- | --- |
| Pre-call leak (fallible sibling arg) | fixed: guarded errdefer through argument evaluation; MIR.kept_edge_transfer_boundary disarms it before the invocation (golden 626, matrix fallible cells) |
| Identifier-only edges | fixed: anonymous constructors / call results move payload + rcCreate, rc projections retain, COPY deep-copies payload, NIL passes null (golden 627, matrix expression cells) |
| Boolean fact | fixed: KeptIdentityContract (family + sink) on SymbolEntry; CallEdgeOwnershipPlan per edge, stamped by placement, consumed by MIR |
| No automatic last-use move | fixed: conservative syntactic liveness (no later occurrence, not in a loop) moves the handle; GIVE is an assertion; plain MUTABLE errors only when kept AND used afterward; cost specs pin the elision |
| Born-as-Rc restamps types | partially addressed: edge decisions moved into the plan; born-as-Rc itself still promotes by mutating entry/decl/use-site types inside the single placement writer. Full BindingRepresentationPlan (no semantic-type mutation, no AST re-walk) remains open. |
| Untyped analysis | improved: typed BodySummaries in keep-analysis, typed contract/plan/liveness structs, KeptEdgeCallFrame; residual T.unsafe/respond_to? remain where AST node unions lack a shared interface |
| Public/separate-compilation contract | partially addressed: keep-relevant body shape (param identifiers in struct-literal fields and call args) now feeds interface_fingerprint, so body-only retention changes invalidate callers via the reconciler's full fallback. Cross-package .clearc interface serialization remains open (no such interface file exists yet for any fact). |
| Matrix dimensions | expanded to 99 cells: expression edges, COPY forks, loop retains, fallible siblings, last-use move buckets, reserved @shared/@value rejections. Still missing: containers of identities (elem_ownership keeps unimplemented), mutation-through-both-observers cells, @value/@shared positive families (B1/C1). |

## Review response round 2 (2026-07-22)

| Issue | Status |
| --- | --- |
| Function-value ABI hole | fails closed: KEPT_FN_VALUE_ABI rejects any use of a retaining function as a function value (spec + matrix cell + repro). Retention in canonical FunctionSignature / FN types, interface serialization, and compatible callback types remain the real fix (open, phase B2 adjacent). |
| Fail-open ownership typing | fixed: kept_edge_arg_type raises on untypeable expressions; unresolvable kept-edge identifiers raise instead of guessing |
| Plan authority | fixed: a kept callee param without a CallEdgeOwnershipPlan raises in MIR; the callable-contract kept detection reads only the plan map (param-symbol fallback removed; method-call indexes receiver-shifted) |
| Born-as-Rc type mutation | still open: promotion mutates entry/decl/use-site types inside the single placement writer; BindingRepresentationPlan separation not started |
| source_catalog shape duplication | still open: parse-time retention-shape fingerprint is a conservative proxy, not shared semantics, and does not cover cross-package interfaces |
| Missing cases (containers of identities, field assignment after construction, aliases, methods, callbacks-positive, generic payloads, COPY optional OR_ELSE default) | open; matrix now at 100 cells including the fn-value rejection |
| PR 160 CI | branch-wide self-host gates (full fuzz, transpile coverage, buildable corpus, benchmarks, coverage) not run locally this round; local gates green (7,239 specs, 616 transpile zero leaks, 100-cell kept matrix, Sorbet) |

## Review response round 3 (2026-07-22)

| Issue | Status |
| --- | --- |
| Generic double-Rc | root-caused as a PRE-EXISTING generic-capability bug (reproduced at the pre-retain commit; not caused by retain). No combination of `T @multiowned` fields ever compiled. Now fails closed at the STRUCT declaration (GENERIC_IDENTITY_FIELD_UNSUPPORTED) with spec + matrix cell; capability wrapping made idempotent at Zig-type emission as hardening. Real generic keep-analysis remains open. |
| Lexer OR_ELSE acceptance | still blocked: the generated lexer assigns `wrapped OR_ELSE fresh` into an @multiowned FIELD (post-construction assignment), which keep-analysis does not cover. Field-assignment keeps are the next implementation unit; the G2 gate stays red until then. |
| Canonical function-type retention / interface serialization / representation plan / incremental authoritative contract | open, unchanged from round 2; KEPT_FN_VALUE_ABI remains the fail-closed stopgap. |
| Exhaustiveness policy (user directive) | the matrix now enforces: every capability x model x destination combination is either a passing cell or a REGISTERED rejection cell with its diagnostic code - nothing may fail open as invalid Zig. 101 cells: 85 positive, 16 negative (KEPT_IDENTITY_NEEDS_MODEL, USE_OF_MOVED_VALUE, KEPT_FN_VALUE_ABI, GENERIC_IDENTITY_FIELD_UNSUPPORTED, reserved @shared/@value). Unimplemented dimensions (field assignment, containers of identities, aliases, methods) must join as cells - passing or rejecting - before the feature is called ready. |

## Production-readiness loop (started 2026-07-22, runs until done)

Work order; each unit lands with tests, full local batteries, commit, push:

1. Field-assignment keeps: `x.field = provided OR_ELSE fresh` into an
   @multiowned field (the REAL lexer shape). Failing repro parked at
   docs/agents/retained-identity-wip/628_kept_identity_field_assign.clear.pending
   (restore to transpile-tests/628_... as the first step). Known symptoms:
   payload-into-handle mismatch + undeclared `rt` in the hoisted default.
   Then run tools/lexer_compat.rb; G2 stays blocked until green.
2. Remaining matrix dimensions as cells (pass or registered rejection):
   field_assign dest, containers of identities, aliases, methods,
   COPY-of-optional-default. Update README ledger + profile each time.
3. Retention in canonical FunctionSignature/FN types: contract on the
   signature, compatible function values (replace KEPT_FN_VALUE_ABI
   rejection with typed acceptance where sound), package interfaces.
4. BindingRepresentationPlan: separate semantic Type from binding
   representation; placement stops mutating entry/decl/use-site types.
5. Incremental invalidation consumes the serialized authoritative
   contract (replace SourceCatalog#retention_shape_source proxy).
6. Acceptance: full lexer behavioral oracle, full fuzz matrix
   (tools/fuzz/run.rb --matrix), transpile corpus, zig suite, mutation
   gate, prspec, Sorbet - all green.
7. Readiness audit: run gems/nil-kill, gems/espalier, gems/decomplex,
   gems/slopcop over the changed compiler code and address findings.

Definition of production-ready: every unit above done, every gate green,
tracker gates flipped, pushed to origin/self-host-i.

## Loop progress (2026-07-22, session 2)

- Oracle advance: the generated lexer now BUILDS and tokenizes correctly -
  smoke cases 0-4 pass and unicode_columns passes standalone. Root causes
  fixed along the way (all pre-existing accept-but-invalid holes):
  - statement-position `TRY (call)` now discards its success payload;
  - translator emits reassign-concat for String << (String has no
    in-place append) and unwraps optional concat operands;
  - `ruby_array_concat_*` helpers emit explicit RETURN;
  - Ruby String#length/#size translate to codepointCount (bytesize stays
    byte-oriented);
  - the native regex scanner OWNS its source copy (callers may free their
    argument while the scanner lives inside a Lexer - INV-12 lifetime);
  - COPY of a plain value into an @multiowned destination deep-copies and
    wraps (coercion no longer forges a retain), with the wrap decision and
    stale-cast cleanup reading the SOURCE model.
- REMAINING BLOCKER (next loop turn): the smoke batch hangs (100% CPU
  spin, single thread) when unicode_columns runs AFTER escaped_string in
  ONE process; each passes alone, and 7 sequential ASCII cases pass.
  Prime hypothesis: scanner double-deinit corrupting the native
  c_allocator arena (second close frees state.source twice), poisoning
  the next case's PCRE2 calls -> zero-advance scan loop. Check the
  emitted lexer zig for TWO cleanup paths on the scanner field
  (struct-lit seed temp + field_pre_cleanup on `view.s = ...` assignment
  + Lexer __clear_drop), and add a poisoned-handle abort in
  compiler_regex.zig test builds to prove it.

## Loop progress (2026-07-22, session 3): LEXER ORACLE SMOKE GREEN

tools/lexer_compat.rb: 13/13 cases, mismatches: 0, with the regenerated
lexer using native keep shapes end to end (optional kept param, field
assign OR_ELSE, retained pass-through into nested interpolation lexers).

Root causes fixed this session (each a pre-existing accept-but-invalid
or wrong-value hole):
- ruby-to-clear emitted Prism #content (raw source) for string literals,
  doubling every escape sequence; now emits #unescaped everywhere
  (visit_string_node + interpolated parts).
- Triple-quoted literal emission absorbed generator indentation into
  string values; literals now always emit the escaped single-line form.
- A literal `${` cannot be spelled in one CLEAR string (interpolation
  opener; `\$` is not an escape) - such literals now emit as
  ("a" $+ "$" $+ "{" $+ "b") concat expressions.
- Ruby negative range ends (str[3..-4]) now translate to
  length-relative substr math instead of a negative length.
- The native regex scanner gained a closed-twice abort (kept as a
  permanent guard).
Remaining loop units: full-corpus oracle, matrix dimensions
(field_assign dest cells etc.), canonical fn-type retention,
BindingRepresentationPlan, serialized incremental contract, full fuzz
matrix, gems readiness audit.

## Loop progress (2026-07-22, session 4)

Full-corpus lexer oracle: 62/79 batches (~620 files) green after the
symbol-ownership fixes. One remaining defect class found:

- transpile-tests/55_string_ops.clear line 43: `18446744073709551615_u64`
  crashes the generated lexer with error.Overflow. The generated numeric
  branch parses digits via toInt (Int64); max-u64 literals need the
  UInt64 domain. TokenValue already has a UInt variant (helper config).
  Next turn: decide the faithful representation - lexer int literals are
  never negative, so either (a) the generated branch parses
  suffix-unsigned (or any out-of-i64) digits through a u64 path emitting
  TokenValue{ UInt: ... } and the compat harness normalizes the
  int/uint kind for comparison against Ruby's bignum, or (b) the Ruby
  lexer source is refactored so the numeric domain is explicit and
  translation follows. Then resume the full corpus from batch 63.

Full fuzz matrix (tools/fuzz/run.rb --matrix): still running in
background at this checkpoint (3,744+ cells green, no failures so far);
collect from /tmp/fuzz_full2.log.

## Session-5 handoff: u64 token-literal design (do this next)

The fix is a numeric-domain refactor, not a one-liner:

1. Ruby lexer (compiler/ruby/ast/lexer.rb): the numeric token pipeline
   (decimal, based, suffixed paths + add_prefixed_int) carries Integer
   bignums; translated CLEAR types the whole pipeline Int64. Make the
   domain explicit: lexer integer literals are never negative, so the
   pipeline's CLEAR-facing type is UInt64. Either introduce a tiny
   helper (int_token_value(digits, base)) that the helper-config maps to
   a native compilerParseTokenInt(digits, base) RETURNS !UInt64, or
   restructure add_prefixed_int's value parameter so the translator
   types it UInt64 (union_variants already maps UInt64 -> UInt).
2. Harness: compare_tokens in tools/lexer_compat.rb must treat Ruby
   kind "int" and CLEAR kind "uint" as equal when values agree (Ruby
   bignum vs CLEAR UInt token).
3. Re-run: --file transpile-tests/55_string_ops.clear first, then the
   full corpus (batch 63 onward held the only known failure).

Full fuzz matrix: first run was killed by a too-small 50-minute
timeout mid-phase (all 3,744 parallel cells green at that point);
relaunched with a 2-hour budget -> /tmp/fuzz_full3.log.

## Loop progress (2026-07-22, session 6): u64 token domain DONE

Implemented the session-5 plan, option (a):

- Native: compilerParseUInt(digits, base) !u64 in
  compiler/src/compiler_regex.zig (std.fmt.parseUnsigned);
  compilerCodepointToString widened to u64 (rejects > 0x10FFFF).
- Config: helpers.string_to_int_base -> compilerParseUInt; prelude
  EXTERN RETURNS !UInt64; types.TokenInt -> UInt64.
- Ruby lexer: TokenInt type alias; add_prefixed_int val: TokenInt;
  integer_suffix_contains? upper-bounds-only (values non-negative by
  construction; u64 arm keeps the 2^64-1 bound to reject bignum
  overflow in the Ruby domain); based literals strip the 0x/0o/0b
  prefix before to_i (Ruby tolerated the prefix, Zig parseUnsigned
  does not) - tr('_','') runs before delete_prefix so the translator's
  string-typed tr registry match still fires.
- Translator: local_analyzer types based to_i as UInt64;
  method_registry wraps the helper in fallible propagation and got a
  UInt64 toFloat overload in std_lib.rb for the f32/f64 suffix arms;
  type_env checks helper_config clear_type before alias expansion.
- Harness: compare_tokens normalizes int/uint token kinds.

Gates on the final tree: smoke oracle 13/13 mismatches 0 (including
based_literals + 0xFF_FF_u32), 55_string_ops mismatches 0, prspec
7240/0 (u64 boundary spec green), sorbet clean, transpile suite exit 0
with 0 leaks, fuzz matrix 3744 cells 0 failures (twice: 2h run + final
tree confirmation).

Note: earlier "corpus batch crash" this session was a zig/.clear-cache
race (deleted the cache while a background batch built) - never rm the
cache while lexer_compat or clear test runs in background.

Remaining loop units: full corpus 79/79 (relaunching post-commit),
canonical fn-type retention, BindingRepresentationPlan, serialized
incremental contract, gems readiness audit.

## Loop progress (2026-07-22, session 6 cont.): self-lex + bare-literal domain

Corpus batch 10 (lexing compiler/src/ast/lexer.clear itself) exposed
that the u64-bound commit introduced a bare 18446744073709551615
literal the self-hosted lexer cannot lex (plain decimals are i64
domain). Fixes:

- Translator visit_integer_node: bare integer literals above i64 max
  emit with _u64 suffix (above u64 max -> unsupported comment).
- Host lexer parity: bare decimal literals above i64 max and bare
  based (0x/0o/0b) literals above u64 max now raise overflow errors,
  matching the self-hosted toInt/parseUInt domains. Spec added
  (range-checks bare literals against their token domain).
- Sorbet cannot parse literals above i64 max, so the u64-max bound is
  spelled ((value >> 63) >> 1) == 0, which stays defined in the u64
  domain (no over-wide shift).
- Removed dead T.bind-rescue slop in with_kept_edge_call_frame
  (decomplex audit).

Readiness audit progress: decomplex report over all 84 changed Ruby
files and espalier over the kept-identity core - the kept-specific
findings were false positives (kept_edge_temp_stack is genuinely
cross-method; scan_kept_fn_value_use! handles shadowing); remaining
pressure is pre-existing (MIRLoweringExpressions method count,
lower_function_def collision). nil-kill/slopcop need runtime+coverage
collection - pending.

Gates: prspec 7241/0, sorbet clean, transpile 618/618 0 leaks (612
migrated off retired ~?T[] syntax missed by 5820928cf), lexer
self-lex mismatches 0.

## Loop progress (2026-07-22, session 6 cont.): incremental contract capture

retention_shape_source now mirrors its semantic derivers EXACTLY.
Four proven-failing-first specs:

- field-assignment keeps (`h.budget = b`, Variables#visit_assignment_field)
  were absent from the interface fingerprint - a body-only edit adding
  one changed the param ABI without invalidating callers;
- OR_ELSE-wrapped keeps (`H{ f: p OR_ELSE d }`) were absent (Lifetimes
  unwraps OR_ELSE and keeps the provided identity);
- the old Move/Copy unwrap was unsound the OTHER way: `H{ f: b }` (kept)
  and `H{ f: COPY b }` (independent identity) fingerprinted identically;
- same for call args: transitive keep fires on bare identifiers only,
  so `keepIt(b)` vs `keepIt(COPY b)` must differ.

This closes the "incremental re-derives syntactically and diverges from
the semantic contract" review item for the shapes the semantic pass
reads today. A fully serialized KeptIdentityContract in the incremental
cache remains the eventual design (blocked on incremental caching
actually persisting semantic facts across processes - today the catalog
is parse-only by design, so an exact syntactic mirror of the semantic
derivers is the correct same-process contract).

Gates: kept spec 20/20, incremental spec 25/25, prspec 7245/0, sorbet
clean. (T.bind in with_kept_edge_call_frame restored - it types self
for Sorbet; only the rescue-nil was slop.)

## Loop progress (2026-07-22, session 6 cont.): shape audit + protocol crash

Empirically probed the not-yet-modeled retention shapes to confirm
fail-closed vs pre-existing-limitation:

- PROTOCOL + kept function: reject_kept_function_values! walks every
  top-level statement whenever a kept function exists, newly reaching
  PROTOCOL nodes. AST.each_child_node assumed Ruby-Struct member access;
  ProtocolRequirement is the one T::Struct Locatable -> NoMethodError
  crash. FIXED (props/public_send fallback) + regression spec. This was
  a real bug the feature exposed.
- Method-receiver keep (self.field = param in a METHOD/IMPLEMENTATION):
  aborts in generated Zig. Confirmed IDENTICAL failure on origin/master
  (pre-existing; @multiowned field + MUTABLE self receiver, unrelated to
  the param-keep feature).
- Plain local stored into an @multiowned field (h.budget = fresh where
  fresh is a plain frame value): Zig compile error. IDENTICAL on master.
  This is the non-param dual (rc field expects Rc(T), gets bare T);
  keep-analysis only models PARAM sources by design.
- Container of identities (push a Budget into []Budget@list @multiowned):
  Rc(T) vs T element-type mismatch in generated List.append. Pre-existing
  container-element representation gap, not param-keep.

Net: the feature's own shapes (param -> struct-lit field, param -> field
assignment, transitive param, GIVE, COPY override, OR_ELSE default,
optional, fallible sibling, expression args, born-as-Rc) are all green
and fuzz/oracle-covered. The remaining shapes are either pre-existing
representation gaps (method-self, local-value, container-element) that
predate the feature and fail on master too, or the fn-value ABI hole
which fails CLOSED with KEPT_FN_VALUE_ABI. Documented as follow-on
representation work (BindingRepresentationPlan), not merge blockers.

## Follow-on design (documented, not merge blockers)

Two units from the review are additive/refactor, not soundness holes;
both have no sound partial slice that improves correctness today, so
they are specified here for a dedicated cycle rather than attempted
piecemeal.

### Canonical fn-type retention (KEPT_FN_VALUE_ABI is the current gate)

State today: a retaining function assigned to a plain function-type
binding is REJECTED at annotation (KEPT_FN_VALUE_ABI, declaration-sited
via kept_identity_declaration_anchor). No invalid Zig is emitted - the
original "retaining fn -> plain FN emits invalid Zig" blocker is closed
by failing closed.

To make retention representable in function values:
1. Type::FunctionTypeParam gains `kept: T::Boolean` (default false).
2. Boundary converters (function_type_expression_for and its inverse)
   thread `kept` through FunctionParamExpression <-> FunctionTypeParam
   so the round-trip stays lossless.
3. Type assignability: a retaining fn is assignable only to a fn type
   whose matching param is `kept` (so `FN(Budget @kept) -> Holder`
   accepts `keep`, plain `FN(Budget) -> Holder` still rejects it - a
   type mismatch, not a special-cased error).
4. Indirect-call lowering: a call through a `kept`-param fn value must
   materialize the Rc(T) at the call site exactly like the direct-call
   kept edge (reuse lower_kept_identity_arg's plan path; the fn value's
   target already has the Rc(T) ABI).
Effort: multi-file type-system change with an indirect-call lowering
leg; deserves its own failing-test-first cycle.

### BindingRepresentationPlan (born-as-Rc still mutates types)

State today: promote_kept_binding! mutates the entry/decl/use-site
Type from T to Rc(T) in place (restamp_promoted_uses!). This WORKS -
all gates green - but conflates "declared capability" with "value
representation." A BindingRepresentationPlan would carry the
representation as a separate stamp the emitter reads, leaving the
declared Type untouched. This is an architectural-cleanliness refactor
of working code, not a correctness fix; no partial slice improves
behavior, so it is deferred whole.

## Review response round 5 (2026-07-22): honest reconciliation

The prior "not merge blockers" framing was wrong to apply to the
architectural items and is retracted. Accurate status:

### FIXED this round (was a real miscompilation)

Issue 3 - capability-polymorphism was UNSOUND. An @shared (Arc) source
kept into an @multiowned (Rc) identity reached Zig as "expected Rc,
found Arc": keep-analysis treated any_rc? (Arc OR Rc) as retainable.
Design decision made: SAME-FAMILY retention only (reviewer's option 1).
Cross-family edges now fail CLOSED with KEPT_IDENTITY_FAMILY_MISMATCH
at annotation; COPY still breaks identity and is exempt. The fuzz hole
that let invalid-Zig count as a passing rejection is closed: every kept
rejection cell now sets diagnostic_code_required and maps to a real
CLEAR code (generator raises otherwise). Verified: kept spec 23/23,
kept matrix 105 cells with 17 code-verified rejections, 0
unexpected-pass.

### OPEN and merge-required (large, interrelated, NOT deferred)

These three are one architectural workstream: make retained identity a
first-class canonically-tracked effect instead of inferred
side-mutations. Measured scope so I/the next session do not
under-estimate:

- Issue 1 BindingRepresentationPlan: born-as-Rc still mutates the
  declared semantic type and restamps use-site type stamps by variable
  name (promote_kept_binding! + restamp_promoted_uses!). Empirically,
  removing either the type mutation or the restamp breaks the born-as-Rc
  golden (622) - 57 reader sites across 16 lowering/backend files
  consult the representation via type predicates (.multiowned?/any_rc?/
  rc_stored?). A sound fix adds a representation channel keyed by stable
  binding identity (entry has next_binding_id; entry.storage is already
  the Escape-owned representation axis) and migrates those 57 readers
  off the mutated type. Memory-safety-critical; must be staged with the
  born-as-Rc golden + leak checks per reader group.
- Issue 2 canonical FunctionSignature retention: the inferred
  retained-parameter effect is not in Type::FunctionType, boundary
  converters, imports, or indirect-call lowering; fn values are rejected
  by a whole-AST name scan (KEPT_FN_VALUE_ABI, fail-closed) and
  incremental mirrors the syntax in SourceCatalog. Sound fix: add
  kept:Bool to FunctionTypeParam, thread it through the converters,
  make assignability family-aware, and lower indirect kept calls through
  the same plan path. Unblocks fn-value retention and a durable
  cross-package contract.
- Issue 4 KeptEdgeLiveness: last-use is a separate syntactic traversal
  indexed by name. There is no pre-existing general last-use/ownership
  plan to consume (OwnershipGraph tracks borrows; FSM liveness is
  segment-scoped), so this requires a shared liveness pass that the
  TAKES machinery and kept edges both consume - coupled to Issue 1's
  representation work.

These need a scoped design pass (and the family-model decision above
is now settled as same-family-only, which bounds Issue 2's
assignability rules). They are not safe to land as blind autonomous
edits across 57 memory-safety-critical readers in one loop iteration.

## Issue 1 migration probe (2026-07-22): reader-group ordering

Attempted the storage-authoritative born-as-Rc migration (remove the
declared-type mutation + by-name restamp; derive representation from
entry.storage). Findings, so the staged refactor starts from evidence:

- promote_kept_binding! reduced to `entry.storage = :multiowned` (+
  arg.symbol re-point). Clean.
- Reader group 1 - declaration wrap (var_decl_facts): MIGRATED cleanly.
  `Type.new(node.full_type!)` is a detached copy, so deriving
  `ft.ownership = symbol.storage` when `symbol.rc_stored? && !ft.any_rc?
  && !ft.any_sync?` wraps the born-as-Rc decl as Rc WITHOUT touching the
  declared type. Sorbet + the isolated decl compiled.
- Reader group 2 - cleanup classifier (classify_rc_or_link): BLOCKS.
  It is a pure (ti: Type) -> entry function keyed on `ti.any_rc?`; with
  the plain type it returns nil and build_drop_entry! then raises "DROP
  for non-owning type Budget". Fixing it requires threading the
  binding's storage/identity into the classifier's type-only interface
  (entry_for_node has the node; the deep classify_* helpers do not).
  This is the memory-safety-critical group (wrong entry = leak or
  double-free) and is why the migration cannot be a blind sweep.
- Reader groups 3+ (kept-edge sources already read CallEdgeOwnershipPlan,
  so they are fine; field-deref / WITH-unwrap / generic-subst still to
  be audited once cleanup threads identity).

Correct sequencing: (a) give the cleanup classifier a binding-identity
input (representation plan or storage) so classify_rc_or_link consults
it, gated by the born-as-Rc + leak suite; (b) then remove the type
mutation + restamp; (c) audit remaining type-predicate readers group by
group with `./clear test transpile-tests/` (0 leaks) as the gate. The
experiment was reverted (it left born-as-Rc leaking); committed state
keeps the working type-mutation approach.
