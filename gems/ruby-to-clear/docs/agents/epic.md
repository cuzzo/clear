# Epic: Ruby-to-Clear Transpiler (`rb-to-clear`)

This document outlines the design and implementation roadmap for `rb-to-clear`, a Ruby-to-Clear source transpiler built on top of the Prism parser. The initial milestone targets automatically transpiling ~95% of [lexer.rb](file:///home/yahn/litedb/src/ast/lexer.rb).

---

## 1. AST Node Analysis & Target Selection

An audit of [lexer.rb](file:///home/yahn/litedb/src/ast/lexer.rb) using `ruby-to-clear-audit` reveals **43 unique Prism node types** across **1,786 total nodes**. Targeting the top 20 node types achieves **95.80% automatic coverage** of the entire tokenizer source.

### Top 20 Targeted Prism Nodes

| Node Type | Frequency | Representation in `lexer.rb` | Translation Mapping to Clear |
| :--- | :--- | :--- | :--- |
| **CallNode** | 323 | `scan(...)`, `add(...)`, `to_i` | Function/method call or operator expression |
| **StringNode** | 264 | `'...'`, `"..."` | String literal |
| **ArgumentsNode** | 262 | Call argument lists | Bracketed argument list |
| **LocalVariableReadNode** | 148 | Variable reads (`start_col`, etc.) | Identifier |
| **StatementsNode** | 144 | Multiple statements in blocks | Statement list (separated by `;` or newline) |
| **InstanceVariableReadNode**| 136 | `@s`, `@line`, `@column` | Field access on `self` (`self.s`, `self.line`, etc.) |
| **SymbolNode** | 73 | `:type`, `:value` | Enum members, symbols, or identifiers |
| **ConstantReadNode** | 65 | `KEYWORDS`, `StringScanner` | Type reference or global constant |
| **WhenNode** | 63 | `when @s.scan(...) then ...` | MATCH arms (`WHEN ... ->`) or ELSE_IF conditions |
| **IntegerNode** | 54 | `1`, `0`, `3` | Integer literal |
| **RegularExpressionNode** | 44 | `/\s+/` | Regex literals or matching library helper calls |
| **EmbeddedStatementsNode** | 27 | Interpolation expressions `#{...}`| Interpolation braces inside Clear interpolated string |
| **LocalVariableWriteNode** | 27 | `start_col = @column` | Variable declaration `MUTABLE x = y` or `x = y` |
| **AssocNode** | 19 | Hash/Keyword arguments mapping | Struct initializer fields or map pairs |
| **IfNode** | 16 | `if ... else ... end` | `IF ... THEN ... ELSE ... END` |
| **RequiredParameterNode** | 11 | Method definitions params | Type-annotated parameter list |
| **BlockNode** | 9 | `sig { ... }`, `loop { ... }` | Inline closures or control flow blocks |
| **InterpolatedStringNode** | 9 | `"line: #{@line}"` | Clear interpolated string (`$...`) |
| **RangeNode** | 9 | `3..-4` | Clear range syntax (`3..-4`) |
| **DefNode** | 8 | `def tokenize` | `FN` or `METHOD` definition |

---

## 2. Syntax Translation Mapping

The following mapping rules convert Ruby idioms to Clear:

### A. Classes & Instance Variables
- Ruby classes mapping instance variables inside methods:
  ```ruby
  class Lexer
    def initialize(source)
      @line = 1
    end
  end
  ```
- Map to Structs and functions/methods in Clear:
  ```clear
  STRUCT Lexer {
    line: Int64
  }

  FN newLexer(source: String) RETURNS Lexer ->
    RETURN Lexer{ line: 1 };
  END
  ```
- All `@var` references translate to `self.var`.

### B. Functions & Methods (`DefNode`)
- Standard methods:
  ```ruby
  def same_cell?(a, b)
    a.x == b.x
  end
  ```
- Map to:
  ```clear
  FN sameCell?(a: Cell, b: Cell) RETURNS Bool ->
    RETURN a.x == b.x;
  END
  ```

### C. Conditionals (`IfNode`, `WhenNode`, `CaseNode`)
- Single line `IF`:
  ```ruby
  if condition then action end
  ```
  Maps to:
  ```clear
  IF condition -> action;
  ```
- Multi-line `IF`:
  ```clear
  IF condition THEN
    statements;
  ELSE_IF condition2 THEN
    statements;
  ELSE
    statements;
  END
  ```

---

## 3. Transpiler Architecture & Design

We will implement the transpiler in Ruby using `Prism::Visitor`.

### Unsupported Node Fallback Strategy
When encountering an unsupported or partially supported node, the transpiler will fall back to extracting the exact source slice corresponding to the node and emitting it as a commented-out block:

```clear
# [UNSUPPORTED: ClassVariableWriteNode]
# @@global_count = 100
```

This guarantees compile-safety of the emitted structure while preserving non-transpiled logic for manual inspection and incremental updates.

---

## 4. Line of Code (LoC) Estimates

We plan to implement `rb-to-clear` directly in Ruby. The breakdown of estimated code size is:

| Component | Purpose | Estimated LoC |
| :--- | :--- | :--- |
| **CLI & Driver** | Option parsing, input reading, file writing | 50 |
| **Output Buffer / Formatter** | Managing indentation levels, tracking line breaks | 80 |
| **Base Visitor & Fallback** | `Prism::Visitor` subclass with fallback for missing nodes | 80 |
| **AST Node Implementations** | 20 customized visitor methods (average 15 lines each) | 350 |
| **Helper Methods** | Source code extraction, identifier normalization | 80 |
| **Total** | | **640 lines of Ruby** |

---

## 5. Implementation Roadmap

### Phase 1: Skeleton & Comment-All Pass
- Create the gem structure under `gems/ruby-to-clear`.
- Write a basic CLI and `Prism::Visitor` that comments out all nodes, outputting an entirely commented representation of the input source.
- Integrate unit tests verifying the fallback formatting.

### Phase 2: Leaf Nodes & Expressions
- Support basic leaf nodes: `IntegerNode`, `StringNode`, `SymbolNode`, `LocalVariableReadNode`.
- Support writes: `LocalVariableWriteNode`.
- Support ranges, interpolations, and basic `ArgumentsNode`.

### Phase 3: Control Flow & Calls
- Support `IfNode`, `WhenNode`, `CaseNode`, and `CallNode` signatures.
- Support standard `DefNode` structures.

### Phase 4: Tokenizer Translation
- Run the transpiler against `src/ast/lexer.rb`.
- Verify transpiled segments match Clear expectations, manually adjusting any remaining commented-out blocks or extending AST node mappings.
