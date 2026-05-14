# Puck V8

V8 branches from V7 and adds heap-backed mutable storage:

- `VAR x` in procedure parameters: pass-by-reference. Inside the callee, accesses to a VAR param go through a heap cell; the caller's variable is mutated in place.
- `ARRAY(N)` allocates a fixed-size, heap-backed array initialised to zeros.
- `name[i]` for indexed read (in expressions) and `name[i] := value;` for indexed write (statement).

The VM gains three new ops for cells (`ALLOC_CELL`, `LOAD_REF`, `STORE_REF`) and three for arrays (`ALLOC_ARRAY`, `ARRAY_GET`, `ARRAY_SET`). A REF cell is just an array of length 1 — the heap entry shape is identical; only the bytecode ops differ.

The compiler does one small pre-pass per scope to identify which variables are passed by `VAR` to some callee in that scope. Those slots are heap-boxed at procedure entry. Inside the procedure body, accesses to boxed names emit `LOAD_REF`/`STORE_REF` instead of `LOAD`/`STORE`.

`release` now recurses into array payloads — a cell or array that hits `refs=0` releases anything stored inside it before being freed. V5 didn't need this because strings hold no nested refs; V8 does.

The parser change is small: `VAR` keyword in `parse_params`, plus three new productions for `ARRAY(N)`, `name[i]` in expressions, and `name[i] := value;` in statements. The `Procedure` AST node gains a parallel `var_params` list of names so existing tracer code doesn't have to learn a new shape.

> **Note for future readers:** by V8 we now have *two* heap shapes — V5's scalar string entries and V8's array-of-cells entries. They share the refcounting machinery but live in separate code paths. V9 unifies them: strings become arrays of codepoints, and the special-case scalar payload goes away.
