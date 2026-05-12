# Puck V4

V4 branches from V3 and adds the minimum needed for looping:

- `LOOP ... END;`
- `EXIT;`
- `JUMP`
- `JUMP_IF_FALSE`
- `RETURN`
- jump-target patching

It also expands math operators to `+`, `-`, `*`, `/`, and `%` by sending the operator symbol to Ruby:

```ruby
stack.push(left.send(op, right))
```

The README focuses on patching because that is the new compiler concept. Loop parsing is intentionally straightforward.
