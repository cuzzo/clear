# BORROWED T Lockdown Plan

## Goal

`WITH BORROWED x AS ref` should guarantee: **ref is a read-only alias, valid exactly for the
duration of the block, that cannot escape or alias shared/mutable state.** Currently the
implementation has three gaps where the guarantee is violated. This document defines the
tests and fixes to close each gap.

---

## Current Enforcement (What Works Today)

`non_escaping = true` is set on every alias binding created by `WITH BORROWED` and `WITH RESTRICT`.
The annotator checks this flag at four sites:

| Site | File | What it blocks |
|---|---|---|
| `ensure_owned_value!` | `annotator.rb:2637` | Storing ref into a struct field at construction, or a union variant, or a TAKES param |
| `handle_assign_move` | `annotator.rb:3173` | Moving/assigning a non-Copy ref to another variable |
| `verify_function_signature!` (TAKES path) | `function_analysis.rb:332` | Passing ref to a TAKES parameter (ownership transfer) |
| `visit_ReturnNode` (coarse) | `annotator.rb:1275` | RETURN anywhere inside a WITH block (`@with_block_depth > 0`) |

---

## Gap 1: BG/DO/STREAM Blocks Can Capture BORROWED Bindings

### Why it is dangerous

A fiber's lifetime is independent of the stack frame that created it. A BG block that
captures a `WITH BORROWED` alias keeps a stack pointer alive after the WITH block exits
and the frame is potentially rewound. This is a stack use-after-free.

```ruby clear
-- DANGEROUS: ref is a stack alias; the BG fiber may outlive the WITH block
name = "hello";
WITH BORROWED name AS ref {
    task = BG { ref.length() };   -- ref escapes into fiber -- SHOULD BE ERROR
}
AWAIT task;
```

### Current behavior

`_unified_capture_walk` (`capabilities.rb:310`) records all outer-scope identifiers captured
by a fiber body. It checks `.sync`, `.storage`, and `.type` but **never checks `.non_escaping`**.
The BG block annotates and transpiles successfully, capturing a dangling stack pointer.

### Proof test (should fail today, must fail after fix)

Add to `spec/borrow_checker_spec.rb` or a new `spec/borrowed_escape_spec.rb`:

```ruby
describe "BG capture of BORROWED binding is rejected" do
  def expect_error(src, msg_fragment)
    expect { annotate(src) }.to raise_error(SemanticError, /#{msg_fragment}/)
  end

  it "BG block cannot capture a WITH BORROWED alias" do
    expect_error(<<~CLEAR, /cannot capture.*borrowed\|BORROWED.*escape\|non.escaping.*BG/i)
      FN main() RETURNS Void ->
        name = "hello";
        WITH BORROWED name AS ref {
          task = BG { ref.length() };
        }
        RETURN;
      END
    CLEAR
  end

  it "DO block cannot capture a WITH BORROWED alias" do
    expect_error(<<~CLEAR, /cannot capture.*borrowed\|BORROWED.*escape\|non.escaping.*DO/i)
      FN main() RETURNS Void ->
        name = "hello";
        WITH BORROWED name AS ref {
          DO { ref.length() } END
        }
        RETURN;
      END
    CLEAR
  end

  it "BG STREAM block cannot capture a WITH BORROWED alias" do
    expect_error(<<~CLEAR, /cannot capture.*borrowed\|BORROWED.*escape/i)
      FN main() RETURNS Void ->
        name = "hello";
        WITH BORROWED name AS ref {
          s = BG STREAM { YIELD ref.length() };
        }
        RETURN;
      END
    CLEAR
  end

  it "nested BG inside non-BG function is also blocked" do
    expect_error(<<~CLEAR, /cannot capture.*borrowed\|non.escaping/i)
      FN makeTask(BORROWED s: String) RETURNS ~Int64 ->
        RETURN BG { s.length() };
      END
    CLEAR
  end
end
```

### Fix

**File:** `src/annotator-helpers/capabilities.rb`

**Step 1:** Add `has_non_escaping_capture` field to `CaptureAnalysis`:

```ruby
CaptureAnalysis = Struct.new(
  :has_local,
  :has_rc,
  :has_shared,
  :has_sharded,
  :has_affine_locked,
  :has_outer_ref,
  :has_non_escaping_capture,   # ADD: captures a non_escaping (BORROWED/RESTRICT) binding
  :captures,
  :close_patterns,
  :pointer_captures,
  :string_captures,
  :resource_captures,
  keyword_init: true
)
```

Update `analyze_fiber_captures` to initialize the new field to `false`.

**Step 2:** In `_unified_capture_walk`, inside the `AST::Identifier` branch where
`info = current_scope.locals[name]` is accessed, add:

```ruby
result.has_non_escaping_capture = true if info.non_escaping
```

**Step 3:** In `visit_BgBlock` (`annotator.rb`), after `full_analysis = analyze_fiber_captures(...)`:

```ruby
if full_analysis.has_non_escaping_capture
  error!(node, "BG block captures a WITH-scoped (BORROWED/RESTRICT) binding. " \
               "WITH bindings cannot escape into fibers — they are stack aliases " \
               "that become invalid when the WITH block exits.")
end
```

