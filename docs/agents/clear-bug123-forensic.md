# Bugs #1 / #2 / #3 Forensic

Same shape as [`bug9-forensic.md`](bug9-forensic.md). For each of the
remaining CLEAR-side bugs uncovered while building `vm.cht`, this
document identifies:

1. **Which MIR pipeline stage** is responsible.
2. **Which fuzz template** should have generated the shape (and didn't).
3. **What the minimal fix or coverage delta is.**

The reproducers are
[`transpile-tests/known-failing/bug{1,2,3}_*.cht`](../../transpile-tests/known-failing/).

---

## Bug #1 — Hoisted temp emitted after its use site

**Symptom**: Zig rejects the emitted file with
`use of undeclared identifier '__tmp_N'` because the temp is declared
inside the `if` body block while the condition references it.

### Pipeline stage: `MIRLowering.lower_if` ordering bug

Trace through the relevant code paths:

1. `lower_body` iterates the outer statements; sees `IfStatement`; calls `lower_if(node)`.
2. `lower_if`
   ([`src/mir/mir_lowering.rb:6670`](../../src/mir/mir_lowering.rb))
   does:
   ```ruby
   cond = lower(node.condition)           # ← hoist_alloc may push to @pending_stmts
   then_body = lower_body(node.then_branch)
   else_body = ...
   MIR::IfStmt.new(cond, then_body, else_body)
   ```
3. `lower(node.condition)` lowers `(maybe("STRINGS") OR "") != "STRINGS"`.
   The `maybe(...) OR ""` becomes a `MIR::TryCatch` whose
   `heap_provenance` is true. `hoist_alloc` pushes an `AllocMark + Let +
   Cleanup` triple to `@pending_stmts` and substitutes
   `MIR::Ident("__tmp_2")` in the cond.
4. `then_body = lower_body(node.then_branch)`. **`lower_body`'s first
   iteration calls `flush_pending` BEFORE the first statement of the
   then-branch** ([`mir_lowering.rb:481`](../../src/mir/mir_lowering.rb)),
   which drains the still-present pending Let from step 3 — into the
   then-body, **not the outer scope**.
5. The result is `[IfStmt(cond=Ident("__tmp_2"), then_body=[Let("__tmp_2", ...), ...RAISE...])]`.
   `Ident("__tmp_2")` is used in `cond` (emitted first) before the
   `Let("__tmp_2", ...)` inside `then_body` (emitted second). Zig says
   "use of undeclared identifier".

**Diagnosis**: `lower_if` doesn't isolate the cond's pending stmts.
They leak into the then-body via the shared `@pending_stmts` buffer.

**Fix shape** (minimal):

```ruby
def lower_if(node)
  ...
  cond = lower(node.condition)
  cond_pending = flush_pending          # drain BEFORE lowering then-body
  then_body = lower_body(node.then_branch)
  else_body = ...
  if_stmt = MIR::IfStmt.new(cond, then_body, else_body)
  cond_pending.empty? ? if_stmt : (cond_pending + [if_stmt])
  # lower_body's caller knows to flatten arrays.
end
```

The same fix must land in every place that lowers a control-flow node
with a condition: `lower_while`, `lower_while_bind`, `lower_match`,
`lower_for_range`, `lower_for_each`. Each has the same shape (lower
condition / iterable; pending stmts implicitly leak into body).

### MIR Checker invariant that could defend

A use-before-decl check: every `MIR::Ident("__tmp_N")` reference must
have its corresponding `MIR::Let("__tmp_N", ...)` earlier in the
linear MIR sequence (taking IfStmt branches into account). This is a
basic SSA-liveness property the checker doesn't currently enforce.

### Fuzz template: `or_positional` is the one, but with a missing axis

`or_positional.rb` already exists for "every syntactic position OR can
appear in". Its `OR_POSITIONS`:

```ruby
OR_POSITIONS = [:assign_rhs, :fn_arg, :method_arg, :return_expr,
                :with_source, :collection_lit]
```

**`:if_cond` is missing.** The same gap applies to `:while_cond` and
`:match_subject`. Bug #1 is the `:if_cond` cell.

A reproducer in the template would look like:

```cht
FN main() RETURNS !Void ->
  IF (mayFail() OR "fallback") != "expected" THEN
    RAISE "wrong";
  END
  RETURN;
END
```

Add `:if_cond`, `:while_cond`, `:match_subject` to `OR_POSITIONS` and
the template's body renderer; the matrix grows 60 → 90 cells. Today
the new cells fail (Zig forward-reference). Once the lowering
ordering is fixed they all pass.

---

## Bug #2 — `[FRAME_NO_REWIND]` on a non-escaping local temporary

**Symptom**:
```
[FRAME_NO_REWIND] clearMain::clearMain --
  loop body frame-allocates but has no restoreLoopMark defer
```
on a `parts = haystack.split(" ")` inside `WHILE`. The local never
escapes the loop body; the lowering should have set
`mark_per_iter = true` and emitted a `saveLoopMark`/`restoreLoopMark`
defer pair.

### Pipeline stage: `LoopFrameAnalysis.analyze_loop_node!` not seeing the decl

[`src/mir/control_flow.rb:1315`](../../src/mir/control_flow.rb):
```ruby
frame_decls = local_frame_decls(body, local_names)
escaping, non_escaping = frame_decls.partition do |decl|
  escapes_to_outer?(decl.name.to_s, body, local_names)
end
loop_node.mark_per_iter = non_escaping.any?
```

If `parts` were included in `frame_decls` and `escapes_to_outer?`
returned false (it doesn't escape), `non_escaping.any?` would be true
and `mark_per_iter` would be set. The checker only fires when
`mark_per_iter` is false; therefore `parts` is **not** in
`frame_decls`.

`local_frame_decls` filters:

```ruby
when AST::BindExpr
  ti = Type.from_node(s)
  next unless ti
  is_frame = ti.frame_provenance? &&
             (ti.list_collection? || ti.map? || ti.array? || ti.string?)
  decls << s if s.mode == :decl && is_frame && s.name.is_a?(String)
```

`parts = haystack.split(" ")` IS an `AST::BindExpr` with `mode = :decl`
and `name = "parts"`. So the filter must be returning false on one of:

- `Type.from_node(s)` — possibly nil if the binding's type info hasn't
  been propagated from `split`'s return type.
- `ti.frame_provenance?` — possibly false if the stdlib `split`'s
  `:node_storage` allocator didn't propagate :frame back to the
  binding's type info.
- `ti.array?` — `String[]` is a slice; should be true.

The most likely cause (without instrumenting) is the second:
`split`'s `:node_storage` allocator says "use the binding's storage"
but the binding's storage isn't computed at the time
`local_frame_decls` runs, so the type info still has no provenance.

**To complete the forensic, the next step is** add a one-line
`puts ti.inspect` inside `local_frame_decls` for `BindExpr` and run
the bug-#2 reproducer — either the type comes back without
`frame_provenance` (annotator gap) or without `array?` (type-resolution
gap).

**MIR Checker side**: the checker correctly fires `FRAME_NO_REWIND`,
which is exactly what it's supposed to do. The bug is on the
**Lowering** side per CLAUDE.md's role split — the lowering should
have promoted-to-heap or set mark_per_iter; the checker is the
backstop, not the fixer.

### Fuzz template: none cover this shape

`loop_carry_collection` exists for "list built INSIDE loop, used
AFTER loop" — list lives in the enclosing frame, not per-iteration.
`nested_loop_escape` covers "list built INSIDE loop, escaped INTO
outer container."

**No existing template covers**: "method-call result bound inside
loop body, used only within the same iteration, never escapes." Bug
#2 is exactly this. A new template — call it
`loop_local_method_temp` — needs cells crossing:

- `kind ∈ { :split, :concat, :substring, :list_literal, :string_literal }`
  (whichever stdlib methods return frame-provenance values)
- `loop ∈ { :while, :for_range, :for_each }`
- `binding ∈ { :decl, :mutable_decl, :reassign }`

The template body is `temp = <kind>; <use temp inside iteration>;`
and the assertion is "loop runs, checker doesn't fire FRAME_NO_REWIND,
program exits 0."

---

## Bug #3 / #8 — `expr OR fallback` doesn't stop fallibility propagation

**Symptom**: a function whose body uses `expr OR fallback` (`charAt(i) OR ""`)
gets rejected with `Function 'X' can fail (raises directly via RAISE) but its return type doesn't declare it`.
The function contains zero literal `RAISE` statements.

### Pipeline stage: error message is wrong, fallibility model is by design

[`src/annotator.rb:779`](../../src/annotator.rb):

```ruby
@fn_raises_directly[node.name] =
  node.uses_frame || node.uses_heap || node.uses_alloc || heap_ret ||
  (@fn_has_fnptr[node.name] == true) ||
  (node.reentrant == :non_reentrant) ||
  (node.respond_to?(:pre_clauses) && node.pre_clauses && node.pre_clauses.any?) ||
  scan_for_raises(node.body)
```

Any function that allocates anything (frame, heap, alloc) has
`@fn_raises_directly[name] = true`. That flag drives the
`enforce_fallible_returns!` post-pass. So a function with
`ascii = "ABC..."` (a frame string allocation) is "fallible" even
without any `RAISE`.

The CLEAR design model: allocation can OOM, OOM unwinds via the
runtime, so the function legitimately has a failure path. The user's
expectation that `OR ""` neutralises the failure is correct for the
specific *expression's* fallibility, but not for the *containing
function's*.

**Per the model, this is not a bug.** The function really is fallible
in CLEAR's runtime model.

**The actual bug is in the error message.**
[`src/annotator-helpers/effects.rb:562`](../../src/annotator-helpers/effects.rb):

```ruby
def fallibility_hint_for(name)
  return "raises directly via RAISE" if @fn_raises_directly[name]
  ...
end
```

`@fn_raises_directly` is a misnomer — it's "this function is a
direct source of fallibility for any reason," not "this function
contains a literal RAISE." The hint always says "RAISE" even when
the cause is allocation. User reads the message, scans the body,
finds no `RAISE`, concludes the compiler is wrong.

**Fix**: split the hint to report the actual cause. If
`scan_for_raises(node.body)` is true, "raises directly via RAISE."
Otherwise: "allocates (can fail with OOM)," "calls function pointer
(can fail)," "uses pre-clauses (can fail)," etc. The information is
already in `effects.rb`; it's just not threaded into the hint.

### MIR Checker side

Nothing to change. The fallibility analysis runs in the annotator,
before MIR. No checker invariant applies.

### Fuzz template: none cover this shape either

`or_positional` tests OR fallback semantics at the call site, not
the containing function's signature. A template
`fallibility_inference` would cross:

- `body_kind ∈ { :literal_alloc, :explicit_raise, :calls_fallible,
                  :pure_int_math, :string_concat, :heap_return }`
- `caller_kind ∈ { :wrapped_with_or, :unwrapped_with_or, :propagates }`

For each cell, assert: the function's inferred fallibility matches the
table. Mismatch is a finding. Once the message-clarity fix lands, the
hint string in each error message should match the cell's expected
cause.

---

## Summary

| Bug | Pipeline stage | MIR / Checker invariant | Fuzz template gap |
| --- | --- | --- | --- |
| #1 hoister | `MIRLowering.lower_if` (and lower_while/match) doesn't isolate cond's `@pending_stmts` | Use-before-decl on `MIR::Ident` references (new invariant) | `or_positional` missing `:if_cond`/`:while_cond`/`:match_subject` |
| #2 frame rewind | `LoopFrameAnalysis.local_frame_decls` doesn't recognise the decl's type as frame-provenance array — root in annotator/type-resolution propagation | `INV-FRAME-REWIND` already fires correctly; this is a lowering-synthesis gap | No template; new `loop_local_method_temp` needed |
| #3/#8 fallibility | `fallibility_hint_for` lies about WHY (`@fn_raises_directly` covers alloc too) | None — fallibility model is correct by design | No template; new `fallibility_inference` needed |

The pattern is the same in all three (and in bug #9): **the docstring of
a template promises a class, but the matrix's axes don't span the cases
that hit the gap.** Combined with the MIR pipeline's "decide vs. verify"
split, the test surface has structural blind spots that are bug-shaped.

Each forensic concludes with a specific minimal next step:

- #1: add `:if_cond` to `or_positional`; fix `lower_if`'s pending flush.
- #2: instrument `local_frame_decls` to find which filter rejects `parts`; add `loop_local_method_temp` template once the cause is known.
- #3/#8: split `fallibility_hint_for` to report alloc vs. raise; add `fallibility_inference` template.
