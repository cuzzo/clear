# The V7 Implementation - Macros

V7 adds macros as a compile-time AST rewrite step.

The VM does not run macros. The compiler does not compile macros. Instead, source moves through one new phase:

```text
tokens -> AST -> macro expander -> simpler AST -> bytecode -> VM
```

That lets us add useful surface syntax while keeping the bytecode machine small. V7 uses this to define `WHILE` and `FOR` *in Puck itself*, plus `ELSIF`/`ELSE` for `IF`, and the comparison operators `<`, `<=`, `>`, `>=`, and `#`.

V7 also adds one Oberon convention worth flagging up front: **`#` is the not-equal operator.** (Oberon uses `#` where most languages use `!=`.)

---

## The Program

See [example.puck](example.puck) for the full source. The shape:

```pascal
MODULE Demo;
  MACRO WHILE(condition) DO body END; ... END;
  MACRO FOR(i, start, finish) DO body END; ... END;
BEGIN
  FOR(i, 1, 5) DO
    IF i = 1 THEN ... ELSIF i = 3 THEN ... ELSE ... END;
  END;
END.
```

Two macros are defined, both in pure Puck source. The body uses one of them.

Run it directly:

```bash
ruby examples/puck/v7/vm.rb
```

Or run it in the visualizer:

```bash
ruby examples/puck/run.rb v7
```

---

## How `DO body END;` Works

The most important V7 idea, and the one that's easiest to miss in source. A macro definition looks like:

```pascal
MACRO WHILE(condition) DO body END;
  LOOP
    IF condition THEN
      body;
    ELSE
      EXIT;
    END;
  END;
END;
```

That header is two parts:

1. **Parameters in `(...)`:** ordinary args, like a procedure. Here, just `condition`.
2. **A body slot in `DO ... END;`:** the name of a slot that will receive the caller's block of statements. Here, named `body`.

In the template, `body;` (with a semicolon, no parens) is the placeholder. When the macro is called, the expander replaces every `body;` with the block of statements the caller wrote between `DO` and `END`.

At the call site:

```pascal
WHILE(i <= 5) DO
  SYSCALL(1, i);
  i := i + 1;
END
```

- `i <= 5` binds to `condition`.
- The two statements between `DO` and `END` become the value of `body`.

After expansion, the template's `body;` gets replaced with those two statements verbatim. The result is ordinary `LOOP` / `IF` / `EXIT` code that the V4 compiler already knows how to compile.

### Why `body;` parses

`body;` is a `CallStatement` with name `"body"` and zero args — a bare procedure call. V7's parser added a new branch in `parse_statement` specifically so `name;` (no parens) parses:

```ruby
elsif @tokens[@pos].value == ";"
  consume(:OPERATOR) # ;
  AstNode.new(:CallStatement, name, [])
```

The expander spots `CallStatement(name, [])` whose `name` matches the current macro's body slot and splices the bound body in place. That special case is the only piece of magic in the expander.

---

## What Expands

`FOR(i, 1, 5)` expands first. The expander binds `i` -> `i`, `start` -> `1`, `finish` -> `5`, and `body` -> the caller's `IF i = 1 THEN ...` block. The template becomes:

```pascal
i := 1;
WHILE(i <= 5) DO
  IF i = 1 THEN
    ...
  ELSIF i = 3 THEN
    ...
  ELSE
    ...
  END;
  i := i + 1;
END;
```

That output still contains a `WHILE(...)` call, so the expander recurses. `WHILE` binds `condition` -> `i <= 5`, `body` -> the result of the previous expansion. After this second pass:

```pascal
i := 1;
LOOP
  IF i <= 5 THEN
    IF i = 1 THEN ... ELSIF i = 3 THEN ... ELSE ... END;
    i := i + 1;
  ELSE
    EXIT;
  END;
END;
```

After expansion, the compiler only sees features it already knows: assignment, `LOOP`, `IF` (with `ELSE`), `EXIT`, math, comparison, and syscalls.

---

## Hygiene (or the lack of it)

