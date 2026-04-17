# Architecture

To understand the stages of the compiler, we will use a simple CLEAR program to understand it:

```ruby clear illustrative
FN add_one() RETURNS Int64 ->
  x = 41;
  RETURN x + 1;
END
```

### 0. Lexer (`src/lexer.rb`)

 * This takes text and parses it into valid CLEAR tokens.
 * If you're adding a new syntax feature, you likely need to start here.

```ruby
[
  Token(:KEYWORD, "FN"),
  Token(:VAR_ID,  "add_one"),
  Token(:CHAR,    "("),
  Token(:CHAR,    ")"),
  Token(:KEYWORD, "RETURNS"),
  Token(:TYPE_ID, "Int64"),
  Token(:ARROW,   "->"),

  Token(:VAR_ID,  "x"),
  Token(:CHAR,    "="),
  Token(:INT64,   41),
  Token(:CHAR,    ";"),

  Token(:KEYWORD, "RETURN"),
  Token(:VAR_ID,  "x"),
  Token(:CHAR,    "+"),
  Token(:INT64,   1),
  Token(:CHAR,    ";"),

  Token(:KEYWORD, "END"),
  Token(:EOF,     nil),
]
```

### 1. Parser (`src/parser.rb`)

 * This parses tokens and transforms them into Abstract Syntax Tree (AST) nodes.
   * An AST node basically extracts all relevant data from the source text about a particular CLEAR construct (like a function, or while loop).
  
```ruby
AST::Program(
  statements: [
    AST::FunctionDef(
      name: "add_one",
      params: [],
      return_type: :Int64,
      body: [
        AST::BindExpr(
          name: "x",
          type: nil,
          value: AST::Literal(type: :Int64, value: 41)
        ),
        AST::ReturnNode(
          value: AST::BinaryOp(
            left:  AST::Identifier(name: "x"),
            op:    :ADD,
            right: AST::Literal(type: :Int64, value: 1)
          ))])])
```

### 2. Annotation (`src/annotator.rb`)

 * In this pass, the tree is semantically decorated:
   * Names are resolved,
   * Types are inferred,
   * Storage is known,
   * And `x = 41` has been classified as a declaration.

```ruby
AST::FunctionDef(
  name: "add_one",
  return_type: :Int64,
  full_type: FunctionSignature(() -> Int64),
  can_fail: false,
  body: [
    AST::BindExpr(
      name: "x",
      mode: :decl,
      full_type: Int64,
      storage: :stack,
      slot_size: 8,
      value: AST::Literal(
        type: :Int64,
        value: 41,
        full_type: Int64,
        storage: :stack
      )
    ),
    AST::ReturnNode(
      value: AST::BinaryOp(
        left: AST::Identifier(
          name: "x",
          full_type: Int64,
          symbol: <resolved local binding x>
        ),
        op: :ADD,
        right: AST::Literal(type: :Int64, value: 1, full_type: Int64),
        full_type: Int64
      ))])
```

### 3. Pipeline Fusion & Desugaring 

  * At this stage, pipelines are fused together for efficiency other desugaring occurs, like string concatenation.

### 4. MIR Pass / Control Flow (`src/control_flow.rb`)

An Abstract Syntax Tree is very difficult to work with to ensure sound Affine Ownership: ensure no use-after-free, no double-free, and no memory leaks.

In this pass, we build a Control Flow Graph (CFG), run ownership analysis, and use this to create the MIR.

This is's easy to ensure some invariants:

  1. An affine value has at most one active owner at a time.
  2. A value is dropped exactly when the current scope still owns it at scope exit.
  3. A value that has been moved must not be used or dropped again.

```text
entry -> block0 -> exit

block0:
  x = 41
  return x + 1
```

Ownership/dataflow is also trivial:

```text
x: stack Int64
needs cleanup? no
moved guard? no
```

### 5. MIR Lowering

 * In the pass, we take the CFG, and transform it into a MIR (a Mid-level Representation).

```ruby
MIR::Program([
  MIR::FnDef(
    "add_one",
    [],
    "i64",
    [
      MIR::Let(
        "x",
        MIR::IntLit(41),   # schematic name
        false,             # const
        nil,               # no explicit Zig annotation needed
        nil
      ),
      MIR::ReturnStmt(
        MIR::BinaryOp(     # schematic
          MIR::Ident("x"),
          :add,
          MIR::IntLit(1)
        )
      )
    ],
    :private,
    false,
    nil
  )
])
```

 * The code directly as parsed cannot easily convert directly to Zig *SAFELY*.
 * A Mid-Level Representation (MIR) exists as the go-between from the parsed AST to the final *SAFE* Zig code.

### 6. MIR Emission / Zig Transpilation

Finally, we transform that MIR into Zig code:

```zig
fn add_one() i64 {
    const x = 41;
    return x + 1;
}
```
