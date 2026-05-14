# The V8 Implementation - Refs and Arrays

V8 adds **heap-backed mutable storage**: a way for callees to mutate the caller's variables (`VAR` parameters), and a way to hold a fixed-size collection of cells (`ARRAY`). Both lean on the V5 heap and refcount machinery — same `HeapRef`, same `retain`/`release`.

Three new bytecode ops, two new pieces of syntax. The VM grows; the parser grows a little; the compiler does one new pre-pass.

---

## The Program

See [example.puck](example.puck) for the full source. The two new shapes:

```pascal
PROCEDURE swap(VAR a, VAR b);
  t := a;
  a := b;
  b := t;
END;

squares := ARRAY(5);
squares[i] := i * i;
n := squares[i];
```

Output (after running `swap(x, y)` where `x := 1; y := 2`, then writing and reading the `squares` array):

```text
1
2
2
1
0
1
4
9
16
```

Run it directly:

```bash
ruby examples/puck/v8/vm.rb
```

Or in the visualizer:

```bash
ruby examples/puck/run.rb v8
```

---

## What a REF Actually Is

A primitive variable normally lives in a memory slot:

```text
M00: 1      # plain Integer in slot 0
```

A `VAR` parameter lives **on the heap, indirected through a ref**:

```text
M00: H00 -> [1]    # slot 0 holds a ref; heap entry 0 holds the value
```

That's the only difference. The heap entry is a one-cell array (`[1]`); the slot holds a `HeapRef` pointing at it. Reading the variable becomes "dereference the ref, return the cell's value." Writing becomes "dereference the ref, replace the cell's value."

That's also the only difference between a REF and the strings V5 introduced. The heap was already there. We just changed what we keep in it: V5 kept string bytes, V8 also keeps **mutable cells**.

---

## The Three New Ops

| Op | What it does |
|---|---|
| `ALLOC_CELL` | Pop a value; allocate a heap entry with payload `[value]`; push a ref to it. Same `refcount=1` as `:ALLOC`. |
| `LOAD_REF slot` | `memory[slot]` is a ref. Push `heap[ref.id].value[0]` (the cell's value). Retain if that value is itself a ref. |
| `STORE_REF slot` | `memory[slot]` is a ref. Pop a value; write through the ref into the cell. Release the old payload. The ref itself doesn't change. |

Arrays reuse the same heap shape. The payload is just a longer array of cells:

| Op | What it does |
|---|---|
| `ALLOC_ARRAY` | Pop a size N. Allocate a heap entry with payload `[0, 0, ..., 0]` (N cells). Push a ref. |
| `ARRAY_GET` | Pop index, pop ref. Push `heap[ref.id].value[index]` (retained). |
| `ARRAY_SET` | Pop value, index, ref. Write `heap[ref.id].value[index] = value` (releasing the old slot). |

A REF cell is just an array of size 1. The two `ALLOC_*` ops are mechanically the same; we give them different names so the bytecode reads clearly.

`release` now has to recurse into array payloads — once a cell or array hits `refs=0`, anything stored *inside* it has to be released too:

```ruby
def release(value)
  return unless value.is_a?(HeapRef)
  @heap[value.id].refs -= 1
  if @heap[value.id].refs.zero?
    payload = @heap[value.id].value
    payload.each { |v| release(v) } if payload.is_a?(Array)
    @heap[value.id] = nil
  end
end
```

V5 didn't need the recursion because strings don't hold refs. V8 does.

---

## Compiling `VAR`

Two new pieces the compiler has to figure out:

1. **Which slots in this scope are boxed?** Every `VAR` parameter is obviously boxed (the caller passed a ref into that slot). And any *local* variable that's later passed to a procedure as a `VAR` argument has to be boxed too — otherwise the callee would mutate a temporary on the stack rather than the caller's variable.
2. **For each variable access, emit the right pair of ops:** `LOAD`/`STORE` for plain slots, `LOAD_REF`/`STORE_REF` for boxed ones.

A pre-pass over each scope's body walks every `CallStatement` and `Call`, looks up the callee's `var_params`, and records the names that get VAR-passed. Those names become the scope's boxed set.

At the top of every procedure body, the compiler emits a small prelude that allocates a heap cell for each boxed local (params don't need this — their cells already exist in the caller):

```text
PUSH 0
ALLOC_CELL
STORE <slot>
```

After that prelude, the rest of the body compiles normally. Every reference to a boxed name picks `LOAD_REF`/`STORE_REF` instead of `LOAD`/`STORE`.

### Procedure call sites

A `VAR` argument has to be a bare variable — you can't pass `x + 1` by reference. At the call site, the compiler emits `LOAD <slot>` for that arg (no dereference), so the **ref itself** goes onto the stack. The callee sees the ref in its own memory slot and accesses it via `LOAD_REF`/`STORE_REF`. After the callee returns, the caller's slot still holds the ref, and the cell behind it now reflects whatever the callee wrote.

For non-VAR args, the compiler compiles the expression normally (which dereferences any boxed names it touches).

---

## Walking `swap`

The program does:

```pascal
x := 1;
y := 2;
swap(x, y);
```

In `main`, `x` and `y` are boxed because `swap` declares both params as `VAR`. The pre-pass sees `swap(x, y)` and records `x` and `y` as boxed names.

Main's prelude:

```text
PUSH 0; ALLOC_CELL; STORE 0    # x's cell
PUSH 0; ALLOC_CELL; STORE 1    # y's cell
```

`x := 1` and `y := 2` are STORE_REF (write through the cells):

```text
PUSH 1
STORE_REF 0     # x cell now holds [1]
PUSH 2
STORE_REF 1     # y cell now holds [2]
```

`swap(x, y)` — VAR args, push refs:

```text
LOAD 0          # push x's ref onto the stack
LOAD 1          # push y's ref onto the stack
CALL swap
```

`swap` runs with `memory = [x_ref, y_ref]`. Body:

```text
LOAD_REF 0      # push x cell's value (1)
STORE 2         # t := 1 (t is unboxed local)
LOAD_REF 1      # push y cell's value (2)
STORE_REF 0     # write 2 into x's cell
LOAD 2          # push t (1)
STORE_REF 1     # write 1 into y's cell
```

After return, main reads `x` and `y` via `LOAD_REF` and sees `2` and `1`.

---

## Why the heap entry holds an Array

The cell `[1]` is a Ruby array of length 1 in the VM's heap. Arrays from `ARRAY(N)` are arrays of length N. Same struct, same `retain`/`release`, same id-to-entry indexing.

That uniformity is the whole point of doing REFs and arrays in the same version. A REF is an array of one cell. An array is a REF with more cells. The bytecode ops differ slightly (`LOAD_REF` always touches `value[0]`; `ARRAY_GET` takes an index off the stack), but the heap shape is one thing.

---

## What V8 Adds Up To

After V8, Puck has enough machinery to express its own standard library: integer math + strings + heap-backed mutable cells + indexed collections. The next version's job is to start writing useful procedures *in Puck* — string equals, concat, substring, int↔string — rather than baking more into the VM. The VM is essentially done.
