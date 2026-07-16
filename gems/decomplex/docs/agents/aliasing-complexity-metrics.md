# Aliasing and Ownership Complexity Metrics

This document outlines the expansion of Decomplex to include pointer-aliasing and ownership detection. These metrics transform Decomplex from a heuristic structural analyzer into a semantic fact-engine capable of driving high-accuracy transpilation to CLEAR's affine ownership model.

## Metric Tiers

### Tier 1: High Confidence / Structural Hazards
**Metric: Encapsulation Breach**
- **Description**: Detects when a class returns a mutable reference to an internal state field (`@ivar`) without a copy (`.dup` / `.clone`) or conversion.
- **Architectural Risk**: Violates "Fortress Architecture" principles. It allows external callers to bypass class invariants and validation by mutating state "from the outside."
- **CLEAR Impact**: Identifies sites where CLEAR must either enforce a `COPY` or wrap the field in a read-only borrow.

### Tier 2: Design Pressure / Structural Risk
**Metric: Aliasing Tangle (Action-at-a-Distance)**
- **Description**: Identifies single objects that are aliased across three or more disparate modules/subsystems.
- **Architectural Risk**: Creates "tangled webs" where mutation in one module causes unpredictable behavior in another. This is the primary driver of "locality drag"—where a developer must understand 5 files to change 1.
- **CLEAR Impact**: Signals that a resource requires a Group 1 capability (e.g., `@shared:locked` or `@shared:writeLocked`) rather than simple affine move semantics.

### Tier 3: Strategic / Project Context
**Metric: Entanglement Density**
- **Description**: An aggregate heatmap quantifying the ratio of aliased references to total references within a file or directory.
- **Architectural Risk**: High-density files are objectively harder to refactor, test, and reason about. They represent the "dark matter" of the codebase where most regressions occur.
- **CLEAR Impact**: Prioritization metric. Files with low entanglement density are "low-hanging fruit" for 98% automated transpilation. High-density files require manual architectural review before migration.

## Implementation Strategy

The implementation leverages a two-pass semantic analyzer within `gems/decomplex/lib/decomplex/`:

1.  **Escape & Reachability Pass**:
    - Extends `LocalFlow` to track def-use chains across method boundaries.
    - Builds a **Reachability Graph** to determine if an object allocated in Scope A can reach Scope B via return, argument passing, or field assignment.

2.  **Ownership Synthesis**:
    - Aggregates escape facts to classify bindings as `Unique`, `Borrowed`, or `Shared`.
    - Detects "Reification Misses" where a developer intended for an object to be private but allowed it to escape via a getter.

## Transpiler Bridge

When the CLEAR transpiler processes Ruby code, it queries the Decomplex fact-graph:

- **Fact: Unique** -> Transpile to `GIVE` (Move).
- **Fact: Borrowed** -> Transpile to `WITH ... AS alias` (Borrow).
- **Fact: Shared** -> Transpile to `@shared:locked` (Arc/RwLock).
- **Fact: Escaped Field** -> Transpile to `RETURN COPY field` or `@boxed` wrapper.
