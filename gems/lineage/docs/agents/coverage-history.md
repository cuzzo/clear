# Coverage and Quality History: The "Delta" Model

This document outlines the design for ingesting and tracking coverage and mutation testing data over time within the `Lineage` engine. By anchoring quality metrics to the historical graph, the toolchain can answer the critical question: *"Is this fragile code getting safer or more dangerous?"*

## 1. The Value of Historical Coverage

Historical coverage acts as the "Protection Axis" in the risk model.
- If a function has a high churn rate and multiple production crashes, it is high-risk.
- If that same function's mutation kill-rate jumps from 20% to 100% in a recent commit, the risk score should drop significantly because the "safety net" has been proven.
Tracking this metric over time allows `Boobytrap` to distinguish between "Historically Fragile" and "Currently Protected" code.

## 2. The "Delta" Storage Model (Aggregate Quality)

Storing full line-by-line coverage bitmasks for every commit would cause the SQLite database to bloat to gigabytes. Instead, `Lineage` stores **Aggregate Logical Metadata**.

The engine tracks the "Current Known State" of a Logical Unit and records Deltas over time.

### Tracked Metrics per Logical Unit:
- `last_unit_coverage` (%)
- `last_integration_coverage` (%)
- `last_mutant_kill_rate` (%)
- `is_hard_gated` (Boolean)
- `current_distinct_tests`
- `current_test_types`
- `current_mutant_verified_tests`
- `current_mutant_killed_tests`

When a new coverage artifact is ingested, the engine updates the current state of the Logical Unit and records a **Coverage Delta Event** (e.g., `Mutation coverage increased +40%`).

## 2.1 Named Test Exposure History

Aggregate coverage answers "how much of this unit was covered?" but it
does not answer "which tests hit this unit?" or "was that protection
mutation-verified?" `Boobytrap` needs that second shape to avoid
over-ranking code that was historically buggy but has since been covered
by meaningful tests.

`Lineage` therefore also stores a first-class `test_exposure_events`
ledger. Each row represents one named test hitting one logical unit at a
specific commit. Records may include:

- file/function/line/branch identity
- test id
- test type (`unit`, `integration`, `fuzz`, `zig-runtime`, etc.)
- optional mutation status (`killed`, `survived`, `timeout`, etc.)
- source verification status
- the original provider payload

Mutation status is optional by design. CLEAR has little historical
mutant coverage data, and most repositories will start with named test
exposure before they have mutation history. Missing mutation data must
remain neutral: it should not be treated as killed evidence or as a
survived mutant. When mutation facts are present, they can strengthen the
"currently protected" signal dramatically.

## 3. The "Three-Pass" Ingestion Pipeline

To ensure the integrity of the data and support flexible CI setups, ingestion is strictly decoupled into a three-pass model. The passes respect the lifecycle of data availability.

### Pass 1: The Backbone (Git/VCS)
- **Command:** `lineage build`
- **Execution:** First step. Builds the `logical_units` table and the commit graph. All subsequent passes anchor to the IDs generated here.

### Pass 2: The Empirical Feed (Stack Traces)
- **Command:** `lineage ingest --provider sentry ...`
- **Execution:** Async/Continuous. Ingests production events, maps them to commits and Logical IDs, and records `crash_events`.

### Pass 3: The Quality Feed (Coverage/Mutant)
- **Command:** `lineage ingest-coverage --format boobytrap ...`
- **Execution:** End of a CI run. Ingests `coverage.json` and `mutant.json` artifacts, mapping them to the specific commit and updating the Quality State of the associated Logical Units.

### Pass 4: The Named-Test Exposure Feed
- **Command:** `lineage ingest-test-exposure ...`
- **Execution:** End of a test run. Ingests `test-exposure/v1` facts,
  maps each record to source at the commit, and records one event per
  logical-unit/test hit. This feed is valuable even without mutation
  facts because it distinguishes thin single-test coverage from broad
  unit/integration/fuzz exposure.

**Why this works:**
- It allows historical backfilling (run Pass 1 over 2 years of history, run Pass 3 for the last 30 days of retained CI artifacts).
- It enables parallel CI jobs (Git traversal doesn't block coverage ingestion for a previous commit).

## 4. SQLite Schema Updates

To support the Quality Feed, the SQLite schema is extended:

```sql
-- Extend logical_units to cache the current quality state
ALTER TABLE logical_units ADD COLUMN current_line_cov REAL DEFAULT 0.0;
ALTER TABLE logical_units ADD COLUMN current_mutant_cov REAL DEFAULT 0.0;
ALTER TABLE logical_units ADD COLUMN is_hard_gated INTEGER DEFAULT 0;
ALTER TABLE logical_units ADD COLUMN current_distinct_tests INTEGER DEFAULT 0;
ALTER TABLE logical_units ADD COLUMN current_test_types TEXT DEFAULT '';
ALTER TABLE logical_units ADD COLUMN current_mutant_verified_tests INTEGER DEFAULT 0;
ALTER TABLE logical_units ADD COLUMN current_mutant_killed_tests INTEGER DEFAULT 0;

-- Create a ledger for quality events
CREATE TABLE quality_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    unit_id TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    metric_type TEXT NOT NULL,   -- 'LINE_COV', 'MUTANT_COV', 'GATE_STATUS'
    old_value REAL,
    new_value REAL,
    FOREIGN KEY(unit_id) REFERENCES logical_units(id)
);

CREATE TABLE test_exposure_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    unit_id TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    path TEXT NOT NULL,
    function TEXT,
    line INTEGER,
    branch_id TEXT,
    test_id TEXT NOT NULL,
    test_type TEXT NOT NULL,
    mutation_status TEXT,
    is_mutation_verified INTEGER NOT NULL,
    is_mutation_killed INTEGER NOT NULL,
    is_verified INTEGER NOT NULL,
    payload_json TEXT NOT NULL,
    FOREIGN KEY(unit_id) REFERENCES logical_units(id)
);
```

## 5. Strategic Verdict

Tracking aggregate coverage and mutation testing over time is a **Must Build** feature. By providing a database for this data, `Lineage` creates a "Quality Ledger." It completes the "Quadrants of Risk" (Structure, History, Production, Protection), allowing LLMs and developers to confidently refactor previously dangerous code.