V7's macros are **not hygienic**. The expander substitutes names literally. If a macro template uses a name like `i`, and the caller passes a different variable as the bound argument, the substitution renames it correctly. But if a template introduces a *new* variable (not bound to a parameter), it just lives in the caller's scope, which can collide.

For example, `FOR(i, 1, 5)` uses the caller-provided name `i` for the loop variable. The expander rewrites every `i` in the template to whatever the caller passed (here, also `i`). If the caller had a different variable already called `i` and called `FOR(j, 1, 5)`, the template's loop variable becomes `j` cleanly.

But the template doesn't introduce any *fresh* temporaries that need to avoid clashing with caller names. If it did, V7 would need gensyms (synthetic unique names) — the classic macro pitfall. Real Oberon defines `WHILE` and `FOR` as built-in syntax instead of macros for exactly this reason.

For this tutorial, simple substitution is enough. Just be aware that "macros" in V7 are a deliberately minimal version of the idea.

---

## ELSIF

`ELSIF` is parsed as nested `IF` in the `ELSE` branch:

```pascal
IF i = 1 THEN
  ...
ELSIF i = 3 THEN
  ...
ELSE
  ...
END;
```

becomes:

```pascal
IF i = 1 THEN
  ...
ELSE
  IF i = 3 THEN
    ...
  ELSE
    ...
  END;
END;
```

There's no `:Elsif` AST node — just `:If` with an `else_body`. The single `parse_if` method handles both: when it sees `ELSIF`, it recursively calls itself (with the trailing `END;` consumption suppressed, because the outer IF owns those tokens).

### ELSE at the bytecode level

`IF` without `ELSE` was V4's lesson: one forward-jump placeholder, one patch:

```text
   <compile condition>
   JUMP_IF_FALSE after_if   # placeholder
   <compile body>
after_if:
```

`IF ... ELSE` needs two patch sites:

```text
   <compile condition>
   JUMP_IF_FALSE else_branch   # patch 1
   <compile body>
   JUMP after_else             # patch 2
else_branch:
   <compile else_body>
after_else:
```

The compiler emits `JUMP_IF_FALSE` with no target, remembers its index, compiles the body, emits an unconditional `JUMP` with no target, remembers *its* index, patches the first jump to land at "right here" (the start of the else branch), compiles the else body, and patches the second jump to land at "right here" (after the else). Same forward-patching pattern as V3 and V4, just two placeholders instead of one.

`ELSIF` reuses this same code path. `IF a THEN ... ELSIF b THEN ... ELSE ... END;` produces the same shape as nested `IF/ELSE/IF/ELSE`, so the compiler emits one `JUMP_IF_FALSE`/`JUMP` pair per `ELSIF`. No new bytecode op.

---

## Operator Translation

V7 adds five comparison operators (`<`, `<=`, `>`, `>=`, `#`). The compiler holds a single map from source operator to the Ruby method symbol the VM should send:

```ruby
COMPARE_OPS = {
  :"="  => :==,
  :"#"  => :!=,
  :"<"  => :<,
  :"<=" => :<=,
  :">"  => :>,
  :">=" => :>=
}.freeze
```

The VM's `compare` is unchanged shape-wise from V5/V6 but no longer needs the `if op == :==` guard — it just sends:

```ruby
def compare(op, stack)
  right = stack.pop
  left = stack.pop
  stack.push(left.send(op, right))
end
```

Adding `<=` cost the parser one literal in its operator list, the compiler one entry in `COMPARE_OPS`, and the VM zero lines. Same trade as V6's MODULE: the parser grew, the VM stayed put.

---

## What This Adds Up To

V7's source surface is much richer than V6's: macros, `ELSIF`/`ELSE`, comparison operators, `DO ... END` blocks. The compiler grew a small amount (one new branch for `If`'s `else_body`, one operator map). The macro expander is a new pre-compile phase, but it produces AST nodes the V4-vintage compiler already understands. **The VM gained zero new ops.**

That is the closing benefit of the ALGOL-style tradeoff: by V7 we have a credibly useful little language, and the runtime is essentially the V4 stack machine plus V5's refcounted heap.
