# FSM / Thunk Structural Rearchitecture

## Goal

Remove string-rewrite and regex-scanning protocols from thunk and FSM lowering.
Thunk/FSM compilation should preserve binding identity and ownership facts as
structured compiler data until final Zig emission. Generated Zig text must not be
used as an intermediate representation for semantic rewrites.

Hard architectural blocker: there must eventually be **zero regex usage in
`src/mir`**. No `Regexp`, regex literals, `String#match`, `String#scan`,
`String#gsub` with regexes, or similar text-pattern rewrites belong in MIR
architecture. A pending architecture spec tracks this blocker; this work is not
complete until that spec can be unpended and pass.

This work is motivated by two problems:

- Correctness: text rewrites can mis-handle shadowing, generated names, moved
  guards, cleanup shape, future Zig syntax, or fields whose spelling happens to
  match a regex.
- Performance: repeated `gsub` / `scan` over emitted Zig snippets creates
  avoidable cliffs in large recursive, BG, or FSM-heavy functions.

## Current Problem

Thunk emission and FSM emission both lower semantic compiler facts to Zig text
too early, then patch or rediscover semantics by scanning that text.

Current thunk sites:

- `src/mir/thunk_transform/emit.rb`
  - `render_expr` lowers AST expressions to MIR, then immediately emits Zig.
  - `qualify_params` rewrites bare params to `current.<param>` with regex.
  - `qualify_with_f` rewrites bare params to `f.<param>` with regex.

Current FSM sites:

- `src/mir/fsm_lowering.rb`
  - `promote_fsm_decls_to_fields` rewrites `var X = ...` and related locals to
    `__ctx.X = ...` via regexes.
- `src/mir/fsm_ops.rb`
  - generated fragments use `__FSM_CTX` placeholders that are replaced later.
- `src/mir/fsm_transform/emit.rb`
  - scans emitted text for `__ctx_<id>.<field>` reads.
  - scans emitted text for moved-guard writes.
  - scans emitted text for `defer` / `errdefer` cleanup lines.
  - strips and rewrites cleanup snippets into destroy-task lines.

This means the compiler is treating Zig source text as a second, informal MIR.
That is the wrong abstraction boundary.

## Desired Architecture

### 1. Name Resolution Is Structural

MIR lowering should support an explicit binding render context:

```ruby
BindingRenderContext(
  locals: { "x" => MIR::CtxFieldRef.new(ctx: "__ctx_4", field: "x") },
  moved_guards: { "x" => MIR::CtxFieldRef.new(ctx: "__ctx_4", field: "x_moved") },
)
```

When lowering an `AST::Identifier`, MIR should retain or attach the resolved
binding target. Final emission renders the target as `x`, `current.x`, `f.x`, or
`__ctx_4.x` depending on the active context. No regex should be needed to
rewrite identifier text after emission.

### 2. Segment Lowering Returns Typed Facts

FSM segment lowering should return structured data instead of raw Zig strings:

```ruby
FsmSegmentLoweringResult(
  stmts: T::Array[MIR::Stmt],
  reads: T::Set[String],
  writes: T::Set[String],
  move_guard_writes: T::Set[String],
  cleanup_facts: T::Array[FsmCleanupFact],
)
```

The exact type names can change during implementation, but the important point
is that reads, writes, moved guards, promoted locals, and cleanup facts come
from MIR facts and lowering context, not from emitted text scans.

### 3. Cleanup Lifting Is a Fact Protocol

FSM cleanup lifting should not parse `defer` lines. The lowerer should produce a
typed cleanup fact when a cleanup must run at segment exit, function exit, or
FSM destroy-task exit:

```ruby
FsmCleanupFact(
  name: "buf",
  source: :body,
  timing: :destroy_task,
  guard_field: "buf_moved",
  cleanup: MIR::CleanupCall(...)
)
```

Final emission can render that fact once. This removes the current dependency on
the spelling of `defer CheatLib.cleanup(...)`.

### 4. Placeholders Are Deleted, Not Wrapped

`__FSM_CTX` and related placeholder strings should disappear. If a generated
operation needs a context field, it should hold a structured context-field
reference from construction time.

## Implementation Plan

### Phase 0: Baseline and Guardrails

- Snapshot compile timings for the known pathological imports:
  - `tmp/nil-kill/require-corpus-shard-0095.clear`
  - `tmp/nil-kill/require-corpus-shard-0104.clear`
