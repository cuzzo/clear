# The V6 Implementation - Modules

V5 added heap strings and refcounting.

V6 adds the source shape that makes the program look more like a small Oberon module:

```pascal
MODULE Demo;
  declarations...
BEGIN
  statements...
END.
```

This is mostly a parser and compiler change. `vm.rb` is unchanged from V5 — see [V5](../v5/README.md) for the bytecode interpreter.

The trailing `.` matters: `END.` ends the module; `END;` ends every other block (`IF`, `LOOP`, `PROCEDURE`). The single-character difference is the only thing the parser needs to tell them apart, which is why the tokenizer in this version adds `.` as an operator token.

---

## The Program

The demo program lives in [example.puck](example.puck). Its overall shape is the V6 lesson:

```pascal
MODULE Demo;
  PROCEDURE print_if_target(i); ... END;
BEGIN
  ... statements ...
END.
```

It exercises most of the language built so far — strings, refcounting, procedure calls, conditionals, loops, math, and syscalls — so V6's structural change can be seen wrapping a non-trivial program. See [example.puck](example.puck) for the full source.

Run it directly:

```bash
ruby examples/puck/v6/vm.rb
```

Or run it in the visualizer:

```bash
ruby examples/puck/run.rb v6
```

Output:

```text
OUTPUT: starting
OUTPUT: hit
OUTPUT: 3
OUTPUT: done
```

---

## What Changed

The tokenizer adds the module keywords and the final `.` operator:

```ruby
MODULE BEGIN
```

The parser recognizes a module before ordinary statements:

```ruby
def parse
  return [parse_module] if @tokens[@pos]&.type == :MODULE

  parse_statements
end
```

`parse_module` separates declarations from executable body:

```ruby
declarations = parse_statements(:BEGIN)
consume(:BEGIN)
body = parse_statements(:END)
consume(:END)
consume(:OPERATOR) # .
```

The result is one wrapper node:

```ruby
AstNode.new(:Module, name, { declarations: declarations, body: body })
```

In the demo program, "declarations" is just the `PROCEDURE print_if_target(i); ... END;` block — everything between `MODULE Demo;` and `BEGIN`. Later versions can put more kinds of things (constants, types, variable declarations) here.

The module name `Demo` is captured by the parser and stored on the AST node, but the V6 compiler currently does nothing with it (`node.var` is not referenced in [compiler.rb](compiler.rb)). It's parsed-but-unused — a later version could use it to namespace procedures (e.g. `Demo.print_if_target`) or emit it as a label in the bytecode header. For now it just makes the source look like Oberon.

---

## Why The VM Does Not Change

The compiler lowers the module wrapper back into the same shape as before:

```ruby
compile_statements(node.val[:declarations], mem, procedures, loop_exits, codes)
compile_statements(node.val[:body], mem, procedures, loop_exits, codes)
```

Procedures still compile into the procedure table.

The `BEGIN ... END.` body still compiles into top-level bytecode.

So the VM still sees ordinary bytecode:

```text
ALLOC String "starting"
STORE 0
LOAD 0
SYSCALL 1
...
```

That is the main v6 lesson: `MODULE` is program structure, not a new runtime instruction.

### Why this is an ALGOL benefit

V6 is the clearest example so far of a deliberate tradeoff in the ALGOL/Oberon family — the same tradeoff that's part of why we picked one of these languages for this tutorial.

In a Lisp or Scheme, the parser is famously tiny — the reader is two pages of code. That's the usual Lisp pitch, and it's true. But (in our opinion) the parser is the *easy* part of building a small language. The hard parts — choosing bytecode shapes, lowering control flow, managing values at runtime — are where the real work hides. A small parser means more of the system's complexity ends up in the compiler and VM, where it's harder to reason about.

ALGOL/Oberon makes the opposite trade. The parser is the largest chunk of code, but the work it's doing is mostly mechanical: read tokens left-to-right, recognize keywords, build AST nodes. From there the compiler and VM stay small. V6 demonstrates this exactly: a whole new piece of source-level structure (`MODULE ... BEGIN ... END.`) added a fair bit of parser code, a tiny `:Module` case in the compiler, and **zero lines** to `vm.rb`.

We believe that trade — bigger parser, smaller compiler, smaller VM — makes ALGOL/Oberon-style implementations easier to wrap your head around. Not only is the syntax more recognizable to most readers, but the parts that actually require careful thinking are smaller.

---

## What This Shows

The example intentionally exercises earlier pieces:

- strings and refcounting: `label := "starting";` then `label := "done";`
- procedure calls: `print_if_target(i);`
- conditionals: `IF i = 3 THEN`
- loops and exits: `LOOP ... EXIT ... END;`
- math: `i := i + 1;`
- syscalls for strings and integers

V6 makes the source feel more complete while keeping the bytecode machine small.
