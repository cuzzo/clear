# Puck V5

V5 branches from V4 and adds the minimum needed for heap strings:

- string tokens like `"hello"`
- `ExprNode(type: :String, value: "...")`
- `ALLOC` for heap values
- heap refs like `S00`
- `retain` on `LOAD`
- `release` when refs are overwritten or popped

The README focuses on refcounting because that is the new VM concept. String parsing is intentionally small.
