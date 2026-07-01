# Empirical Big-O Analysis for `nil-kill`

## Overview
This document outlines a proposed architecture for adding empirical Big-O complexity analysis (time and space) to `nil-kill`. Currently, `nil-kill` traces type boundaries, container shapes, and call edges, but it explicitly does not track input sizes or execution resources.

Adding Big-O bounds estimation requires mapping the relationship between an input's size ($N$) and the resulting cost (execution time or memory allocations). Since static analysis of Ruby for algorithmic complexity is notoriously intractable due to its dynamic dispatch, empirical runtime measurement is a viable path forward to finding a lower-bound on complexity.

## Estimated Effort
Building this natively into `nil-kill` without heavy external math dependencies would require roughly **300 to 400 Lines of Code (LoC)**. While the line count is small, the mathematical complexity and required noise-filtering heuristics are high.

## Proposed Architecture

### 1. Ruby Tracer Modifications (`lib/nil_kill/runtime_trace.rb`)
The tracer must be updated to capture size and time metrics without ruining application performance.

*   **Size Extraction ($N$):** 
    During `record_call`, `nil-kill` already samples parameters. We would add a safe check: `if value.respond_to?(:size) || value.respond_to?(:length)`, recording the integer size. For multiple collections, we can track the max size or a combined size matrix.
*   **Cost Measurement (Time/Space):**
    *   *Time:* Capture `Process.clock_gettime(Process::CLOCK_MONOTONIC)` at `record_call` (entry) and `record_return` (exit). The delta is the execution cost.
    *   *Space (Optional but powerful):* Use `GC.stat(:total_allocated_objects)` diffs to measure memory pressure scaling.
*   **Data Aggregation (Reservoir Sampling):** 
    We cannot store millions of $(N, Cost)$ tuples per method in memory. Instead, we should bucket samples (e.g., maintaining the median cost for $N \in [0, 10]$, $N \in [11, 100]$, $N \in [101, 1000]$).
*   **JSON Serialization:**
    Update the final trace output to emit a `complexity_samples` map containing `[N, Cost]` tuples for each method frame.

### 2. Rust Inference Engine (`src/`)
The Rust engine will parse the empirical samples and map them to theoretical curves.

*   **Schema Extension:** Update `schemas.rs` to ingest `complexity_samples`.
*   **Outlier Rejection (Critical):**
    Ruby runtime data is heavily polluted by Garbage Collection pauses, JIT warmup, and thread scheduling. Before curve fitting, the engine must discard the top percentile of outliers (e.g., stripping anything $> 1.5 \times \text{IQR}$).
*   **Curve Fitting / Regression Algorithm:**
    Implement Least Squares Regression to fit the filtered $(N, Cost)$ points against standard complexity shapes:
    *   $O(1)$: $Cost = c$
    *   $O(\log N)$: $Cost = c \cdot \log(N)$
    *   $O(N)$: $Cost = c \cdot N$
    *   $O(N \log N)$: $Cost = c \cdot N \log(N)$
    *   $O(N^2)$: $Cost = c \cdot N^2$
    
    The algorithm computes the $R^2$ (coefficient of determination) for each curve model. The model with the highest $R^2$ that exceeds a minimum confidence threshold (e.g., $R^2 > 0.85$) wins.

### 3. Reporting and Diagnostics
If a method exhibits highly nonlinear scaling (e.g., fitting cleanly to $O(N^2)$), the Rust engine emits a new `Action` diagnostic. 

For example, this could be surfaced in `nil-kill` as:
> **Warning:** `process_users` strongly scales $O(N^2)$ based on parameter `users` (Confidence: 0.94). Check for nested loops or repeated linear array scans.

## Challenges
*   **JIT Noise:** YJIT gets faster over time. Early samples (where $N$ might be small) could take significantly longer than later samples (where $N$ is large), inadvertently presenting an inverted curve. We may need to discard the first $X$ samples per method to let the JIT stabilize.
*   **Multi-Parameter Methods:** A method taking two arrays (`arr1`, `arr2`) has two axes of $N$. Doing multi-variable regression (e.g., $O(N \times M)$) expands the mathematical footprint considerably.
