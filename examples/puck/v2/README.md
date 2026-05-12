# The V2 Implementation - Recursive AST Compilation

V1 proved the smallest useful loop:

1. Tokenize source code.
2. Parse tokens into AST nodes.
3. Compile AST nodes into bytecode.
4. Run bytecode on a stack VM.

V2 keeps that same loop, but splits the implementation into four files:

| File | Job |
| --- | --- |
| `tokenizer.rb` | Turns source text into tokens. |
| `parser.rb` | Turns tokens into AST nodes and expression trees. |
| `compiler.rb` | Turns AST nodes and expression trees into bytecode. |
| `vm.rb` | Runs the bytecode. |

The big new idea is that expressions are recursive. V2 keeps `AstNode` for statements and adds `ExprNode` for expression trees.

In V1, the value of an assignment was just an integer:

```pascal
result := 42;
```

In V2, the value can be an expression:

```pascal
result := add_one(add_one(40));
```

That expression has smaller expressions inside it:

```text
Call add_one
  argument: Call add_one
    argument: Integer 40
```

That is why both the parser and compiler now have recursive methods.

---

## The Program

The demo program in [vm.rb](vm.rb) uses the simpler version:

```pascal
PROCEDURE add_one(x);
  RETURN x + 1;
END;

result := add_one(41);
SYSCALL(1, result);
```

You can run it with:

```bash
ruby examples/puck/v2/vm.rb
```

Output:

```text
OUTPUT: 42
```

The more interesting expression is:

```pascal
result := add_one(add_one(40));
```

It also produces `42`, but it shows why recursion matters.

---

## Step 1: Tokenizer

The tokenizer still scans left to right. V2 adds just enough syntax for procedures and addition:

| Token | Why V2 Needs It |
| --- | --- |
| `PROCEDURE` | Start a procedure definition. |
| `RETURN` | Return an expression from the procedure. |
| `END` | Finish the procedure definition. |
| `+` | Support `x + 1`. |

For:

```pascal
result := add_one(add_one(40));
```

the tokenizer produces:

```text
[
  [:SYMBOL, "result"],
  [:OPERATOR, ":="],
  [:SYMBOL, "add_one"],
  [:OPERATOR, "("],
  [:SYMBOL, "add_one"],
  [:OPERATOR, "("],
  [:INTEGER, 40],
  [:OPERATOR, ")"],
  [:OPERATOR, ")"],
  [:OPERATOR, ";"]
]
```

The tokenizer does not understand that this is a nested function call. It only knows the words and punctuation.

---

## Step 2: Parser

The parser is where the nesting becomes visible.

The assignment parser reads:

```ruby
val = parse_expression
```

That means the right-hand side of `:=` can be more than an integer.

### parse_expression

`parse_expression` starts by reading one term:

```ruby
expression = parse_term
```

Then it checks whether that term is followed by `+`:

```ruby
if @tokens[@pos]&.type == :OPERATOR && @tokens[@pos].value == "+"
  consume(:OPERATOR) # +
  expression = ExprNode.new(type: :Add, left: expression, right: parse_term)
end
```

So this:

```pascal
x + 1
```

becomes:

```ruby
ExprNode.new(
  type: :Add,
  left: ExprNode.new(type: :Variable, name: "x"),
  right: ExprNode.new(type: :Integer, value: 1)
)
```

### parse_term

`parse_term` handles the pieces expressions are made of:

| Source | Expression Node |
| --- | --- |
| `40` | `ExprNode.new(type: :Integer, value: 40)` |
| `x` | `ExprNode.new(type: :Variable, name: "x")` |
| `add_one(40)` | `ExprNode.new(type: :Call, name: "add_one", arg: ...)` |

The recursive part is here:

```ruby
arg = parse_expression
```

When the parser sees `add_one(`, it does not assume the argument is a simple integer. It calls `parse_expression` again.

That is why this works:

```pascal
add_one(add_one(40))
```

The outer call parses its argument by recursively parsing the inner call.

Output AST for the assignment:

```ruby
AstNode.new(
  :Assignment,
  "result",
  ExprNode.new(
    type: :Call,
    name: "add_one",
    arg: ExprNode.new(
      type: :Call,
      name: "add_one",
      arg: ExprNode.new(
        type: :Integer,
        value: 40
      )
    )
  )
)
```

That tree is the key new thing in V2.

---

## Step 3: Compiler

The compiler has the same problem as the parser: expressions can contain smaller expressions.

So V2 adds:

```ruby
compile_expression(expression, codes, mem, procedures)
```

It dispatches based on expression type:

| Expression | Bytecode |
| --- | --- |
| Integer | `PUSH value` |
| Variable | `LOAD slot` |
| Add | Compile left, compile right, then `MATH :+` |
| Call | Compile argument, then `CALL procedure` |

The recursive call case is the important one:

```ruby
compile_expression(expression.arg, codes, mem, procedures)
codes << ByteCode.new(:CALL, procedure)
```

For:

```pascal
result := add_one(add_one(40));
```

the compiler emits bytecode in this order:

```text
PUSH 40
CALL add_one
CALL add_one
STORE 0
```

The inner call must run first because its return value becomes the argument to the outer call.

The stack makes this natural:

1. `PUSH 40` puts `40` on the stack.
2. First `CALL add_one` pops `40` and pushes `41`.
3. Second `CALL add_one` pops `41` and pushes `42`.
4. `STORE 0` saves `42` into `result`.

Then:

```pascal
SYSCALL(1, result);
```

compiles to:

```text
LOAD 0
SYSCALL 1
```

---

## Step 4: VM

The VM still executes one bytecode instruction at a time.

V2 adds two instructions:

| Instruction | What It Does |
| --- | --- |
| `MATH :+` | Pop two stack values, add them, push the result. |
| `CALL procedure` | Pop one argument, run the procedure return expression, push the result. |

For now, procedures are deliberately tiny:

```pascal
PROCEDURE add_one(x);
  RETURN x + 1;
END;
```

The VM handles `CALL` by:

1. Popping the argument from the stack.
2. Binding it to the procedure parameter name.
3. Evaluating the procedure return expression.
4. Pushing the return value onto the stack.

So `add_one(add_one(40))` runs like this:

```text
stack = []

PUSH 40
stack = [40]

CALL add_one
stack = [41]

CALL add_one
stack = [42]

STORE 0
stack = []
memory = [42]

LOAD 0
stack = [42]

SYSCALL 1
OUTPUT: 42
```

---

## Why This Matters

V1 only compiled flat statements.

V2 introduces tree-shaped expressions:

```text
add_one(add_one(40))
```

is not a list. It is a tree:

```text
Call add_one
  Call add_one
    Integer 40
```

Once the parser can build trees and the compiler can recursively walk trees, the language can grow in small steps:

- More math operators.
- More procedure arguments.
- More expression forms.
- Later, conditionals and loops.

That recursive AST walk is the main new technique in V2.

As with v1, I highly recommend running this interactively:

```bash
ruby examples/puck/run.rb v2
```

When you're ready, jump to [V3](../v3/README.md), where we add conditionals and ~80 LOC, and *almost* reach a Turing-complete language.