Apply the same check in `visit_DoBlock` and `visit_BgStreamBlock`.

---

## Gap 2: BORROWED Permitted on @shared, @locked, multiowned Types

### Why it is dangerous

`WITH BORROWED x AS ref` is documented as: *"the data is stable for the duration of the
borrow."* For `@shared` (Arc) and `@locked` types, the data lives on the heap and can be
written by other fibers concurrently. The `non_escaping` alias is a const reference, so ref
itself cannot be returned or stored, but any read through ref may observe stale or partially
written state. This violates the stability contract and misleads the programmer.

```ruby clear
counter: @locked Int64 = 0;
WITH BORROWED counter AS ref {
    -- ref is "stable" per BORROWED semantics
    -- but another fiber can write counter.value between these two lines
    a = ref;      -- reads value N
    b = ref;      -- may read value N+1 (another fiber incremented)
}
```

For `@multiowned` (Rc), the data is not thread-shared but mutation is possible via other
Rc handles. BORROWED implying "stable" is semantically wrong here too.

### Current behavior

`declare_capability_scope!` (`capabilities.rb:225-231`) for BORROWED:

```ruby
elsif cap[:capability] == :BORROWED
  alias_name = cap[:alias] || var_name
  resolved_type = ...
  current_scope.declare(alias_name, nil, resolved_type, false, false, nil, :stack)
  current_scope.locals[alias_name].non_escaping = true
  og_declare(alias_name, nil, resolved_type)
  @og.borrow("__borrowed_#{var_name}", var_name, mutable: false)
end
```

No check on the source variable's sync or storage.

### Proof test

```ruby
describe "BORROWED rejected on shared/synchronized types" do
  it "cannot BORROWED a @shared variable" do
    expect_error(<<~CLEAR, /BORROWED.*shared\|shared.*BORROWED\|cannot borrow.*@shared/i)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c: Counter = Counter{ value: 0 } @shared;
        WITH BORROWED c AS ref {
          n = ref.value;
        }
        RETURN;
      END
    CLEAR
  end

  it "cannot BORROWED a @locked variable" do
    expect_error(<<~CLEAR, /BORROWED.*locked\|locked.*BORROWED\|cannot borrow.*@locked/i)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c: Counter = Counter{ value: 0 } @locked;
        WITH BORROWED c AS ref {
          n = ref.value;
        }
        RETURN;
      END
    CLEAR
  end

  it "cannot BORROWED a @multiowned variable" do
    expect_error(<<~CLEAR, /BORROWED.*multiowned\|cannot borrow.*@multiowned/i)
      STRUCT Node { value: Int64 }
      FN main() RETURNS Void ->
        n: %Node = Node{ value: 1 } @multiowned;
        WITH BORROWED n AS ref {
          x = ref.value;
        }
        RETURN;
      END
    CLEAR
  end

  it "plain struct can still be BORROWED (no regression)" do
    expect_no_error(<<~CLEAR)
      STRUCT Point { x: Float64 }
      FN main() RETURNS Void ->
        p = Point{ x: 1.0 };
        WITH BORROWED p AS ref {
          n = ref.x;
        }
        RETURN;
      END
    CLEAR
  end
end
```

### Fix

**File:** `src/annotator-helpers/capabilities.rb`

In `declare_capability_scope!`, at the start of the `cap[:capability] == :BORROWED` branch,
look up the source variable's symbol and check its storage/sync:

```ruby
elsif cap[:capability] == :BORROWED
  source_sym = cap[:old_scope]&.locals&.[](var_name)
  if source_sym
    bad = source_sym.storage == :shared || source_sym.storage == :multiowned ||
          source_sym.sync == :locked || source_sym.sync == :write_locked
    if bad
      capability_str = [
        source_sym.storage == :shared ? "@shared" : nil,
        source_sym.storage == :multiowned ? "@multiowned" : nil,
        source_sym.sync == :locked ? "@locked" : nil,
        source_sym.sync == :write_locked ? "@writeLocked" : nil
      ].compact.first
      error!(cap[:var_node], "Cannot use WITH BORROWED on #{capability_str} variable '#{var_name}'. " \
                              "BORROWED guarantees stability, but #{capability_str} data can be " \
                              "modified concurrently. Use WITH #{var_name} { } to lock/access it instead.")
    end
  end
  # ... existing declaration code ...
```

---

## Gap 3: Field Mutation Bypasses Non-Escaping Check

### Why it is dangerous

`ensure_owned_value!` catches non_escaping values stored into struct fields at construction
time (struct literal). It does NOT run for post-construction field mutation (`s.field! = ref`).
This means a non_escaping alias can be stored into a field of a struct that outlives the
WITH block.

```ruby clear
STRUCT Holder { data: String }
MUTABLE h = Holder{ data: "original" };
name = "hello";
WITH BORROWED name AS ref {
    h.data! = ref;   -- SHOULD BE ERROR: ref is non_escaping, h.data outlives WITH block
}
-- h.data now points to stack memory that may be overwritten
print(h.data);  -- use-after-free
```

