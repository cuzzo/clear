# Compiler Error Audit (Layer 1)

Read-only survey of every place the compiler emits a diagnostic. Drives
Layer 2 (centralization + error codes) and Layer 3 (coverage push,
message-quality pass).

Snapshot: `error-audit` branch off `origin/polymorphic-sync-v3`.

## Summary

**~513 emit sites across the compiler.** Of those, **~9% use the
centralized `MESSAGES` registry** (`src/ast/source_error.rb`); the
rest are ad-hoc string literals or interpolations.

| Emit shape | Sites | Notes |
|---|---:|---|
| `error!(node, :SYM, ...)` (centralized) | 41 | Looks up template in `MESSAGES`. The intended path. |
| `error!(node, "...")` (ad-hoc literal) | 95 | Bypasses the registry. |
| `error!(node, "...#{...}...")` (ad-hoc interpolated) | 205 | Bypasses the registry. Most numerous. |
| `fixable!(...)` | 31 | Used for warnings + interactive fixes. Mostly ad-hoc messages. |
| `note!`, `warning!` | 17 | Non-fatal informational; ad-hoc. |
| `raise CompilerError/ParserError` direct | 7 | Pre-dates the helper layer. |
| `MIRChecker @errors << error(:KIND, ...)` | 11 | Separate code system parallel to `MESSAGES`. |
| `$stderr.puts "[Warning] ..."` | 11 | Direct stderr; no registry, no collector. |

**The infrastructure exists; the discipline drifted.** `source_error.rb`
already supports either a Symbol code or a raw String. The Symbol path
is the registry. The String path is labelled "Legacy Support" in the
helper itself. Most error sites take the legacy path.

## Per-file ad-hoc concentration

Worst offenders (annotator + parser dominate):

| File | error! sites | centralized | ad-hoc | % registry |
|---|---:|---:|---:|---:|
| `src/annotator.rb` | 180 | 13 | 167 | 7% |
| `src/ast/parser.rb` | 69 | 0 | 69 | 0% |
| `src/annotator-helpers/pipe_analysis.rb` | 50 | 3 | 47 | 6% |
| `src/annotator-helpers/function_analysis.rb` | 29 | 4 | 25 | 14% |
| `src/annotator-helpers/capabilities.rb` | 28 | 0 | 28 | 0% |
| `src/annotator-helpers/generic_analysis.rb` | 24 | 7 | 17 | 29% |
| `src/annotator-helpers/union.rb` | 18 | 14 | 4 | **78%** |

`union.rb` is the proof of life — the union-types feature was added
later and was disciplined about routing every error through the
registry. The earlier-written files (parser, capabilities, annotator)
predate or escape that discipline.

## What's already centralized (`MESSAGES` in `source_error.rb`)

66 message templates registered. 34 are actually referenced by an
`error!(:SYM, ...)` call site; the other ~32 appear unused (likely
refactored to ad-hoc form or removed but the entry kept). Examples
of the unused entries:

```
FIXED_ARRAY_SIZE_AS_DYNAMIC
FIXED_ARRAY_SIZE_MISMATCH
GENERIC_DUPLICATE_TYPE_PARAM
GENERIC_FN_DUPLICATE_PARAM
GENERIC_FN_PARAM_SHADOWS_BUILTIN
GENERIC_TYPE_PARAM_SHADOWS_BUILTIN
HEAP_PRIMITIVE
ILLEGAL_BREAK
ILLEGAL_CONTINUE
ILLEGAL_UPVALUE
```

These are good cleanup candidates: either the actual call site
should be reverted to the registry, or the entry should be deleted.

## Categories that exist (from `fixable!` calls)

The `category:` field on `FixableFinding` is a fixed enum:
`:lint :ownership :capability :escape :type :registry :reentrance`.
Currently used:

| category | sites |
|---|---:|
| `:type` | 18 |
| `:lint` | 6 |
| `:reentrance` | 5 |
| `:ownership` | 3 |
| `:registry` | 2 |
| `:escape` | 2 |
| `:capability` | 2 |

Plain `error!` emissions don't have a category field at all — adding
one as part of Layer 2 lets `clear fix --only=cat,...` filtering work
across the whole error catalog, not just the explicitly-`fixable!`
ones.

## Common message-prefix conventions (from ad-hoc strings)

Top prefixes in ad-hoc messages — natural category seeds:

```
"Type Error: ..."         14 sites
"Lifetime Error: ..."      7 sites
"Syntax Error: ..."        3 sites
"Reentrancy Error: ..."    3 sites
"EFFECTS REENTRANT: ..."   3 sites
```

Many other messages start with feature keywords (`@observable`, `BG`,
`CONCURRENT`, `MATCH`, `WITH`, ...) which suggest a feature-axis
breakdown of error codes (not just a generic `:type` / `:syntax`
split).

