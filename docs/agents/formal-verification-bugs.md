# Formal-Verification Bugs

Tracker for bugs surfaced by `tools/fuzz/`. Each entry includes:
- Where it was found (template + cell params)
- Repro snippet
- Status (open / fixed elsewhere / docs gap)
- Workarounds the fuzz emitter has taken to keep cells viable

The branch policy is **find, don't fix** — bugs land here so they can be
addressed elsewhere. Workarounds in the matrix templates are tagged in
each template's comments so they can be removed when the underlying bug
is fixed.

## Active bugs

### 1. `RETURN COPY alias` lowers to `*T` for EXCLUSIVE / RESTRICT / SNAPSHOT

**Found by**: `access_gate` template (4 cells)
- `(exclusive, locked, baseline_copy_return)`
- `(exclusive, write_locked, baseline_copy_return)`
- `(restrict, plain, baseline_copy_return)`
- `(snapshot, versioned, baseline_copy_return)`

**BORROWED's `RETURN COPY ref` works correctly** — only the four above fail.

**Repro**:
```clear
FN extract() RETURNS !Counter ->
    MUTABLE c = Counter{ value: 1_i64 } @locked;
    WITH EXCLUSIVE c AS ref { RETURN COPY ref; }
END
```

**Symptom**: Zig codegen
```
error: expected type 'error_union ... !T', found '*T'
```

**Why the unit specs miss it**: `spec/with_alias_escape_spec.rb` "allows
RETURN COPY of an EXCLUSIVE alias" stops at annotation; never compiles
to Zig.

### 2. BG handle capturing `@local` can RETURN / be stored in heap field

**Found by**: `lifetimed_return` template (2 UNEXPECTED-PASS cells)

**Repro** (compile passes; runtime SIGABRT):
```clear
FN spawn() RETURNS ~Int64 ->
    MUTABLE c = Counter{ value: 0_i64 } @local;
    RETURN BG { c.value; };
END

FN main() RETURNS Void ->
    bg = spawn();
    r: Int64 = NEXT bg;
END
```

**Why it matters**: `bg_lifetime_sources` (annotator.rb:6449) stamps the
lifetime correctly, but enforcement on `RETURN bg` and `outer.field = bg`
isn't wired through. Compiler accepts; runtime crashes when the BG runs
against the freed `@local` source.

**`bg_stream` correctly rejects both patterns** — the gap is BG-specific.

### 3. `(bg_stream, @local, COPY, String)` — heap addresses leak

**Found by**: `stream_into_boundary` template

**Repro** (passes ASSERT; reports leaked memory):
```clear
src: ~String[INF] = BG STREAM { ... YIELD i.toString(); ... };
val: String = NEXT src;
inner: ~Int64[INF] = BG STREAM {
    WHILE TRUE DO
        c = COPY val; YIELD c.length();
        ...
    END
};
NEXT inner; NEXT inner;
```

`[DebugAllocator]` reports 6 leaked heap addresses per run. Likely the
COPY of an outer-scope String inside a `WHILE TRUE` BG-STREAM body
doesn't pair with a cleanup when the main scope ends.

### 4. `@local` is admitted as concrete-param caller

**Found by**: `polymorphic_sync_admission` (1 UNEXPECTED-PASS)
- `(callee=:concrete, caller=:local)`

A function declared `FN tick!(MUTABLE c: Counter)` (no REQUIRES) accepts
a `@local` argument. Per `docs/sharing-capabilities.md` concrete params
should accept plain `T` only. This is the canonical viralization-risk
surface from the `@local` design discussion — `@local` is structurally
a `*T` so admission rules conflate it with plain locals.

**Design question**: should this be tightened (admission stricter), or
documented as intentional (concrete admits `@local` because it's
identity-compatible)?

### 5. `SHARED T` rejects `@locked` / `@writeLocked` / `@versioned` short forms

