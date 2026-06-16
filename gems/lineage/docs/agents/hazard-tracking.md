# Hazard Tracking: Persistent Safety Constraints

This document outlines the design for tracking "Safety Hazards" (Atomics, Locks, Manual Memory) within the `Lineage` engine. By storing hazard tags at the logical-unit level, the toolchain ensures that safety requirements follow the code through renames and refactors.

## 1. Why Store Hazards in Lineage?

- **Rename Stability:** If a function containing an atomic hazard is moved from `io.zig` to `transport.zig`, Lineage ensures the hazard tag is preserved. Static lists or simple AST scans lose this historical context.
- **Temporal Lifecycle:** Lineage tracks the birth and death of hazards. A function may be a "Memory Hazard" in v1 (raw pointers) but become "Safe" in v2 (refactored to abstractions).
- **Verification Anchor:** By persisting hazards in SQLite, `SlopCop` can instantly query for "Verification Gaps" without re-scanning the entire repository AST.

## 2. Storage Model: The Hazard Ledger

The `logical_units` table in SQLite is extended to support multiple hazard types via a joined table.

```sql
CREATE TABLE unit_hazards (
    unit_id TEXT NOT NULL,
    hazard_type TEXT NOT NULL, -- "LOOM", "TSAN", "ASAN", "VOPR"
    detected_at_hash TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1, -- 0 if refactored away
    FOREIGN KEY(unit_id) REFERENCES logical_units(id)
);
CREATE INDEX idx_hazards_unit_id ON unit_hazards(unit_id);
```

## 3. Detection Strategy: Velocity vs. Precision

### Recommendation: Stick to Tree-sitter / Specialized Tools
While CodeQL is powerful for deep semantic analysis, it is **overkill** for "Hazard Tagging." Identifying that a function contains an `atomic.load` or a `Mutex` is a surgical syntactic task.

- **The Path:** Use the existing **Zig-backend tool** (and expand it via Tree-sitter for other languages) to identify "Dangerous Primitives" during the `lineage build` pass.
- **Why:** This is 100x faster than building a CodeQL database and much easier for contributors to extend. Precision is high because these primitives are explicitly named in the grammar.

## 4. GitHub Integration: The "Virtual Gutter"

GitHub does not support native custom gutters. To surface hazard gaps in PRs, `SlopCop` will use **SARIF-based Annotations**.

- **Output:** `SlopCop` generates a SARIF (Static Analysis Results Interchange Format) file.
- **Display:** Using the `github/codeql-action/upload-sarif` action, these findings appear as first-class "Check Annotations" directly beneath the offending line in the PR Files-Changed view.
- **Visual Impact:** A line with an unverified atomic load will receive a yellow/red warning card: *"Loom Gap: Atomic usage lacks visibility verification."* This provides the same value as a gutter icon with native UI support.
