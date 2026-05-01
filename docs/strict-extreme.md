# STRICT EXTREME: The Path to High-Integrity CLEAR (@strict:extreme)

## Overview
The "CLEAR Story" is a transition from **Productivity** (Ruby-like ease) to **Performance** (C-like speed) to **Integrity** (Ada/SPARK-level safety). While standard CLEAR provides memory and concurrency safety, **STRICT EXTREME** is a compilation mode designed for mission-critical systems (HFT, Aerospace, Medical) where runtime failures (Panics) are unacceptable.

Unlike other high-integrity languages, CLEAR does not require a different syntax for this level of safety. Instead, it uses **Progressive Formal Verification** to prove properties about the code that the `Annotator` and `OwnershipGraph` are already tracking silently.

## The Integrity Spectrum

| Mode | Safety Guarantee | Developer Experience |
| :--- | :--- | :--- |
| **Standard** | Memory & Concurrency Safety | "It just works" (Ruby-like) |
| **STRICT** | Performance & Effect Safety | No hidden HEAP/BLOCKING |
| **STRICT EXTREME** | **Liveness & Panic Safety** | Formally Proven (Ada-like) |

## Core Pillars of STRICT EXTREME

### 1. The "No-Panic" Guarantee (Formal Proof)
In standard mode, CLEAR prevents memory corruption but may `!!` (Panic) on an out-of-bounds index or an integer overflow. In **STRICT EXTREME**, the compiler uses a SMT solver (like Z3) to prove that **no runtime panic is possible**.
- **Constraint Propagation**: The compiler tracks value ranges. If it cannot prove `idx < list.length()`, it rejects the build.
- **Proof Assistance**: The `clear fix` tool suggests `@pre` (pre-conditions) or `@post` (post-conditions) to satisfy the prover.

### 2. Guaranteed Bounded Execution (Stack & Time)
Ada-level safety requires knowing that a program will not run out of memory or hang.
- **Stack Depth Proof**: The compiler walks the call graph and proves the maximum possible stack usage. Recursive functions without a proven base case are rejected.
- **TIGHT Loop Validation**: Loops must be proven to terminate. "Infinite" loops are only allowed in dedicated "Supervisor" fibers.

### 3. Total Effect Isolation
While `STRICT` mode requires annotations for HEAP and BLOCKING, **STRICT EXTREME** requires a **Total Effect Signature**.
- **Deterministic Paths**: Functions can be marked `@pure` (no side effects) or `@deterministic` (identical inputs always yield identical timing/output).
- **Alloc-Free Zones**: Proves that a "Hot Path" performs zero allocations (not even arena allocations) to guarantee zero jitter.

### 4. Liveness & Deadlock Immunity
Leveraging the `OwnershipGraph`, the compiler proves that no circular dependency of `@locked` or `@shared` objects exists. 
- **Lock-Ordering**: The compiler enforces a global "Acquisition Hierarchy." If you try to acquire `Lock B` while holding `Lock A`, but elsewhere `Lock A` is acquired after `Lock B`, the build fails.

## Implementation Path: "Progressive Disclosure"

The beauty of the CLEAR architecture is that **STRICT EXTREME** does not hinder the early-stage developer:
1.  **Draft Phase**: The developer writes code in Standard mode. The compiler silently tracks ownership and effects.
2.  **Optimization Phase**: The developer turns on `STRICT` mode to remove bottlenecks (allocations/blocking).
3.  **Certification Phase**: The developer turns on `STRICT EXTREME`. The compiler takes the existing metadata and "Hardens" it using formal verification.

## Architecture & Logic
Because CLEAR's memory model is a **Directed Acyclic Graph (DAG)** (enforced by Affine movement and Arena scopes), it is mathematically "Decidable." Proving properties about CLEAR code is significantly simpler than proving properties about C++ or Rust because **aliasing is strictly controlled and visible** to the `Annotator`.

### Goal for v0.3 Roadmap
Integration of a formal solver into the `Annotator` to provide "Panic-Free" proofs for core data-processing pipelines.