### Current behavior

`visit_assignment_field` (`annotator.rb:1857`) calls `visit(field_node)`, checks mutability,
calls `validate_assignment_type` for the type check. It never inspects `non_escaping` on the
value node (`assignment_node.value`).

### Proof test

```ruby
describe "field mutation rejects non_escaping values" do
  it "cannot assign BORROWED alias into a struct field" do
    expect_error(<<~CLEAR, /non.escaping\|WITH.scoped\|cannot store.*BORROWED/i)
      STRUCT Holder { data: String }
      FN main() RETURNS Void ->
        MUTABLE h = Holder{ data: "original" };
        name = "hello";
        WITH BORROWED name AS ref {
          h.data! = ref;
        }
        RETURN;
      END
    CLEAR
  end

  it "cannot assign BORROWED struct into a field" do
    expect_error(<<~CLEAR, /non.escaping\|WITH.scoped\|cannot store/i)
      STRUCT Inner { x: Int64 }
      STRUCT Outer { inner: Inner }
      FN main() RETURNS Void ->
        MUTABLE o = Outer{ inner: Inner{ x: 1 } };
        inner = Inner{ x: 2 };
        WITH BORROWED inner AS ref {
          o.inner! = ref;
        }
        RETURN;
      END
    CLEAR
  end

  it "Copy-type field assignment of borrowed Copy value is still allowed" do
    -- Int64 is Copy; no ownership transfer happens; safe
    expect_no_error(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        MUTABLE c = Counter{ value: 0 };
        n = 42;
        WITH BORROWED n AS ref {
          c.value! = ref;
        }
        RETURN;
      END
    CLEAR
  end
end
```

Note: the last test (Copy types) should NOT be blocked. `Int64` is copyable - the field
assignment copies the value, not a pointer. Only non-Copy types create a lifetime hazard.

### Fix

**File:** `src/annotator.rb`

In `visit_assignment_field`, after `visit(field_node)` and before the type check:

```ruby
# Non-escaping values (BORROWED/RESTRICT aliases) cannot be stored in fields.
# ensure_owned_value! catches struct-literal construction; this catches mutation.
val = assignment_node.value
if val.is_a?(AST::Identifier) && val.symbol&.non_escaping
  vti = val.type_info
  schema_resolver = ->(t) { lookup_type_schema(t) rescue nil }
  is_copy = vti && (Type.new(vti).implicitly_copyable?(schema_resolver) ||
                    Type.new(vti).copyable?(schema_resolver)) rescue false
  unless is_copy
    error!(assignment_node, "Cannot store WITH-scoped '#{val.name}' into a struct field. " \
                             "WITH bindings cannot escape their block.")
  end
end
```

---

## Completeness: What Remains Allowed (Intentionally)

After these three fixes, the following uses of BORROWED aliases remain valid:

| Use | Safe? | Reason |
|---|---|---|
| `n = ref.length()` (method call, no TAKES) | Yes | Read-only use; result is a scalar copy |
| `print(ref)` (non-TAKES param) | Yes | Function reads but does not own |
| `ASSERT ref == "x"` | Yes | Value comparison; no ownership |
| `x = ref.field` where field is Copy | Yes | Field access copies a scalar |
| `MUTABLE iter = Struct{ source: ref, ... }` | Blocked | struct construction - caught by `ensure_owned_value!` |
| `RETURN ref` | Blocked | `@with_block_depth > 0` |
| `task = BG { ref.length() }` | Blocked (after fix) | Gap 1 |
| `WITH BORROWED (@shared x) AS ref` | Blocked (after fix) | Gap 2 |
| `s.field! = ref` (non-Copy) | Blocked (after fix) | Gap 3 |

---

## Implementation Order

1. **Gap 1 (BG capture)** - highest UAF risk; most impact. Add `has_non_escaping_capture`
   to `CaptureAnalysis`, set in `_unified_capture_walk`, check in all three fiber visitors.
   ~1 day.

2. **Gap 2 (@shared borrow)** - semantic correctness; low code risk. Add source type check
   in `declare_capability_scope!`. ~0.5 days.

3. **Gap 3 (field mutation)** - narrower scope; Copy-type carve-out adds a bit of care.
   Add non_escaping check in `visit_assignment_field`. ~0.5 days.

**Total estimate: ~2 days.** Run `bundle exec prspec spec/` and
`./clear test transpile-tests/` after each gap is closed.

---

## Transpile Tests to Add

After all three fixes, add two transpile tests to verify end-to-end correctness:

**`transpile-tests/237_borrowed_valid_uses.cht`** - comprehensive positive test: all currently
valid patterns from the "remains allowed" table above should compile and run cleanly with no
memory leaks.

**`transpile-tests/238_borrowed_field_borrow.cht`** - iterate a struct with a BORROWED field,
verify the iterator pattern from test 185 still compiles and runs. Regression guard.

These are in addition to the annotator-level specs that verify each error fires at compile
time. The transpile tests verify that the positive path (valid BORROWED use) is not broken
by the fixes.
