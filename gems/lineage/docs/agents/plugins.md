# Lineage Plugin System Findings

## Verdict

Build a plugin system, but keep the first version deliberately boring:
plugins should be external adapters that parse provider-specific inputs
and emit a stable Lineage ingest envelope. Lineage core should still own
commit validation, source verification, line-to-logical-unit mapping,
transactions, and database writes.

Do not start with in-process Lua plugins or dynamically loaded Rust
plugins. That is overkill right now. Dynamic Rust plugins create ABI,
versioning, build, and safety problems; embedded Lua adds another
runtime and makes database writes harder to audit. The useful boundary is
not "run arbitrary code inside Lineage"; it is "let arbitrary tools
normalize side-inputs into a contract Lineage can verify."

The right architecture is:

1. Built-in Rust adapters for first-party/common providers.
2. External executable plugins for everything else.
3. A stable JSON ingest envelope between the plugin and Lineage.
4. A generic `plugin_events` table for provider-specific payloads, plus
   promotion into first-class tables when a provider becomes common.

## Why This Is Worth It

Coverage is already proving the problem: Codecov gives line coverage,
but the meaning often comes from outside the report. CI job names,
artifact names, flags, and paths tell us whether the coverage came from
unit tests, integration tests, transpile tests, fuzzing, Zig runtime
tests, or examples. That classification should not be hardcoded into one
Codecov parser forever.

Mutation data has the same shape but different semantics. Mutant,
mutation-testing tools for other languages, and future provider outputs
need to map into:

- current mutation kill rate
- hard gate status
- killed/survived/timed-out/error counts
- test type or verification profile
- optional provider-specific details

Stack traces are another version of the same problem. The provider
parses a format, but Lineage must verify the commit and source lines
before trusting it.

So yes, a plugin system is worth it. The overkill part would be giving
plugins direct database authority or loading arbitrary code into the
Lineage process.

## Ownership Boundary

Plugins should own:

- parsing external input files or API responses
- extracting commit identity or asking the caller to supply it
- extracting raw frames, path/line records, coverage rows, mutation rows,
  provider IDs, timestamps, labels, and provider-specific payloads
- classifying provider-specific meaning such as `unit`, `integration`,
  `fuzz`, `transpile`, `runtime`, or `mutant`

Lineage core should own:

- verifying the commit exists in `metadata`
- reading source at that commit
- checking optional context lines/snippets
- mapping file/line/function to a logical unit
- deciding whether an unverified record is accepted, flagged, or dropped
- writing standard tables
- writing generic plugin payloads
- maintaining schema compatibility

This keeps the database trustworthy. A bad plugin can emit bad proposed
records, but it cannot silently poison logical-unit identity or bypass
verification.

## Recommended Plugin Interface

Use an external process interface:

```sh
lineage ingest-plugin \
  --db lineage.db \
  --repo . \
  --plugin ./tools/lineage-mutant-plugin \
  --input mutant-results.json \
  --commit "$GITHUB_SHA"
```

Lineage invokes the plugin with a small JSON request on stdin:

```json
{
  "lineage_plugin_api": 1,
  "repo": "/repo",
  "input": "mutant-results.json",
  "commit": "abc123",
  "hints": {
    "provider": "mutant",
    "artifact_name": "ruby-mutant-unit",
    "test_type": "unit"
  }
}
```

The plugin writes a normalized response on stdout:

```json
{
  "lineage_plugin_api": 1,
  "provider": "mutant-ruby",
  "provider_version": "0.12.0",
  "records": [
    {
      "kind": "quality_metric",
      "metric": "MUTANT_COV",
      "value": 83.3,
      "path": "src/ast/type.rb",
      "line": 65,
      "function": "with",
      "test_type": "unit",
      "context_line": "def with(",
      "payload": {
        "killed": 25,
        "survived": 5,
        "timeout": 0,
        "error": 0
      }
    },
    {
      "kind": "quality_metric",
      "metric": "GATE_STATUS",
      "value": 1.0,
      "path": "src/ast/type.rb",
      "line": 65,
      "function": "with",
      "test_type": "unit",
      "payload": {
        "gate": "required",
        "threshold": 80.0
      }
    }
  ]
}
```

The same envelope can represent stack frames:

```json
{
  "kind": "crash_frame",
  "provider_id": "sentry-event-123",
  "error_class": "RuntimeError",
  "path": "/app/src/ast/type.rb",
  "line": 81,
  "function": "with",
  "context_line": "next_ownership = T.let(...)",
  "payload": {
    "release": "abc123",
    "environment": "production"
  }
}
```

And classified coverage:

```json
{
  "kind": "quality_metric",
  "metric": "LINE_COV",
  "value": 97.4,
  "path": "zig/lib/atomic_ptr.zig",
  "test_type": "fuzz",
  "payload": {
    "provider": "codecov",
    "flag": "zig",
    "artifact": "zig-coverage-fuzz-3"
  }
}
```

## Database Shape

Keep the existing first-class tables:

- `quality_events`
- `crash_events`

Add a generic payload ledger:

