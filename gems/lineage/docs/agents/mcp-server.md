# MCP server (MVP)

`gems/lineage/tools/mcp_server.rb` exposes `lineage.db` to LLM coding agents
over the Model Context Protocol. Read-only, stdio JSON-RPC (same
Content-Length framing as `lineage lsp`), no MCP gem dependency - it
hand-rolls the small subset of the protocol a tool-calling agent actually
uses (`initialize`, `tools/list`, `tools/call`).

## Why 5 tools, not 17 tables

`lineage.db` has 17 tables. A tool-per-table MCP surface would mean an agent
choosing among 17+ near-identical CRUD tools on every turn, which measurably
degrades tool-selection accuracy. Instead, each tool answers one workflow
question a coding agent asks before or during an edit, composing whichever
tables that question needs:

| Tool | Question it answers | Tables it reads |
|---|---|---|
| `lineage_file_risk` | Should I be careful in this file/directory? | `logical_units`, `events`, `unit_hazards` |
| `lineage_unit_context` | Give me everything about this function before I touch it | `logical_units`, `events`, `unit_hazards`, `unit_hotness`, `sarif_findings` |
| `lineage_verification_gaps` | Is this trustworthy, specifically why not? | `unit_hazards`, `current_sarif_findings` |
| `lineage_change_history` | How fragile has this area been? | `events`, `crash_events` |
| `lineage_find_definition` | Where is this defined? | `logical_units`, `events` |

Query logic is reused, not reimplemented: each tool either executes one of
the exact `.sql` files under `sql/storage/`/`sql/ui/runtime/` that the Rust
UI and LSP already ship (`find_definitions.sql`, `apply_hazards.sql`,
`apply_hotness.sql`, `current_unit_spans_for_path.sql`,
`sarif_findings_for_path.sql`), or a small direct query for a shape with no
existing UI/LSP equivalent (file-risk aggregation, change history).

## Running it

```bash
ruby gems/lineage/tools/mcp_server.rb --db lineage.db --repo .
```

Point an MCP-capable client's stdio server config at that command. See
`gems/lineage/test/mcp_server_test.rb` for a worked example driving it over
the real protocol.

## Division of labor with the LSP

Both sit on the same query layer (several tools literally execute the same
`.sql` files the LSP/HTTP UI use) but serve different consumption modes on
purpose:

- **LSP**: passive, per-keystroke, editor-native (hover/gutter/codeLens/
  definition). Good for glanceable awareness while editing.
- **MCP**: active, on-demand, agent-invoked. Good for deliberate
  investigation before an edit, including cross-file questions
  (`lineage_change_history`, directory-scoped `lineage_file_risk`) that have
  no natural per-line LSP representation.

## MVP scope and known gaps

- **No `lineage_architecture_neighborhood` tool.** The architecture graph
  (`architecture_*` tables) needs an Espalier ingestion run, which is Ruby-
  focused; there was no architecture data to validate this tool against for
  Lineage's own (Rust) codebase, so it was cut from the MVP rather than
  shipped unvalidated.
- **`lineage_find_definition` skips the engine_state fast path.** The Rust
  `find_definitions` first consults an in-flight incremental-build
  checkpoint for freshness; this MVP goes straight to the static SQL query,
  which is what most callers get anyway once a build has settled.
- **`lineage_verification_gaps` on a directory prefix returns raw active-
  hazard counts, not the verified/unverified evidence join** a single-file
  lookup gets via `apply_hazards.sql`. Exact-file lookups get full fidelity;
  directory-prefix lookups trade fidelity for coverage. Noted in the tool's
  own response (`note` field) when this simplification is in effect.
- **No repo-root/path-traversal validation on `path` arguments.** Every
  query is read-only and parameterized (no SQL injection surface), but a
  malicious or buggy `path` value is not currently rejected before it
  reaches SQLite. Low risk given the read-only, single-purpose scope, but
  worth hardening before wider deployment.
- **Skill guidance for *when* to call these tools does not exist yet** -
  this MVP is the server; the calling convention (call `lineage_unit_context`
  before editing unfamiliar code, `lineage_verification_gaps` before
  trusting a coverage number, etc.) needs to live in a SKILL.md, not here.

## Findings from dogfooding

<!-- filled in after running the MVP against gems/lineage's own codebase -->
