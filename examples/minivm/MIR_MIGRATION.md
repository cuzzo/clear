# MIR-based VM migration plan

Goal: make `examples/minivm/bc_emitter.rb` a pure MIR template engine —
the same contract CLAUDE.md specifies for `src/mir/mir_emitter.rb`:

> The emitter maps each MIR node to a fixed Zig text fragment. It makes
> NO ownership decisions, inspects NO types, and chooses NO allocators.

Every AST-peek, name-heuristic, and string-matched callee in the current
bc_emitter (commit `2afe4193`'s "compromise pass") is a signal that MIR
is missing a distinction the emitter needs. The fix is always the same:
push the decision up into lowering, encode it structurally in an MIR
node, and let both emitters (Zig, bc) dispatch on node class.

## Invariant (applies to every step below)

Every step must preserve:

- `bundle exec prspec spec/` at 2424/2424.
- `./clear test transpile-tests/` at 327/327, 0 memory leaks.
- No change to emitted Zig source for any tested program — the Zig
  backend is the production path and must not regress.

Step acceptance also tracks:

- VM coverage (`run_tests.rb --vm-coverage`) stays flat or improves.

## Scope: minimise Zig backend disruption

Each phase is designed so the Zig emitter's output is byte-identical
before/after the phase. Where a new MIR node is introduced, the Zig
emitter gets a case that produces the same string it did for the old
shape. Migration risk scales with number of files touched; we try to
keep it `mir.rb + mir_lowering.rb + mir_emitter.rb + bc_emitter.rb`
per phase.

---

## Phase 0 — scaffold the RawBc node (no behaviour change)

**Goal**: add `MIR::RawBc` as a sibling of `MIR::RawZig`. Nothing emits
it yet; both emitters get a handler; Zig emitter's handler for `RawBc`
is a fallback that expands via `node.stdlib_def[:zig]` if present (same
safety net we already have for `InlineBc`). bc_emitter's handler walks
the `template` array, emitting opcodes per element.

**Touches**: `src/mir/mir.rb` (+12 lines), `src/mir/mir_emitter.rb` (+6
lines), `examples/minivm/bc_emitter.rb` (+20 lines).

**Changes**:

```ruby
# src/mir/mir.rb
RawBc = Struct.new(:template, :args, :stdlib_def) do
  include Stmt
  def expr?; true; end
end
```

**Unlocks**: nothing yet. Sets up the sibling shape so Phase 1 has a
target to emit into.

---

## Phase 1 — registry-first migration of InlineZig

**Goal**: every `MIR::InlineZig.new(pattern, reason, ...)` call in
`src/mir/mir_lowering.rb` that isn't already going through
`emit_builtin` moves into `BUILTIN_OPS` / `STD_LIB`. The emission site
calls `emit_builtin(:op_name, [args])`. Same Zig output, centralized
template.

**Touches**: `src/mir/mir_lowering.rb` (audit + refactor, ~30-50 sites),
`src/ast/std_lib.rb` (new registry keys).

**Changes**:

- `grep -n 'MIR::InlineZig.new' src/mir/mir_lowering.rb` — audit every
  site. Classify:
  - Stdlib-shaped (`CheatLib.foo(...)` → has a registry entry or can
    add one) → migrate to `emit_builtin(:foo, args)`.
  - Pure Zig construct (`@as(i64, ...)`, `@intCast`, struct literal
    inline) → leaves as-is for Phase 3.
- Each migrated op gets a `BUILTIN_OPS[:foo] = { zig: "...", ... }`
  entry. Later phases add `bc:` templates.

**Invariant**: Zig emitter output byte-identical. Spec test: diff of
`emit(program)` before/after.

**Unlocks**: every migrated op is now trivially portable to bc by
adding a `bc:` key. No more case-per-op special-casing in bc_emitter —
it just reads the registry.

**Completes the InlineBc coverage model**: once all stdlib calls go
through `emit_builtin`, bc_emitter's `compile_inline_bc` dispatches
purely on registry data, not hard-coded name matches.

---

## Phase 2 — decompose structural RawZig

**Goal**: every `MIR::RawZig.new(...)` currently used for structural
Zig patterns (loops, conditions, field assignments, defer blocks) gets
replaced with the already-existing MIR structural nodes
(`MIR::WhileStmt`, `MIR::IfStmt`, `MIR::Set`, `MIR::DeferStmt`, …).

**Touches**: `src/mir/mir_lowering.rb` (per-callsite rewrites).

**Changes**: site-by-site audit. Each `RawZig` block either:

1. Becomes a composition of existing MIR nodes (most cases).
2. Gets `stdlib_def` populated for what it calls (if stdlib-shaped,
   already covered by Phase 1).
3. Remains as `RawZig`, annotated in the commit that touches it with
   the reason ("irreducibly Zig-specific: e.g. `comptime` trick,
   inline `@asm`, Zig error union syntax").

**Invariant**: Zig emitter output byte-identical.

**Unlocks**: the Zig emitter's handling of `MIR::RawZig` stops being
a catch-all for "this was too hard to model." That makes `RawBc`
straightforward to introduce — every remaining `RawZig` has a clearly
documented reason for being opaque, and a corresponding `RawBc` can
be provided (or the VM can surface `Unimplemented:<reason>` cleanly).

---

## Phase 3 — target-aware RawZig → RawBc

**Goal**: extend the target-aware mechanism from `InlineZig/InlineBc`
to `RawZig/RawBc`. When `target == :bc` and the `RawZig` site has a bc
equivalent (registered or inlined), lowering emits `RawBc` instead.

**Touches**: `src/mir/mir_lowering.rb` (add bc branches at each `RawZig`
emission site), `src/ast/std_lib.rb` (if any remaining `RawZig` is
stdlib-shaped).

**Changes**:

- For each remaining `MIR::RawZig.new` call:
  - If a bc equivalent exists, add `if @target == :bc && entry[:bc_raw]
    then MIR::RawBc.new(entry[:bc_raw], args, entry) else MIR::RawZig.new(...)`.
  - Entries not yet portable: emit `MIR::RawZig` with `target_unsupported: :bc`
    marker so bc_emitter surfaces a clean `Unimplemented` with the
    original Zig code in the error message.

**Invariant**: Zig emitter output byte-identical (still emits `RawZig`
for `:zig` target).

**Unlocks**: bc_emitter never sees `MIR::RawZig` / `MIR::InlineZig`
in production runs — those are now `:zig`-target-only artifacts.

---

## Phase 4 — distinguish union variant access vs struct field access

**Goal**: resolve the `FieldGet(union, variant)` vs `FieldGet(struct,
field)` ambiguity that currently forces bc_emitter to use name
heuristics. Add a dedicated MIR node (Option B from the prior design
discussion).

**Touches**: `src/mir/mir.rb` (+new node), `src/mir/mir_lowering.rb`
(type-aware emission), `src/mir/mir_emitter.rb` (new handler),
`examples/minivm/bc_emitter.rb` (new case).

**Changes**:

```ruby
# New MIR node
UnionVariantGet = Struct.new(:object, :variant, :zig_type) do
  include Expr
end
```

- `lower_field_get(node)`: if `node.object.type_info` resolves to a
  union type AND `node.field` is a declared variant → emit
  `MIR::UnionVariantGet`. Else → `MIR::FieldGet` as today.
- Zig emitter: renders `@as(ZigType, obj).variant` or equivalent —
  byte-identical to what the old `FieldGet` path produced for a union.
- bc emitter: emits `NATIVE_CALL cdr 1`.

Same treatment for **list decomposition**: add `MIR::ListItems(list)`
and `MIR::ListLength(list)` to replace the `FieldGet(_, "items")` and
`FieldGet(_, "len")` Zig-ArrayList-internal pattern. Zig emitter
renders `obj.items` / `obj.items.len`; bc emitter renders identity /
`NATIVE_CALL count`.

**Invariant**: Zig emitter output byte-identical.

**Unlocks**: bc_emitter's `compile_field_get` drops the `.items` and
`.len` special cases and the `find_field_index` name scan — field access
is one native `vector-ref` path, because only struct access reaches it.

---

## Phase 5 — formalise `rt` param and `CheatLib.promote*` callsites

**Goal**: stop the remaining two kludges in bc_emitter:

- `rt` param stripping in both call-site and helper-decl paths.
- String-matching `CheatLib.promote*` / `dupeUnionValue` callees.

**Touches**: `src/mir/mir.rb`, `src/mir/mir_lowering.rb`, both emitters.

**Changes**:

- `MIR::FnDef` gets `implicit_params` field (currently implicit: just
  `rt`). Emitters don't reserve slots for these; lowering knows about
  them. Or: drop the synthetic `rt` param from `MIR::FnDef.params`
  entirely — the Zig emitter accesses `rt` via a thread-local convention
  that the emitter inserts in the prologue. Both options remove the
  "caller strips rt, callee also strips rt" symmetry.
- The `CheatLib.promote*` family was always a `MIR::DeepCopy` wearing a
  `MIR::Call` hat. Audit every site where `MIR::Call.new("CheatLib.<promote/dupe>", …)`
  is emitted and replace with `MIR::DeepCopy`. The Zig emitter already
  handles `MIR::DeepCopy`; bc_emitter's case is just `compile_expr(source)`.

**Invariant**: Zig emitter output byte-identical.

**Unlocks**: bc_emitter's `compile_call_expr` drops the `"CheatLib.promote*"`
string-match block entirely. Callee names never matter for correctness —
MIR nodes always carry the decision.

---

## Phase 6 — bc_emitter becomes a pure template engine

**Goal**: delete `compile_ast_stmt` / `compile_ast_expr` / etc. from
bc_emitter. Every MIR node has a native handler, or it raises
`Unimplemented` pointing at the specific MIR node class.

**Touches**: `examples/minivm/bc_emitter.rb` (~500 lines of AST
fallback methods deleted).

**Changes**: remove every `compile_ast_*` method. Remove `ast_node`
plumbing from `compile_stmt`, `compile_expr_stmt`, etc. If any handler
was relying on AST fallback, it becomes `Unimplemented` with the MIR
node class name — the debugging surface is now "add a handler for
MIR::X" not "figure out which of 20 compile_ast_Y methods this went
through".

**Invariant**: VM coverage holds or improves. Ruby specs / transpile-tests
unaffected.

**Unlocks**: bc_emitter is now a pure 1:1 mirror of MIREmitter's node
dispatch structure. Any third backend (interpreter, native codegen,
debug-visitor) gets to follow the same template.

---

## Ordering and dependencies

- Phase 0 is trivial scaffolding, no dependencies.
- Phase 1 is pure refactoring; no dependencies beyond Phase 0 existing.
- Phase 2 can run in parallel with Phase 1.
- Phase 3 depends on Phase 1 and 2 (every remaining RawZig is now
  known-shaped).
- Phase 4 is independent — can be done any time after Phase 0.
- Phase 5 is independent.
- Phase 6 is the final cleanup, depends on 1–5 leaving only MIR nodes.

Each phase is 1 commit. Each commit has the three-suite check:
`bundle exec prspec spec/`, `./clear test transpile-tests/`,
`ruby examples/minivm/run_tests.rb --vm-coverage`.

## What's NOT in scope here

- VM performance work (timeouts on loop-heavy tests).
- Narrow integer types (Int8..UInt64, Float32) — gated as VM_UNSUPPORTED.
- Adding new Value variants to `_bc_runner.clear` — separate runtime work.
- Fiber scheduling / BG blocks / concurrent streams — architecturally
  out of scope for the VM (gated as VM_UNSUPPORTED).

---

## Success criterion

When all 6 phases are done:

- `grep -n 'MIR::InlineZig\|MIR::RawZig' examples/minivm/bc_emitter.rb`
  returns only the `raise Unimplemented` case.
- `grep -n '@result\.' examples/minivm/bc_emitter.rb` — no access to
  AST-level schemas (enum_types, union_types, struct_fields are all
  derived from MIR or dropped entirely).
- `grep -n 'compile_ast_' examples/minivm/bc_emitter.rb` returns
  nothing.
- VM coverage: estimated 60-80 PASS (from the union/match/FAIL cluster
  cleanly handled).