**Found by**: `polymorphic_sync_admission` (3 MIR-FAIL cells)

**Repro**:
```clear
FN tick!(MUTABLE c: SHARED Counter) RETURNS Void ->
    WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1_i64; }
END

FN main() RETURNS Void ->
    c = Counter{ value: 0_i64 } @locked;   # short form
    tick!(c);
END
```

**Symptom**:
```
[Compiler Error] Type Error: Argument 1 to 'tick!' expects Counter @shared,
                got Counter. Use SHARE c to create a shared handle.
```

`@locked` (short form) doesn't auto-coerce to `@shared:locked` at call
sites with a SHARED-typed param. `transpile-tests/349_polymorphic_transaction_acceptance.cht`
uses the explicit `@shared:locked` form throughout to avoid this.

### 6. `WITH MATCH` syntax not parsed

**Found by**: `polymorphic_sync_admission` (5 MIR-FAIL cells, all
`:req_locked_or_local`)

**Repro**:
```clear
WITH MATCH c
    WHEN @locked -> EXCLUSIVE c AS x { x.value = x.value + 1_i64; }
    WHEN @local  -> c.value = c.value + 1_i64;
END
```

**Symptom**: `[Parser Error] Unknown WITH capability 'MATCH'`

CLAUDE.md describes the syntax. Parser hasn't shipped it yet.

### 7. Codegen failures for some legitimately-admitted polymorphic cells

**Found by**: `polymorphic_sync_admission` (4 MIR-FAIL cells)
- `(req_locked, @locked)` — `@hasField` deref issue
- `(req_locked, @writeLocked)` — same
- `(req_versioned, @versioned)` — `*Versioned` method-invocation
- `(req_local, @local)` — error union ignored

These are all (REQUIRES family + matching short-form caller). The full
explicit form (`@shared:locked` / `@shared:versioned`) used in
transpile-tests/349 works; the short forms trip a different lowering
path that isn't fully wired.

### 8. DO branches don't capture outer `@local` / `@multiowned` bindings

**Found by**: `execution_boundary` (4 cells), `stream_into_boundary`
(several cells), and earlier `nested_loop_escape` work.

DO branches lower to inner Zig fns that don't close over enclosing
locals. Existing test corpus only uses DO with `@shared:locked` state.

**Symptom (Zig)**: `error: 'val' not accessible from inner function`

**Question**: should DO learn to capture `@local` (auto-pin both
branches to same scheduler), or should this be a documented limitation
(DO requires `@shared`)?

### 9. BG STREAM doesn't accept `@parallel` / `@pinned` modifier sigils

**Found by**: `execution_boundary` (4 cells)

**Repro** (parser error):
```clear
s: ~Int64[INF] = BG STREAM {
    @parallel -> WHILE TRUE DO YIELD c.value; END
};
```

**Symptom**: `[Parser Error] Expected ;, got -> (ARROW)`

The BG STREAM parser has no equivalent of `parse_bg_prefix` — modifier
sigils inside the stream body don't parse. **Inconsistent with BG**,
which accepts the same syntax.

### 10. `expr OR <action>` cleanup pairing is broken across most positions

**Found by**: `loop_cleanup` (initially), `or_positional` (full surface)

**Initial repro** (assignment RHS):
```clear
FN run() RETURNS !Int64[]@list ->
    MUTABLE outer: Int64[]@list = [];
    outer.append(1_i64);
    RETURN outer;
END

FN main() RETURNS Void ->
    result = run() OR PASS;
    RETURN;
END
```
Symptom: `1 tests leaked memory.`

**Full surface** from `or_positional` matrix (60 cells, 45 fail):

