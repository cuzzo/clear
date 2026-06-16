# Systems Test Coverage Detection: Beyond Line Coverage

This document outlines the design for "Constraint-Aware Coverage" in `SlopCop`. The goal is to ensure that high-risk systems code (Atomics, Locks, Manual Memory) is not just "covered" by unit tests, but verified by the appropriate specialized detectors (TSan, ASan, Loom, VOPR).

## 1. The Core Philosophy: "Not All Coverage is Equal"

Standard line coverage is a false security signal for systems programming. A line containing an atomic store can have 100% unit test coverage while remaining completely unverified against memory visibility races (Loom) or thread races (TSan).

`SlopCop` identifies these "Verification Gaps" by joining structural risk signals with type-tagged coverage data.

## 2. Integrated Architecture

The detection pipeline relies on the "Fact-Policy-Join" model:

1. **Identification (Decomplex):** Identifies "Dangerous Primitives" and "Non-deterministic Sites" (e.g., `atomic.load`, `Mutex.lock`, `File.open`, `ptr.offset`).
2. **Evidence (Boobytrap):** Ingests and stores **Type-Tagged Coverage** artifacts (e.g., `coverage.tsan.json`, `coverage.loom.json`, `coverage.vopr.json`).
3. **Judgment (SlopCop):** Joins the primitives with the tagged coverage. If a primitive exists without its required protection type, a high-severity citation is issued.

## 3. Required Protection Matrix

| Primitive / Logic | Required Protection | Failure Mode Caught |
| :--- | :--- | :--- |
| **Atomics** | **Loom** | Memory visibility / Instruction reordering |
| **Locks / Threads** | **TSan** | Data races / Deadlocks |
| **Pointer Math** | **ASan / UBSan** | Use-after-free / Alignment / Bounds |
| **I/O / Time / RNG** | **VOPR (Simulator)** | Combinatoric logic failures / Non-determinism |

## 4. Initial Scope: Zig-First

**Zig Baseline:** This functionality currently exists as a standalone internal tool for the Zig backend. The initial rollout of this generalized `SlopCop` feature will **only support Zig** to leverage the existing detection logic and backend safety culture.

Expansion to Rust (Loom/TSan) and Go (Race detector) is planned for the v0.2 milestone.

## 5. Implementation Roadmap

- **Phase 1: Tagged Ingestion.** Update `Boobytrap` to support a `--type` flag for coverage ingestion (e.g., `boobytrap ingest-coverage --type tsan`).
- **Phase 2: Primitive Mapping.** Add a `dangerous_primitives` fact export to the `Decomplex::Syntax::Provider` for Zig.
- **Phase 3: The Auditor.** Implement the `ConstraintAuditor` in `SlopCop` to perform the join and report gaps.

## 6. Verdict: Critical Differentiator

This feature transforms `SlopCop` from a standard linter into a **Systems Integrity Guardrail**. It provides a level of safety verification that is currently unavailable in any other general-purpose toolchain.

## 7. GitHub Integration: The "Virtual Gutter"

GitHub does not support native custom gutters. To surface verification gaps in PRs, `SlopCop` will use **SARIF-based Annotations**.

- **Output:** `SlopCop` generates a SARIF (Static Analysis Results Interchange Format) file.
- **Display:** Using the standard `github/codeql-action/upload-sarif` action, these findings appear as first-class "Check Annotations" directly beneath the specific line of code in the PR Files-Changed view.
- **Visual Impact:** A line with an unverified atomic load will receive a yellow/red warning card: *"Loom Gap: Atomic usage lacks visibility verification."* This provides the high-fidelity feedback of a gutter icon with native, non-intrusive UI support.