```sql
CREATE TABLE plugin_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider TEXT NOT NULL,
  provider_version TEXT,
  kind TEXT NOT NULL,
  unit_id TEXT,
  commit_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  path TEXT,
  line INTEGER,
  function TEXT,
  test_type TEXT,
  is_verified INTEGER NOT NULL CHECK (is_verified IN (0, 1)),
  payload_json TEXT NOT NULL,
  FOREIGN KEY(unit_id) REFERENCES logical_units(id)
);

CREATE INDEX idx_plugin_events_provider ON plugin_events(provider);
CREATE INDEX idx_plugin_events_unit_id ON plugin_events(unit_id);
CREATE INDEX idx_plugin_events_commit_hash ON plugin_events(commit_hash);
CREATE INDEX idx_plugin_events_kind ON plugin_events(kind);
```

This is preferable to letting plugins create arbitrary side tables in the
MVP. Arbitrary plugin DDL makes migrations, compatibility, and query
safety much harder. If a plugin becomes important enough to need
specialized query performance, promote it to a first-class table later.

For Mutant specifically, the generic payload is enough at first. If it
proves valuable, promote to:

```sql
CREATE TABLE mutation_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id TEXT NOT NULL,
  commit_hash TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  test_type TEXT,
  killed INTEGER NOT NULL,
  survived INTEGER NOT NULL,
  timeout INTEGER NOT NULL,
  error INTEGER NOT NULL,
  kill_rate REAL NOT NULL,
  is_hard_gated INTEGER NOT NULL CHECK (is_hard_gated IN (0, 1)),
  payload_json TEXT NOT NULL,
  FOREIGN KEY(unit_id) REFERENCES logical_units(id)
);
```

## Built-In vs External Plugins

Use built-in Rust adapters for providers we expect to support directly:

- Codecov coverage
- GitHub artifact coverage
- Sentry stack traces
- Mutant results once the shape is stable

Use external executable plugins for project-specific or ecosystem-
specific providers:

- custom CI artifact classifiers
- language-specific mutation tools
- proprietary error-reporting exports
- one-off migration/backfill scripts

External plugins can be written in Rust, Lua, Ruby, Python, JavaScript,
or anything else. Lineage should not care as long as stdout is valid
JSON.

## Lua and Rust Assessment

Lua embedded in Lineage is not worth it for the MVP. It makes sense only
if we need lightweight user-defined transformations after the ingest
envelope is stable.

Rust dynamic plugins are also not worth it for the MVP. Rust does not
provide a stable dynamic plugin ABI by default. A compiled Rust plugin
as a separate executable is fine and likely ideal for fast providers.

If we eventually need sandboxed in-process plugins, WASM is a better
candidate than native dynamic libraries. That should wait until the
external JSON contract has proven insufficient.

## Minimal Implementation Plan

1. Add `lineage ingest-plugin --plugin CMD --input PATH`.
2. Define `lineage_plugin_api: 1` request/response JSON.
3. Add `plugin_events`.
4. Route `quality_metric` records into `quality_events` plus
   `plugin_events`.
5. Route `crash_frame` records into `crash_events` plus
   `plugin_events`.
6. Store records with `is_verified=0` when context mismatches, unless
   the command uses a strict mode that rejects them.
7. Add one fake Mutant plugin fixture and one fake Codecov classifier
   fixture.

## Recommendation

Do the plugin system, but keep it as a normalized ingest adapter layer.
Do not give plugins direct database writes yet. This will let Lineage add
Mutant, richer Codecov/GitHub artifact classification, Sentry-like
providers, and language-specific quality tools without turning the core
engine into a pile of provider-specific parsers.

## Future Language Test Matrix

To verify the generalization of the toolchain (Lineage, Boobytrap, SlopCop, Decomplex, Nil-Kill, Espalier), the following repositories are identified as "Gold Standard" test targets for tomorrow’s fire drill and future language support verification. These repos are in the 10k–25k LOC range with high-alpha logic and rigorous test suites.

| Language | Repository | Approx. LOC | Test Target Focus |
| :--- | :--- | :--- | :--- |
| **C** | **[libuv](https://github.com/libuv/libuv)** | ~25,000 | **Lineage:** Rename stability and deep temporal risk tracking. |
| **C++** | **[Google Test](https://github.com/google/googletest)** | ~20,000 | **SlopCop:** TSan/Loom gap detection in self-hosted test logic. |
| **C#** | **[Polly](https://github.com/App-vNext/Polly)** | ~15,000 | **VOPR:** Resiliency and retry-loop simulation coverage. |
| **Java** | **[Gson](https://github.com/google/gson)** | ~15,000 | **Nil-kill:** Complex reflection and nullability edge cases. |
| **Kotlin** | **[Moshi](https://github.com/square/moshi)** | ~12,000 | **Type Pressure:** Native null-safety (the `?` syntax). |
| **Swift** | **[Alamofire](https://github.com/Alamofire/Alamofire)** | ~18,000 | **Espalier:** High-fidelity async delegation mapping. |
| **Lua** | **[Lapis](https://github.com/leafo/lapis)** | ~15,000 | **Universal Syntax:** Testing Tree-sitter normalization boundaries. |

### Fire Drill Protocol
1. **Lineage Build:** Run `lineage build` to verify performance and logical identity stability.
2. **Decomplex Audit:** Run `decomplex report` to verify "Decision Pressure" and "Root Cause" accuracy.
3. **SlopCop Check:** Verify "Constraint-Aware Coverage" (e.g., Go race-detector/Zig Loom gaps).
4. **Nil-Kill Inference:** Run Nil-Kill to verify SMT solver consistency across language-specific type systems.
