# Design: Mutable Pattern Bindings in CLEAR

## 1. Problem Statement
Currently, CLEAR pattern matching (`MATCH`) and type narrowing (`IS_A`) only support binding variables as immutable aliases:
```clear
IF reg IS_A VarDecl AS var_decl THEN
  var_decl.var_used = TRUE; # COMPILER ERROR: Cannot modify field of immutable object
END
```
This forces developers to copy the payload to a mutable local variable, modify it, and write it back. However, for reference-counted values (`@multiowned` or `@shared`), writing back replaces the pointer/reference itself rather than mutating the payload in-place. This breaks shared identity (e.g. other references to the AST node do not see the mutation).

To support transpiling object-oriented codebases (like the Ruby-based compiler itself), CLEAR needs support for mutating payloads through narrowed variables in-place.

---

## 2. Proposed Syntax
We propose extending the `AS` binding syntax with an optional `MUTABLE` modifier:

### Type Narrowing (`IS_A`)
```clear
IF reg IS_A VarDecl AS MUTABLE var_decl THEN
  var_decl.var_used = TRUE; # Mutates the VarDecl payload in-place
END
```

### Pattern Matching (`MATCH`)
```clear
MATCH u START
  U.A AS MUTABLE a -> a.val = 1,
  U.B AS MUTABLE b -> b.val = 2
END
```

---

## 3. Semantics and Code Generation

### Reference/Pointer Semantics
When binding with `AS MUTABLE`:
- If the matched container is a reference type (e.g., `@multiowned` or `@shared`), the binding is a mutable pointer to the interior variant payload.
- In-place mutation directly writes to the shared memory block, propagating changes to all aliases.

### Code Generation (Zig Backend)
In the transpiled Zig output:
- Instead of capturing the union variant by value:
  ```zig
  // Current by-value capture
  if (reg_value == .VarDecl) |var_decl| { ... }
  ```
- Capture the variant by pointer:
  ```zig
  // Proposed mutable pointer capture
  if (reg_value == .VarDecl) |*var_decl| {
      var_decl.var_used = true;
  }
  ```

---

## 4. Required Compiler Modifications

### A. Parser (`compiler/ruby/ast/parser.rb`)
Modify the `AS` parsing rules in both `parse_match_statement` and `parse_is_a_rhs` to accept `MUTABLE`:
```ruby
# Proposed parser change
if match?(:KEYWORD, 'AS')
  consume(:KEYWORD, 'AS')
  mutable = match?(:KEYWORD, 'MUTABLE') && consume(:KEYWORD, 'MUTABLE')
  binding = consume(:VAR_ID).value
end
```

### B. AST (`compiler/ruby/ast/ast.rb`)
Update `IsA` and `MatchCase` nodes to store a `mutable_binding` boolean flag.

### C. Annotator (`compiler/ruby/annotator/`)
- In `variables.rb`, register the bound variable as mutable in the scope if `mutable_binding` is true.
- Allow assignments to fields of the bound variable without raising `Cannot modify field of immutable object`.

### D. MIR / Emitter (`compiler/ruby/backends/transpiler.rb` & `mir_lowering.rb`)
- Lower `IsA` and `MatchCase` payload accesses to utilize Zig pointer captures (`|*var_decl|` instead of `|var_decl|`).
