# Gradual typing — `Auto` typed holes

**Status:** design sketch. Not implemented. Delay to a dedicated release.

## Goal

Let the user leave a type annotation unspecified with `Auto` as a
placeholder. The compiler infers the concrete type from usage, and
`clear fix` rewrites the source with the inferred type. In the common
case, the user writes `Auto` (or omits the annotation entirely — see
below) and the fixer fills it in.

```clear
FN double(x: Auto) RETURNS Auto ->  -- user writes Auto
  RETURN x + x;
END
```

After `clear fix`:

```clear
FN double(x: Int64) RETURNS Int64 ->
  RETURN x + x;
END
```

## Why it's valuable

- Faster to write small glue code without thinking about types.
- Learning curve: beginners get compiler-assisted typing without
  abandoning static types.
- Return-type inference alone covers most of the ergonomic win; it
  accounts for the majority of "why do I have to say this again?"
  pain.

## Behaviour rules

### Parameters (`FN f(x: Auto)`)

- Parser accepts `Auto` anywhere a type identifier goes.
- Annotator tries to infer from call-site usage across the whole
  program.
- **In most cases, inference fails** — a parameter is an input, so
  without constraints beyond the function body, the type is
  under-determined. Succeeds cleanly for:
  - Primitives used in obvious ways (`x + x` -> likely numeric).
  - Parameters passed through to another known-typed call.
- Fixer reports an unresolved `Auto` param as a `:registry`-like
  finding with the message "cannot infer type for parameter `x`;
  please specify". No `:auto` fix in that case — it would require
  the user to pick.

### Return types (`RETURNS Auto`)

- Inference walks the function body, collects the types of every
  `RETURN` expression, and unifies.
- **Usually succeeds** — the body pins down the type.
- Fails on tagged-union returns where the branches produce different
  variants (compiler can't tell if the user meant the union or one
  specific variant). The finding asks the user to name the union.

### Missing annotations (no `Auto` typed, just absent)

- Treated as if the user wrote `Auto`. The parser inserts an implicit
  `Auto` where a type annotation is required by grammar (param type,
  return type).
- This is the common path: most users won't type `Auto` explicitly.
- `clear fix` can add `Auto` as a visible step: if a declaration
  omits a type entirely and inference succeeds, the fixer emits
  `"Add inferred type X"`.

### Interaction with `clear fix`

- When inference succeeds, emit a `FixableFinding` at category
  `:type`, level `:info`, with an `:auto` fix that replaces the
  `Auto` identifier's span with the inferred type.
- When inference fails, emit `:warning` (for params) or `:error`
  (for return types where the compiler needs a concrete type to
  lower correctly).

## Why this is "major work"

### AST / parser

- New `Type` value: `Auto` (singleton) or a marker flag on existing
  Type.
- Parser change: accept `Auto` in every type position. Fine.

### Annotator

Bulk of the work. The annotator today runs over a complete type
environment — every annotation is resolved before the body is visited.
`Auto` breaks that ordering because:

- A function's signature may depend on body analysis (for return-type
  inference).
- A body may depend on parameter types (for param inference).
- Call sites need the resolved signature to type-check.

One workable design:

1. **Phase 1: collect constraints.** Walk every function body and
   record type constraints against each `Auto` slot. Types flow both
   from "what the user wrote" and from "how they used it".
2. **Phase 2: iterate.** Solve constraints; pin any resolved `Auto`s.
   Repeat until fixpoint or a round produces no new bindings.
3. **Phase 3: error on unresolved.** Any `Auto` still open is a
   failed inference — emit a fixable error.

This is a simplified Hindley-Milner-style pass. Not huge, but the
annotator isn't set up for constraint solving — it assumes top-down
type flow. Expect a rewrite of the annotator's type-resolution core.

### MIR / backend

- No changes once every `Auto` is resolved by the end of the
  annotator pass. If one escapes, the MIR / transpiler error
  surfaces as a compiler bug; we want the annotator to guarantee
  every `Auto` is resolved before MIR lowering.

### Fixer

- One new fix helper: `emit_auto_resolved_fix!(span, inferred_type)`.
- Fits the existing `FixableFinding` / `Fix` shape cleanly.

## Phased rollout

**Phase 1 — return types only.** Most ergonomic bang for buck. Walk
the body, unify return types. Emit fixable finding with concrete
type. Skip parameters entirely for now.

**Phase 2 — primitive parameters.** Constraint solver adds "param
type flows from usage inside body". Works for `x + x` (numeric),
`x.length()` (String, List, etc.), etc.

**Phase 3 — cross-function parameter inference.** Full
across-function constraint propagation. Handle parameters that get
passed through to known-typed calls. Most complex.

**Phase 4 — union disambiguation.** Special-case tagged-union
returns so the fixer can offer "the union type" vs "the specific
variant" as interactive choices.

## Decision deferred

This is a dedicated release. Current priorities (fixable-error
coverage, formatter polish, LSP plumbing) are closer to the
critical path. Revisit after:

- Fixable-error coverage reaches ~20 migrated sites.
- LSP prototype lands.
- A handful of real CLEAR programs have been written; we'll know if
  the ergonomic pain is acute enough to justify the annotator rewrite.
