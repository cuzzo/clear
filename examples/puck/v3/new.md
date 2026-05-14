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

- Compiles procedure bodies to their own bytecode, including multi-statement bodies.
- Compiles multiple call arguments before `CALL`.
- Adds `COMPARE :==` for equality expressions.
- Adds `JUMP_IF_FALSE` for `IF`, with the first instance of **patching**: emit the jump with no target, compile the body, then fill in the target as "past the body".

## vm.rb

- Calls procedures with any number of arguments. The recursive `run` from V2 is unchanged; each `CALL` opens a new memory frame.
- Adds `JUMP_IF_FALSE` (pop the top of the stack; if false, move `ip` to the patched target).
- Adds `RETURN` (already needed in V2 — multi-statement bodies make its role obvious here).
