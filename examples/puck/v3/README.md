# The V3 Implementation - Conditional Jumping

V2 introduced expression trees and recursive compilation.

V3 adds the first real control-flow idea: **do not always run the next statement**.

That sounds small, but it is the foundation of `IF`, `WHILE`, `LOOP`, `RETURN`, and almost every non-trivial program. At the machine level, this idea is usually called a **jump**.

---

## The Program

The demo program in [vm.rb](vm.rb) defines two procedures:

```pascal
PROCEDURE add(a, b);
  RETURN a + b;
END;

PROCEDURE print_selectively(x);
  IF x = 42 THEN
    SYSCALL(1, x);
  END;
END;

result := add(40, 2);
print_selectively(41);
print_selectively(result);
```

You can run it with:

```bash
ruby examples/puck/v3/vm.rb
```

Output:

```text
OUTPUT: 42
```

The important behavior is not that `add(40, 2)` returns `42`. That is straightforward.

The important behavior is this:

```pascal
print_selectively(41);      # Does not print.
print_selectively(result);  # Prints, because result is 42.
```

For the first time, the VM must choose whether to skip code.

---

## What Jumping Means

In V1 and V2, bytecode mostly ran straight down:

```text
PUSH 40
PUSH 2
MATH :+
STORE 0
LOAD 0
SYSCALL 1
```

The instruction pointer moves from one instruction to the next:

```text
0 -> 1 -> 2 -> 3 -> 4 -> 5
```

An `IF` changes that. Conceptually, this source:

```pascal
IF x = 42 THEN
  SYSCALL(1, x);
END;
```

means:

```text
evaluate x = 42
if false, jump past the body
run SYSCALL only if true
continue after END
```

As flattened bytecode, that idea usually looks like:

```text
LOAD x
PUSH 42
COMPARE :==
JUMP_IF_FALSE after_if
LOAD x
SYSCALL 1
after_if:
```

Now walk through the `print_selectively(41)` case.

Inside the procedure, memory starts as:

```text
memory = { "x" => 41 }
stack = []
```

At first, the instruction pointer still behaves like V1. It just moves down one instruction at a time.

```text
> LOAD x
  PUSH 42
  COMPARE :==
  JUMP_IF_FALSE after_if
  LOAD x
  SYSCALL 1
  after_if:
```

`LOAD x` reads `41` and pushes it:

```text
stack = [41]
```

Then the instruction pointer moves down normally:

```text
  LOAD x
> PUSH 42
  COMPARE :==
  JUMP_IF_FALSE after_if
  LOAD x
  SYSCALL 1
  after_if:
```

`PUSH 42` puts `42` on top:

```text
stack = [41, 42]
```

Again, the instruction pointer moves down normally:

```text
  LOAD x
  PUSH 42
> COMPARE :==
  JUMP_IF_FALSE after_if
  LOAD x
  SYSCALL 1
  after_if:
```

`COMPARE :==` pops the top two values and compares them:

```text
41 == 42
false
```

Then it pushes the boolean result:

```text
stack = [false]
```

The instruction pointer moves down normally again:

```text
  LOAD x
  PUSH 42
  COMPARE :==
> JUMP_IF_FALSE after_if
  LOAD x
  SYSCALL 1
  after_if:
```

This is the first instruction that can move the pointer somewhere other than the next line.

`JUMP_IF_FALSE` pops the condition:

```text
stack = []
condition = false
```

Because the condition is false, it moves the instruction pointer to `after_if`:

```text
  LOAD x
  PUSH 42
  COMPARE :==
  JUMP_IF_FALSE after_if
  LOAD x
  SYSCALL 1
> after_if:
```

That skipped the body:

```text
LOAD x
SYSCALL 1
```

So `print_selectively(41)` prints nothing.

The jump is not a function call. It does not create a new stack frame. It only changes where the instruction pointer goes next.

---

## How V3 Represents IF

The tokenizer adds the smallest new syntax:

| Token | Why V3 Needs It |
| --- | --- |
| `IF` | Start a conditional block. |
| `THEN` | Mark where the condition ends and the body begins. |
| `=` | Compare two expressions. |

The parser turns:

```pascal
IF x = 42 THEN
  SYSCALL(1, x);
END;
```

into an AST node shaped like:

```ruby
AstNode.new(
  :If,
  nil,
  {
    condition: ExprNode.new(
      type: :Equal,
      left: ExprNode.new(type: :Variable, name: "x"),
      right: ExprNode.new(type: :Integer, value: 42)
    ),
    body: [
      AstNode.new(:Syscall, "x", 1)
    ]
  }
)
```

The body is just a list of statements. The condition decides whether that list runs.

---

## COMPARE First, JUMP Next

V3 adds equality expressions:

```pascal
x = 42
```

The compiler lowers that expression to:

```text
LOAD x
PUSH 42
COMPARE :==
```

`COMPARE :==` pops two values, compares them, and pushes `true` or `false`.

That boolean is what a flattened bytecode VM would feed into `JUMP_IF_FALSE`:

```text
JUMP_IF_FALSE after_if
```

This v3 keeps the implementation smaller: procedure bodies remain AST, and the VM branches directly in `run_statements`:

```ruby
elsif node.type == :If
  run_statements(node.val[:body], memory) if run_expression(node.val[:condition], memory)
end
```

That line is the same control-flow decision:

```text
if condition is false, skip the body
```

So v3 teaches the jump idea without yet adding explicit jump-address patching to the compiler.

I highly recommend running this interactively as you follow along with the section below:

```bash
ruby examples/puck/run.rb v3
```

---

## Walking Through print_selectively

Call:

```pascal
print_selectively(41);
```

Inside the procedure:

```text
memory = { "x" => 41 }
```

The condition runs:

```pascal
x = 42
```

which evaluates to:

```text
41 == 42
false
```

Because the condition is false, the VM skips:

```pascal
SYSCALL(1, x);
```

Call:

```pascal
print_selectively(result);
```

`result` is `42`, so inside the procedure:

```text
memory = { "x" => 42 }
```

The condition runs again:

```text
42 == 42
true
```

This time the body runs:

```pascal
SYSCALL(1, x);
```

Output:

```text
OUTPUT: 42
```

---

## Why This Matters

Multiple arguments and multi-line procedure bodies are useful, but they are mostly bookkeeping.

Jumping is the real new capability.

Once the VM can decide to skip a body, the next features become natural:

- `IF ... ELSE`
- `LOOP`
- `EXIT`
- `WHILE` as a macro over `LOOP` and `IF`

Those features all come back to the same machine-level trick:

```text
change the instruction pointer instead of blindly running the next instruction
```

V3 is the first step toward that.

When you're ready, jump to [V4](../v4/README.md), where we add loops and ~40 LOC, and reach a Turing-complete language at only ~275 dense LOC!