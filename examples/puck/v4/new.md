# Puck V4

V4 branches from V3 and adds the minimum needed for looping:

- `LOOP ... END;`
- `EXIT;`
- `JUMP`
- **deferred multi-target patching**

V3 already taught single-jump patching for `IF`. V4 generalizes it: a `LOOP` body can contain many `EXIT`s, and all of them have to be patched to the same address after the loop body has been compiled. The compiler accumulates a list of placeholder positions, then patches them in one sweep.

It also expands math operators to `+`, `-`, `*`, `/`, and `%` by sending the operator symbol to Ruby:

```ruby
stack.push(left.send(op, right))
```

The README focuses on the deferred-list patching pattern because that is the new compiler concept. Loop parsing is intentionally straightforward.
