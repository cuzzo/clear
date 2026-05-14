# Puck V9

V9 branches from V8 and finishes the VM. The destination since V5 has been a single uniform value model — V9 lands it.

- Strings are stored as arrays of integer codepoints. V5's scalar-string heap payload goes away. Every heap entry is now an Array.
- `release` no longer needs the `if payload.is_a?(Array)` guard; the recursion is unconditional.
- New op: `ARRAY_LEN` — works on any heap value (string or array).
- New parser builtins: `LEN(x)` (compiles to `ARRAY_LEN`) and `INPUT()` (compiles to `SYSCALL 2`).
- SYSCALL gains a dispatch table: ID 1 print, ID 2 stdin, ID 3 open file, ID 4 read line from file, ID 5 close file. Each ID is ~5 lines of Ruby; cross-platform comes from Ruby's standard library.

After V9 the value model is just **integers and arrays**. Everything else (string equals/concat/substring, int↔string, records as arrays, the self-hosted compiler) is plain Puck code.

V10 will reimplement the VM in C, with a profiling lesson showing what the Ruby VM spent its time on. That's the last version; `core.puck` and `compiler.puck` ship as plain files alongside the tutorial.
