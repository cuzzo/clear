# The V5 Implementation - Strings, Refs, and Refcounting

V4 made control flow concrete with jumps and patching.

V5 adds the first value that is not just an immediate integer or boolean: a string.

That changes the VM model. Integers can live directly on the stack or in memory:

```text
042
```

Strings are stored in a tiny VM heap, and the stack/memory hold references:

```text
S00 -> "hello"
```

Once more than one place can point at the same value, the VM needs to know when the value is no longer used. V5 uses simple reference counting.

---

## The Program

The demo program in [example.puck](example.puck) prints a string, overwrites the variable with another string, and prints again:

```pascal
message := "hello";
SYSCALL(1, message);

message := "forty-two";
SYSCALL(1, message);
```

Run it directly:

```bash
ruby examples/puck/v5/vm.rb
```

Or run it in the visualizer:

```bash
ruby examples/puck/run.rb v5
```

Output:

```text
OUTPUT: hello
OUTPUT: forty-two
```

---

## What Changed

The tokenizer now recognizes string literals:

```ruby
tokens << Token.new(:STRING, match[1...-1])
```

The parser turns them into expression nodes:

```ruby
ExprNode.new(type: :String, value: consume(:STRING).value)
```

The compiler emits a new bytecode instruction whose argument is the literal string:

```text
ALLOC "hello"
```

The VM allocates the string in the heap and pushes a reference:

```text
S00 refs=1 "hello"
```

---

## The Refcount Walkthrough

Start with:

```pascal
message := "hello";
```

The compiler emits:

```text
ALLOC "hello"
STORE 0
```

`ALLOC` allocates the first heap object:

```text
STACK      MEMORY      HEAP
S00        M00: xxx    S00 refs=1 "hello"
```

`STORE 0` moves that ref into memory:

```text
STACK      MEMORY      HEAP
xxx        M00: S00    S00 refs=1 "hello"
```

Now `SYSCALL(1, message);` compiles to:

```text
LOAD 0
SYSCALL 1
```

`LOAD 0` copies the ref from memory to the stack, so it must retain:

```text
STACK      MEMORY      HEAP
S00        M00: S00    S00 refs=2 "hello"
```

`SYSCALL 1` pops the stack ref and releases it:

```text
STACK      MEMORY      HEAP
xxx        M00: S00    S00 refs=1 "hello"
```

The string still exists because memory still owns one reference.

---

## Why Reassignment Matters

The key v5 moment is overwriting the variable:

```pascal
message := "forty-two";
```

The new string is allocated:

```text
STACK      MEMORY      HEAP
S01        M00: S00    S00 refs=1 "hello"
                       S01 refs=1 "forty-two"
```

Then `STORE 0` replaces memory slot `M00`.

Before the VM writes the new value, it releases the old value:

```ruby
release(memory[code.arg])
memory[code.arg] = stack.pop
```

That drops `S00` to zero references, so the VM frees it:

```text
STACK      MEMORY      HEAP
xxx        M00: S01    S00 free
                       S01 refs=1 "forty-two"
```

That is the whole point of refcounting in this version.

---

## The Rule

V5 uses three small ownership rules:

1. `ALLOC` creates a heap object with `refs = 1`.
2. `LOAD` copies a ref, so it calls `retain` and bumps `refs` (e.g. memory still has `S00`, and so does the stack — `refs = 2`).
3. Anything that discards a ref calls `release`.

The important discards are:

- `STORE` overwriting a memory slot (e.g. `message := "forty-two"` — the old `"hello"` ref is dropped before the new ref is written).
- `SYSCALL` popping a stack value (e.g. after the first `SYSCALL(1, message)` — the stack ref is released, dropping `refs` from 2 back to 1; the variable still holds the other reference).
- A frame finishing and releasing its memory. After both `SYSCALL`s, the top-level frame is about to exit. `cleanup(memory)` releases everything in memory, so `"forty-two"` (the only value still in `M00`) drops to `refs = 0` and is freed.

Nothing about `SYSCALL` or strings requires new parser complexity. The new concept is that the VM now manages the lifetime of heap values.

> **Looking ahead:** V5 stores strings as a single scalar payload (a Ruby `String` inside `HeapValue.value`). V8 will add arrays of cells (another shape for `HeapValue.value`) — by V8 we'll have two heap shapes doing similar work. V9 unifies them: strings become arrays of codepoints, and this scalar-string special case goes away entirely. The same pattern showed up earlier in the tutorial (V3 renamed `:Add` to `:Math` because V4 was going to generalize to all integer operators). It's a recurring engineering moment: introduce a special case, use it for a few versions, then recognize it can be general.