## MIR checker has its own code system

`src/mir/mir_checker.rb` enforces 11 invariants and emits errors via a
private `error(kind, name, msg)` formatter `[KIND] fn::name -- msg`:

```
ALLOC_CLEANUP_MISMATCH    HPT_LEAK
ALLOC_WITHOUT_CLEANUP     INLINE_ALLOC_MISMATCH
CLEANUP_WITHOUT_ALLOC     INLINE_NO_CONTRACT
COPY_CLEANUP              RAW_NO_CONTRACT
FRAME_NO_REWIND           RAW_UNJUSTIFIED
                          UNHOISTED_ALLOC
```

These are codes already — just not in the same registry as
`MESSAGES`. Layer 2 should unify them under a single
`ErrorRegistry` so an end user sees one consistent code system,
not two.

## Fix coverage

| Fix confidence | Sites |
|---|---:|
| `:auto` (apply without asking) | 21 |
| `:interactive` (multi-candidate, ask user) | 12 |
| (no fix at all) | ~480 |

So **~94% of error sites offer no programmatic fix.** Many of those
genuinely have no deterministic fix (e.g., type-mismatch where the
compiler can't guess which side is wrong), but a meaningful fraction
of the 480 do — at least an `:interactive` "did you mean ..." fix is
often possible.

## Implications for Layer 2 (recommended)

1. **One registry, two API shapes.**
   Merge `MESSAGES` (compile-time) and the MIR `:KIND` codes into a
   single `ErrorRegistry`. Each entry carries `code`, `category`,
   `severity`, `template`, `cause`, `fix_hint`, `example_bad`,
   `example_good`. Both `error!` (raise) and `MIRChecker.error` (push
   to errors list) read from the same registry.

2. **Per-error documentation.**
   Each registered code gets a `docs/errors/EXXXX.md` file (or
   `docs/errors/<SYMBOLIC_NAME>.md`). Generated from the registry to
   stay in sync. `clear explain <code>` reads it.

3. **Mass refactor of the 472 ad-hoc sites.**
   This is the bulk of the work. Doable in stages:

    - First pass: parser (69 sites, all ad-hoc) — well-bounded,
      mostly `Expected X, got Y` family, easy to template.
    - Second pass: capabilities (28 sites, all ad-hoc) — all
      relate to `@locked` / `@shared` / sigils.
    - Third pass: pipe_analysis (47 ad-hoc) — pipeline stage
      validation, naturally clusters around `WHERE`/`SELECT`/etc.
    - Fourth pass: annotator core (167 ad-hoc) — the largest, most
      heterogeneous pile. Best done per-feature.

4. **Categories on every emission.**
   Add a `category:` field as a required `error!` arg (with a default
   of `:type` for incremental migration). `clear fix --only=...`
   filtering then becomes meaningful for the whole catalog.

5. **Cleanup pass.**
   The ~32 unused MESSAGES entries are dead code — either restore
   their use or delete the entries to reduce confusion.

## Implications for Layer 3 (coverage push)

Once codes exist, prioritize fixes by:
- **Frequency** (errors hit during test runs) — needs a counter
  hooked into `error!` to actually measure.
- **Determinism** (clear fix exists) — most parser errors qualify
  (`Expected ;` -> insert `;`).
- **Polish bar** (Rust-quality message) — what / why / how to fix,
  with a span pointing at the relevant token.

Suggested first targets, in priority order:

1. Parser errors (69 sites). All centralizable; many auto-fixable
   (missing `;`, missing `END`, mismatched `{ }`). High-frequency
   for new users.
2. Capabilities (28 sites). Concentrated around a small feature
   set; messages are currently terse ("`@observable cannot be
   combined with...`"). Consistent tone + examples would help a
   lot here.
3. Pipe analysis (47 sites). Same reasoning — concentrated around
   pipeline-stage validation.
4. The MIR checker codes (11 sites). Already coded; just unify
   into the registry and add doc pages.

## Out of scope for this audit

- Runtime error messages (Zig-side panics, FsmIo errors). They
  surface to the user but live in `zig/` and have their own surface.
- The `RAISE`-system error names (`ErrorName_LockTimeout` etc) —
  those ARE compile-time-stable IDs but for runtime error values, not
  compiler diagnostics.

## Methodology

Counts gathered via:

```sh
grep -rn 'error!\|fixable!\|raise CompilerError\|raise ParserError' \
  src/ --include='*.rb'
```

with regex variants for `error!(:SYM, ...)` vs `error!("...")` to
split centralized from ad-hoc. Per-file breakdowns from the same data
re-grouped by filename. Numbers are point-in-time; expect drift as
work proceeds.