| Position × outcome=success | Result |
|---|---|
| `result = inner() OR PASS` | LEAK (heap_list, heap_string) |
| `result = inner() OR RAISE` | LEAK |
| `result = inner() OR <default>` | LEAK |
| `outer.append(inner() OR …)` | LEAK (heap_string), MIR-FAIL (heap_list) |
| `RETURN inner() OR …` | LEAK or MIR-FAIL depending on action/type |
| `WITH (inner() OR …) AS x { … }` | MIR-FAIL universally (10 cells) |
| `[inner() OR …]` (collection lit) | mixed, mostly OK on heap_list |
| `consume(inner() OR …)` (fn arg) | mostly OK; one runtime FAIL |

The bug isn't just `OR PASS` — `OR RAISE`, `OR <default>` all exhibit
similar cleanup-pairing failures depending on syntactic position. The
inner value's allocation isn't paired with a cleanup defer at the OR
expression's binding site (or doesn't propagate through the chosen OR
lowering path).

**Root cause hypothesis**: each `OR <action>` lowering path has its
own cleanup logic, and the pairing is position-specific — so the bug
surface is wider than the assignment-RHS case that originally triggered
it.

**Cells that pass**: `:fn_arg + :pass/:default + :success` (heap_list
and heap_string both work). And cells where the inner raises and the OR
is a `pass`/`default` for some positions.

The 15 passing cells of 60 don't form an obvious pattern — the failure
is systemic across positions, not localized to one path.

## Workarounds the fuzz templates have taken

Each is tagged in the relevant template's comments. Tracked here so
they can be removed when the underlying bug is fixed.

| Template | Workaround | For bug |
|---|---|---|
| All templates returning a value out of WITH | `RETURNS !T` (not bare `T`) | `WITH EXCLUSIVE` etc. can fail; bare return type doesn't compile |
| `lifetimed_return` | `:atomic_int`, `:locked` ownership cells marked `:in_dev` | BG body capture of `@shared:atomic` / `@locked` doesn't auto-unwrap |
| `stream_into_boundary` phase B | `:in_dev` for atomic + clone, all CLONE on sync-wrapped values | CLONE of bare Atomic / sync-wrapped struct unsupported |
| `stream_into_boundary` | DO + @shared cells marked `:compile_error` | DO branches don't capture outer @shared bindings |
| `access_gate` | `MUTABLE c =` everywhere (not just RESTRICT cells) | Some baseline cells don't compile with immutable source |
| `access_gate` | `RETURNS !T` for any fn containing WITH | WITH blocks are fallible |
| `access_gate` | dropped `!~T` syntax (`RETURNS !~Int64` → `RETURNS ~Int64`) | `!` and `~` don't combine in return type |
| `polymorphic_sync_admission` | Most callees `RETURNS Void` (not `!Void`) | Bare Void avoids "error union ignored" caller errors |
| `loop_cleanup` | `OR PASS` instead of `OR RAISE` for caller | (a) raise re-propagates and exits the test non-zero; (b) `... OR PASS` itself appears to leak (#10) |
| All DO templates | Per-branch unique binding names (`c1`, `c2`) | DO branches share scope; reusing a name causes immutable-rebind error |

## Fixed elsewhere (informational)

These were surfaced by the matrix and addressed in the parallel branch:

- (placeholder — log them here as you confirm fixes land)

## Spec-level gaps the matrix highlights

- `spec/with_alias_escape_spec.rb` "allows RETURN COPY of an EXCLUSIVE
  alias" — verifies annotation, not codegen. Bug #1 slipped through
  because the spec stops short of compiling Zig.
- `spec/bg_handle_lifetime_spec.rb:11-15` explicitly notes it tests
  the **stamp**, deferring enforcement checks ("M2.6 audit-matrix
  work"). Bug #2 is exactly that audit-matrix gap.
- Existing polymorphic-sync specs (`polymorphic_transaction_acceptance_spec.rb`,
  `sync_polymorphism_integration_spec.rb`) use `@shared:locked` full
  form throughout. Bugs #5 and #7 only surface when calling with the
  `@locked` short form, which the matrix exercises and the unit specs
  don't.
