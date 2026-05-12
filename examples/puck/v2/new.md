# Puck V2

V2 keeps the V1 shape, but splits the code into four files and adds the smallest procedure path needed for:

```puck
PROCEDURE add_one(x); RETURN x + 1; END;
result := add_one(41);
SYSCALL(1, result);
```

## tokenizer.rb

- Adds `PROCEDURE`, `RETURN`, and `END` keyword tokens.
- Adds `+` as an operator token.

## parser.rb

- Owns `AstNode`.
- Parses one-argument procedure definitions.
- Parses integer, variable, addition, and one-argument call expressions.

## compiler.rb

- Owns `ByteCode`.
- Stores procedure definitions by name.
- Compiles assignment values from expressions, including `add_one(41)`.
- Emits `CALL` for procedure calls and keeps `SYSCALL(id, var)` behavior from V1.

## vm.rb

- Owns the `VM`.
- Adds `MATH` and `CALL`.
- Keeps the Ruby main block here, so running `ruby examples/puck/v2/vm.rb` executes the V2 demo.
