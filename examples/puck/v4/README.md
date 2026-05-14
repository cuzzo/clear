# The V4 Implementation - Patching Many Jumps At Once

V3 introduced patching: emit a forward jump with a placeholder target, then fill in the target once we know where to land.

V3 only needed *one* placeholder per `IF`. V4 needs to patch *many* placeholders at the same target — one for every `EXIT` inside a `LOOP`. The new compiler concept is **deferred multi-target patching**.

V4 also adds:

```text
LOOP ... END;
EXIT;
JUMP        # the unconditional cousin of JUMP_IF_FALSE
```

---

## The Program

The demo program in [vm.rb](vm.rb) walks numbers from `1` to `100`. It only prints when the loop reaches `42`.

```pascal
PROCEDURE fizzbuzz(limit);
  i := 1;
  LOOP
    IF i % 3 = 0 THEN
      IF i = 42 THEN
        SYSCALL(1, i);
      END;
    END;

    IF i = limit THEN
      EXIT;
    END;

    i := i + 1;
  END;
END;

fizzbuzz(100);
```

Run it interactively with:

```bash
ruby examples/puck/run.rb v4
```

Output:

```text
OUTPUT: 42
```

V4 also sneaks in the basic math operators by using Ruby's `send`:

```ruby
stack.push(left.send(op, right))
```

So the VM can run `+`, `-`, `*`, `/`, and `%` without adding a new branch for each operator. This replaces V3's hardcoded `if op == :+`.

---

## Why One-Patch Isn't Enough

V3's `IF` patching was symmetric: one placeholder, one patch. The placeholder and patch live in the same `compile_statement` call:

```ruby
jump = codes.length
codes << ByteCode.new(:JUMP_IF_FALSE)
compile_body(...)
codes[jump].arg = codes.length
```

A `LOOP` needs two kinds of jumps:

```text
loop_start:
  ... body ...
  JUMP loop_start         # backward — easy, we know loop_start
loop_end:
```

The backward jump is trivial. The compiler emits `JUMP loop_start` and `loop_start` is already an integer it captured before the body.

`EXIT` is the hard one:

```text
loop_start:
  ...
  EXIT                    # ?
  ...
  JUMP loop_start
loop_end:                 # this address is unknown when EXIT is compiled
```

When the compiler sees `EXIT`, it has no idea where `loop_end` will be. And there can be many `EXIT`s scattered through the loop body, each wanting to land at the same `loop_end`.

So we need:

1. A way to emit each `EXIT` as a placeholder.
2. A way to remember all those placeholder positions.
3. A way to patch them all together once `loop_end` is known.

---

## Deferred Multi-Target Patching

The compiler threads a stack of "open loops". Each open loop owns a list of `EXIT` placeholders waiting to be patched.

`LOOP` pushes a new exit list. `EXIT` appends to the *innermost* list. After the body is compiled, the `LOOP` knows the final `loop_end` address and patches every placeholder in its list to that one target:

```ruby
elsif node[:type] == :Loop
  loop_start = codes.length
  exits = []
  compile_statements(node.val, mem, procedures, loop_exits + [exits], codes)
  codes << ByteCode.new(:JUMP, loop_start)
  exits.each { |exit| codes[exit].arg = codes.length }   # patch them all

elsif node[:type] == :Exit
  raise "EXIT outside LOOP" if loop_exits.empty?
  loop_exits.last << codes.length    # record placeholder position
  codes << ByteCode.new(:JUMP)        # emit placeholder
```

Compare to V3, where `IF` only had to remember a single integer. Here we remember a *list* per loop, and patching is a sweep over that list.

`loop_exits` is a stack of lists (not a single list) because loops can nest. An inner `EXIT` should bind to the innermost loop, which `loop_exits.last` selects.

---

## The Loop Shape

For:

```pascal
LOOP
  IF i = limit THEN
    EXIT;
  END;

  i := i + 1;
END;
```

the compiler emits:

```text
loop_start:
  LOAD i
  LOAD limit
  COMPARE :==
  JUMP_IF_FALSE after_if      # patched by V3's single-jump pattern
  JUMP loop_end               # patched by V4's multi-exit sweep
after_if:
  LOAD i
  PUSH 1
  MATH :+
  STORE i
  JUMP loop_start             # backward, no patching needed
loop_end:
```

Two patching moments visible: the `IF`'s single placeholder (V3 lesson) and the `EXIT`'s entry in the loop's exit list (V4 lesson). Together they handle every forward jump in the program.

---

## Why This Matters

Once you can defer-and-patch a *list* of placeholders, the same machinery covers every other control-flow form a teaching language is likely to add:

- `IF ... ELSE` — two patch sites: one for the `JUMP_IF_FALSE` past the then-branch, one for the `JUMP` past the else-branch.
- `WHILE` — desugars to `LOOP` + `IF` + `EXIT`.
- `BREAK` / `CONTINUE` — additional named lists on the loop stack.
- `CASE` / `SWITCH` — N placeholders, one per arm.

V3 taught the idea. V4 turns it into a pattern you can apply to any forward-jump form.
