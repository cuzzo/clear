# CLEAR Mini-VM & Compiler

A self-hosted minimal toolchain written entirely in CLEAR. This project serves as a "Deep Integration" test for the CLEAR v0.1 compiler and a roadmap for the production-grade VM in v0.2.

## Goals
*   **Self-Hosting Proof**: Demonstrate that CLEAR can implement its own execution environment.
*   **Bug Stress-Test**: Exercise `UNION`, `MATCH`, `Id<T>`, and Affine Arrays to find edge cases in the Zig transpiler before the v0.1-pre release.
*   **Intent Showcase**: Prove the "Meaning per Line" thesis by building a compiler and VM in ~500 lines of code.

## Target Features
*   **Stack-based VM**: Simple, robust execution model.
*   **Value Type**: A `UNION Value` supporting `Int64`, `Float64`, and `Bool`.
*   **Sealed Instructions**: Instructions are represented as a `UNION`, mapping directly to a high-speed `MATCH` dispatch loop.
*   **Recursive Descent Compiler**: A parser that compiles math expressions (e.g., `(10 + 5) * 2`) and simple variables into bytecode.

## Out of Scope (V0.1)
*   **String Manipulation**: Limited to numeric/boolean logic to keep the parser simple.
*   **Complex Heap**: No GC simulation; uses CLEAR's native memory model.
*   **Concurrency**: Single-threaded execution loop (logic-only).

## Why this is feasible
By following the **"Dumb VM, Smart Compiler"** philosophy, we avoid the complexity of dynamic dispatch and type-checking at runtime. Using CLEAR's `UNION` and `MATCH`, the entire VM dispatch loop is ~50 lines of code.

## Data Structure Support
*   **Structs**: Supported for `Int64` and `Float64` fields. The VM treats them as packed values.
*   **Arrays**: Supported for fixed-size numeric arrays. The VM manages them as direct memory regions.

## Example Programs

### ✅ Will Compile & Run
```clear
-- Basic Math & Variables
x = (10.5 * 2) + 5
ASSERT x == 26.0

-- Simple Struct Usage
STRUCT Point { x: Float64, y: Float64 }
p = Point{ x: 1.0, y: 2.0 }
ASSERT p.x + p.y == 3.0

-- Array Logic
MUTABLE list: Int64[3] = [1, 2, 3]
ASSERT list[0] + list[1] == 3
```

### ❌ Will NOT Compile (Out of Scope for v0.1 Mini-VM)
```clear
-- String Manipulation (Parsing complexity)
s = "hello" + " world"

-- Dynamic Collections (Heap/GC simulation)
MUTABLE items: Int64[]@list = []
append(items, 10)

-- Parallelism (Scheduler simulation)
(1..10) s> CONCURRENT EACH { ... }
```

## Implementation Roadmap (Commits)
1.  **Foundation**: Define `UNION Instruction` and `SimpleStack` in `vm.cht`.
2.  **Execution**: Implement the `VM.run()` loop with instruction dispatch.
3.  **Parsing**: Implement a basic `Lexer` and recursive-descent `Parser` in `compiler.cht`.
4.  **Emission**: Add bytecode generation to the parser.
5.  **Integration**: Create `main.cht` to parse, compile, and run a script string in one pass.
