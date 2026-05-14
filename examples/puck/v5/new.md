# Puck V5

V5 branches from V4 and adds the minimum needed for heap strings:

- string tokens like `"hello"`
- `ExprNode(type: :String, value: "...")`
- `ALLOC` for heap values (its argument is the literal string itself; this version only allocates strings, so there is no type tag)
- heap refs like `S00`
- `retain` on `LOAD` (the same ref now lives in both memory and on the stack, so `refs` goes from 1 to 2)
- `release` when a ref is overwritten by `STORE`, popped by `SYSCALL`, or dropped during a frame's `cleanup`

The README focuses on refcounting because that is the new VM concept. String parsing is intentionally small.