- Snapshot `decomplex` and `slopcop` reports.
- Keep the architecture spec blocker for zero regex usage in `src/mir`. It is
  pending while legacy FSM code still violates it; completing this rearchitecture
  means making that spec pass.
- Add focused tests that cover thunk/FSM parameter qualification and FSM cleanup
  lifting before replacing the mechanism.
- Add a grep-based temporary guardrail in tests or tooling that fails if new
  thunk/FSM code introduces additional regex rewrites over emitted Zig text.

### Phase 1: Thunk Binding Context

This is the smallest safe first step.

- Introduce a typed render context for thunk parameter references.
- Replace `qualify_params` and `qualify_with_f` with structural identifier
  rendering.
- Keep the existing generated MIR node shapes if possible, but stop generating
  bare Zig and patching it afterward.
- Delete the thunk regex helpers in the same commit.

Acceptance:

- No `qualify_params` / `qualify_with_f` regex rewrites remain.
- Existing thunk tests pass.
- Added tests prove params are rendered through the active frame payload.
- Decomplex / SlopCop do not move materially in the wrong direction.

### Phase 2: FSM Context Field References

Replace placeholder context strings before touching cleanup.

- Introduce `MIR::CtxFieldRef` or equivalent.
- Update FSM segment construction so promoted locals and synthetic fields are
  represented structurally.
- Delete `__FSM_CTX` placeholder replacement from FSM paths.
- Update emitter to render context refs directly.

Acceptance:

- No `__FSM_CTX` placeholder replacement remains.
- Segment output still compiles for existing BG/FSM tests.
- Reads/writes needed by the FSM structure are derived from structured refs.

### Phase 3: FSM Segment Facts

Replace scans used to rediscover context field reads and move-guard writes.

- Make segment lowering return a typed result object.
- Populate reads/writes/move-guard writes while lowering MIR nodes.
- Replace `text.scan(/__ctx_.../)` and moved-guard scans with those facts.

Acceptance:

- Context read and move-guard write scans are deleted.
- FSM structure generation consumes typed segment facts.
- Existing FSM and BG integration tests pass.

### Phase 4: FSM Cleanup Facts

Replace cleanup parsing and cleanup line rewriting.

- Reify cleanup lifting into typed facts.
- Replace `defer` / `errdefer` scans with facts produced by lowering.
- Replace `lifted_ctx_cleanup_to_destroy!` string parsing with fact emission.
- Delete cleanup regexes once all call sites use facts.

Acceptance:

- No FSM cleanup code parses generated Zig lines.
- Destroy-task cleanup order is preserved.
- Leak/TSan and BG/FSM tests pass.

### Phase 5: Metrics and Runtime Validation

- Re-run unit specs with `prspec`.
- Re-run relevant integration / transpile tests.
- Re-run focused fuzz or corpus shards that exercise BG/FSM/thunk paths.
- Re-run compile timing for known pathological files.
- Regenerate `decomplex`, `slopcop`, and nil-kill data if implementation work
  touches ownership or cleanup facts.

## Done Criteria

The work is complete only when:

- The pending architecture spec for zero regex usage in `src/mir` is unpended
  and passes.
- Thunk lowering does not regex-rewrite emitted expressions.
- FSM lowering does not use placeholder strings for context references.
- FSM structure does not scan emitted Zig for context reads or moved guards.
- FSM cleanup lifting does not parse emitted Zig `defer` lines.
- New code is strongly typed and uses typed records for record-shaped data.
- Old string-rewrite paths are deleted, not kept as fallback paths.
- Tests pass locally for the affected unit/integration/fuzz surfaces.
- Compile timings for the known pathological imports improve or the remaining
  hotspot is identified as a different subsystem with evidence.

## Scrap Criteria

Stop and reassess if:

- The replacement keeps both structural facts and the old string scans.
- The change adds a broad compatibility layer instead of deleting old paths.
- Metrics regress because decisions were moved into more helpers without
  removing the original protocol.
- The profiler proves the 15-20s cliffs are unrelated to thunk/FSM string
  rewrites and the structural work would not materially improve correctness.

## Expected Payoff

Thunk cleanup is medium effort and should be straightforward. FSM cleanup is
larger, but it is the higher-value architectural fix. If successful, this should
make BG/FSM lowering less brittle, make ownership cleanup easier to verify, and
remove a class of performance cliffs caused by repeated scans over generated
Zig text.
