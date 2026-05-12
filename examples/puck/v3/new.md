# Puck V3

V3 keeps the V2 file split and adds the smallest surface needed for:

```puck
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

Only `42` prints.

## tokenizer.rb

- Adds `IF` and `THEN` keyword tokens.
- Adds `=` as an operator token.

## parser.rb

- Parses multiple procedure parameters.
- Parses multiple call arguments.
- Parses procedure bodies as multiple statements.
- Parses `IF <expression> THEN ... END;`.
- Parses procedure calls as standalone statements.

## compiler.rb

- Compiles multiple call arguments before `CALL`.
- Keeps procedure bodies as AST for the VM to execute when called.
- Adds `COMPARE :==` for equality expressions.

## vm.rb

- Calls procedures with any number of arguments.
- Runs multi-statement procedure bodies.
- Runs `IF` bodies only when their condition is true.
