# CLEAR TODO

### DONE
  * Basic Types => Struct, List, Number, String
  * Basic Constants => TRUE/FALSE/NIL
  * VAR declaration and reassignment (SET)
  * BinaryOps and UnaryOps
  * Basic Control => IF/THEN/ELSE/ELSE_IF/END; WHILE/DO/END
  * Function Definitions, Calls, and Closures
  * Initial Transpiler to Zig

### IN-FLIGHT
  1. **Capabilities vs Types**: Implementing `multiowned`, `shared`, `alwaysMutable`, and `indirect`.
  2. **WITH Block**: Scoping capabilities and managing lock ordering.
  3. **Simplified Lifetimes**: Implementing `WITH RESTRICT` and path-based borrowing.
  4. **Removal of % Sigil**: Handling stack vs heap allocation automatically.

### ROADMAP
  1. String Concat (20 mins)
  2. SYS_SPAWN (Isolated Processes)
  3. IO (File & Network)
  4. MATCH/START/END (With destructuring)
  5. RANGE(1 TO n)
  6. IMPORT (other CLEAR files)

### TECHNICAL TODO
  * REPL
  * Runtime Line Numbers
  * String Interning
  * Co-routines & fibers -> yield/generators, async/await
  * Execution tracing / debugger hooks
  * Tail call recursion
  * IMPORT (c headers natively) via Zig FFI

### DESIGN TODO
  1. Figure out how to guarantee no file descriptor or thread pool limits.
  2. Enforce type definitions on all Structs and functions.
  3. Empty variables and lists MUST have a type.
  4. For a register VM, do not allow more than 500 variables in local scope.
  5. Refine `WITH` block semantics for nested capability acquisition.

### RESULT / ERROR HANDLING
  * SMOOTH operator `s>`: Automatically unwrap result objects and manage control flow.

### PATH TO PERFORMANCE
  1. Optimize Zig transpilation output.
  2. Implement Structure-of-Arrays (SoA) transformations for parallel processing.
  3. Ensure cache locality via Arena-based memory layout.
