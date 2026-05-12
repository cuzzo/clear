# The V4 Implementation - Patching Jump Targets

V3 introduced the idea of jumping with `IF`.

V4 makes that idea concrete by compiling procedure bodies into bytecode with real jump instructions:

```text
JUMP_IF_FALSE
JUMP
RETURN
```

The new source feature is `LOOP` / `EXIT`, but the interesting compiler feature is **patching**.

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

Run it with:

```bash
ruby examples/puck/v4/vm.rb
```

Output:

```text
OUTPUT: 42
```

V4 also sneaks in the basic math operators by using Ruby's `send`:

```ruby
stack.push(left.send(op, right))
```

So the VM can run `+`, `-`, `*`, `/`, and `%` without adding a new branch for each operator.

---

## Why Patching Exists

A loop needs to jump in two directions:

```text
loop_start:
  ... body ...
  JUMP loop_start
loop_end:
```

The backward jump is easy. When the compiler emits `JUMP loop_start`, it already knows where `loop_start` is.

`EXIT` is different:

```text
loop_start:
  ...
  EXIT
  ...
  JUMP loop_start
loop_end:
```

When the compiler sees `EXIT`, it does not know where `loop_end` is yet. The loop body has not finished compiling.

So the compiler emits a placeholder:

```text
JUMP nil
```

Later, after the loop body is compiled, the compiler knows the loop-end address and patches the placeholder:

```ruby
exits.each { |exit| codes[exit].arg = codes.length }
```

That is patching.

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

the compiler wants bytecode shaped like:

```text
loop_start:
  LOAD i
  LOAD limit
  COMPARE :==
  JUMP_IF_FALSE after_if
  JUMP loop_end        # EXIT, patched later
after_if:
  LOAD i
  PUSH 1
  MATH :+
  STORE i
  JUMP loop_start
loop_end:
```

There are two patching moments:

1. `JUMP_IF_FALSE after_if`
2. `JUMP loop_end` for `EXIT`

Both targets are forward jumps. The compiler cannot know those addresses until it has emitted the bytecode in between.

---

## The Compiler Trick

V4 compiles nested statement bodies into the same bytecode array for that procedure.

That matters because jump targets are instruction indexes:

```ruby
loop_start = codes.length
```

For `IF`, the compiler emits a placeholder:

```ruby
jump = codes.length
codes << ByteCode.new(:JUMP_IF_FALSE)
compile_statements(node.val[:body], mem, procedures, loop_exits, codes)
codes[jump].arg = codes.length
```

For `LOOP`, it collects every `EXIT` placeholder:

```ruby
loop_start = codes.length
exits = []
compile_statements(node.val, mem, procedures, loop_exits + [exits], codes)
codes << ByteCode.new(:JUMP, loop_start)
exits.each { |exit| codes[exit].arg = codes.length }
```

For `EXIT`, it records the placeholder location:

```ruby
loop_exits.last << codes.length
codes << ByteCode.new(:JUMP)
```

That is the core of v4.

---

## Why This Matters

Parsing `LOOP` is not the hard part. It is just another block:

```pascal
LOOP
  ...
END;
```

The important part is that flat bytecode cannot point to labels that do not exist yet.

Patching solves that:

1. Emit a jump with no target.
2. Remember where it is.
3. Compile the body.
4. Fill in the target once the destination address exists.

That same trick is used for `IF`, `ELSE`, `LOOP`, `EXIT`, `WHILE`, `CASE`, and eventually more serious control flow.
