# Universal Stack Trace Support: Verification-Anchored Ingestion

This document outlines the design for ingesting external crash data (e.g., Sentry stack traces) into the `Gigasail` engine. The system is designed to anchor runtime errors to specific AST units (Logical IDs) using a pluggable, two-layered adapter architecture.

## 1. The Goal: Historical Verification

The objective is not just to store crash data, but to **anchor** it to the "Ground Truth" of the source code history. This enables `Boobytrap` to identify "Zombie Bugs"—defects that survive structural refactoring—by linking traces from different releases to the same persistent Logical Unit ID.

## 2. Pluggable Architecture

To handle the diversity of error providers and runtime environments, the system uses a two-layered transformation pipeline.

### Layer 1: Provider Adapters (`ProviderTrait`)
This layer parses the external format of an error tracking service.
- **Task:** Extract raw frames (file, line, function) and the associated `commit_hash`.
- **Implementations:** `SentryAdapter`, `HoneybadgerAdapter`, `LogFileAdapter`.

### Layer 2: Language Normalizers (`LanguageTrait`)
This layer reconciles runtime paths with the repository root.
- **Task:** Strip environment-specific prefixes (e.g., Docker `/app/` paths), handle language-specific call-site quirks, and normalize function naming conventions.
- **Implementations:** `RubyNormalizer`, `PythonNormalizer`, `ZigNormalizer`.

## 3. The "Verification-Anchored" Pipeline

When a payload is ingested, the engine performs the following steps:
1. **Commit Lookup:** Verify that the `commit_hash` exists in the `metadata` table.
2. **Context Verification:** For each frame, if a source snippet is provided by the provider, the engine compares it against the source file at that commit.
3. **Mismatch Handling:** If the source snippet does not match the file at the specified line, the engine MUST flag the trace as "Unverified" or raise an error to prevent data poisoning.
4. **Logical Mapping:** The verified line/file is mapped to a **Logical Unit ID** using the existing `BoundaryExtractor`.
5. **Persistence:** The verified event is written to the `crash_events` table.

## 4. SQLite Schema Extension

```sql
CREATE TABLE crash_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    unit_id TEXT NOT NULL,          -- Anchored Logical ID
    commit_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    error_class TEXT,               -- e.g., "ZeroDivisionError"
    provider_id TEXT,               -- e.g., Sentry Event ID
    is_verified INTEGER NOT NULL,    -- 0 or 1
    FOREIGN KEY(unit_id) REFERENCES logical_units(id)
);
```

## 5. Implementation Roadmap

- **Core Traits (~100 LoC):** Define `ProviderTrait` and `LanguageTrait` in Rust.
- **Universal Bridge (~50 LoC):** Create an internal `IngestPayload` struct to unify provider data.
- **Ingestion Engine (~150 LoC):** Implement the verification and SQL persistence logic.
- **First Adapters:** Launch with `SentryAdapter` and `RubyNormalizer`.

## 6. Strategic Impact

Adding stack trace support transforms `Gigasail` from a Git parser into a **Real-World Risk Oracle**. It allows the toolchain to bridge the gap between "What the code looks like" (Structural) and "How it behaves in production" (Empirical).
