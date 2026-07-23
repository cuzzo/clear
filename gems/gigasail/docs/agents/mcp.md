# MCP server

`giga mcp` exposes `gigasail.db` - and, for a bounded set of static facts,
live disk content - to LLM coding agents over the Model Context Protocol.
Runs as a Rust subcommand (`src/ui/mcp.rs`) over the official [`rmcp`][rmcp]
SDK, alongside `giga lsp` and `giga ui`.

[rmcp]: https://crates.io/crates/rmcp

## Why 5 tools, not 17 tables

`gigasail.db` has 17 tables. A tool-per-table MCP surface would mean an agent
choosing among 17+ near-identical CRUD tools on every turn, which measurably
degrades tool-selection accuracy. Instead, each tool answers one workflow
question a coding agent asks before or during an edit, composing whichever
tables that question needs:

| Tool | Question it answers | Tables / source it reads |
|---|---|---|
| `giga_file_risk` | Should I be careful in this file/directory? | `logical_units`, `events`, `unit_hazards` |
| `giga_unit_context` | Give me everything about this function before I touch it | `logical_units`, `events`, `unit_hazards`, `unit_hotness`, `sarif_findings` - or, live disk + in-process hazard scan (see below) |
| `giga_verification_gaps` | Is this trustworthy, specifically why not? | `unit_hazards`, `current_sarif_findings` - or, live scan |
| `giga_change_history` | How fragile has this area been? | `events`, `crash_events` |
| `giga_find_definition` | Where is this defined? | `logical_units`, `events`, `engine_state` |

Query logic is reused, not reimplemented: three tools call the exact typed
`Storage` methods the UI/LSP already use
(`current_unit_spans_for_path`, `sarif_findings_for_path`,
`find_definitions` - the last of which gets the `engine_state`
incremental-build fast path automatically, since it's the same function the
LSP calls, not a re-derivation); the rest execute the same `.sql` files
under `sql/ui/runtime/` (`apply_hazards.sql`, `apply_hotness.sql`) or a
small direct query for a shape with no existing UI/LSP equivalent
(file-risk aggregation, change history).

## Running it

```bash
giga mcp --db gigasail.db --repo .
```

Point an MCP-capable client's stdio server config at that command. See
`gems/gigasail/test/mcp_server_test.rb` for a worked example driving it over
the real protocol, including the uncommitted-changes and DB-less cases
below.

Transport is stdio, **newline-delimited JSON** (one JSON-RPC message per
line) - per the MCP spec. This is *not* the same framing as LSP
(`Content-Length: N\r\n\r\n{json}`), despite looking superficially similar
as "stdio JSON-RPC." See "Findings from porting to Rust" below for how this
distinction was originally missed and how it was caught.

## Division of labor with the LSP

Both sit on the same query layer (several tools literally call the same
`Storage` methods the LSP/HTTP UI use) but serve different consumption
modes on purpose:

- **LSP**: passive, per-keystroke, editor-native (hover/gutter/codeLens/
  definition). Good for glanceable awareness while editing.
- **MCP**: active, on-demand, agent-invoked. Good for deliberate
  investigation before an edit, including cross-file questions
  (`giga_change_history`, directory-scoped `giga_file_risk`) that have
  no natural per-line LSP representation.

## Uncommitted and added-but-not-committed changes

**The question:** given a `gigasail.db` already built from committed
history, what's the most effective way to serve accurate results for a file
with uncommitted edits or a new, not-yet-committed file?

**Does Gigasail already do this? No - not as a general mechanism.** Two
narrow, pre-existing seams touch the problem, and neither solves it:

- `read_source` (`src/ui/ui.rs`) already reads live disk content when no
  commit is pinned (`commit: None`) - this is why the HTTP UI's source view
  and blame already reflect uncommitted edits for raw text display. It does
  nothing for hazards, coverage, hotness, or unit spans - those still come
  from the database as of the last build.
- `annotate_sarif_freshness` (`src/ui/ui.rs`) re-reads a SARIF finding's
  origin-commit blob and byte-compares it against currently-viewed content,
  setting `finding.stale = true/false`. This is SARIF-only, flag-only (it
  never remaps a finding's line number when content shifts above it), and
  has no equivalent for hazards, coverage, hotness, or unit spans.

Two things it does *not* have, confirmed by reading `git.rs` and
`engine.rs`: `GitProvider` is exclusively a committed-blob/tree reader
(`git2` `find_commit`/`find_blob`/`diff_tree_to_tree`) with zero
working-tree or index capability, and `LineageEngine::run_inner` requires a
real `VcsProvider::list_commits()` walk - there is no pseudo-commit or
working-tree injection path into the incremental engine.

**What was implemented:** `giga_unit_context` and
`giga_verification_gaps` now detect a dirty file via `git2`'s working-tree
status (`Repository::status_file`, checking `WT_NEW`/`INDEX_NEW` for
added-but-not-committed and `WT_MODIFIED`/`INDEX_MODIFIED` for uncommitted
edits to a tracked file - not `GitProvider`, which stays deliberately
committed-history-only; this is a new, narrowly-scoped use of `git2`
directly in `mcp.rs`). When the target file is dirty, the response gains a
`dirty` field and, for the languages Gigasail already hazard-scans
in-process, a separate `live_hazards` field:

```json
{
  "dirty": "uncommitted-changes",
  "hazards": [ /* last-known-commit data - may be stale */ ],
  "live_hazards": [ /* rescanned from disk just now */ ],
  "note": "path has uncommitted changes; `hazards` may be stale ..."
}
```

`live_hazards` is kept separate from `hazards` rather than silently merged
in, so a caller can always see both what the database currently believes
and what's actually on disk right now, and reconcile deliberately -
consistent with this session's "no silent truncation/substitution" pattern
elsewhere in Gigasail's tooling.

**Why this is cheap:** `hazard.rs`'s hazard scanner
(`hazard::scan_rust_sites`, `scan_go_sites`, `scan_zig_sites`, `scan_c_sites`,
`scan_cpp_sites`, `scan_csharp_sites`) already runs entirely in-process -
tree-sitter parse + `.scm` query match against an in-memory string, no
subprocess, no filesystem writes. `giga ingest-hazards` already calls
these same functions against corpus files; the MCP server just points them
at a single file's live disk content instead. Reusing them directly (made
`pub(crate)` for this) means the live-rescan path is the *same* hazard
detection logic as a full `ingest-hazards` run for these six languages, not
a parallel implementation that could drift.

**What this does *not* solve**, stated plainly rather than silently
degraded:

- **Coverage, mutation status, and hotness cannot be recomputed from source
  alone.** They are the output of actually *running* tests, mutators, or a
  profiler against the changed code - there is no static substitute. A
  dirty file's `current_line_cov`/`current_mutant_cov`/hotness numbers stay
  exactly what the last build recorded, and the response does not pretend
  otherwise.
- **Dynamic-language hazards (Ruby/Python/JS/TS/Java/Kotlin/Swift/Lua/PHP)
  have no in-process scanner in Gigasail's own binary** - those hazard
  queries only exist in `fact-mine`'s `.scm` files and are invoked via
  `ingest-hazards`'s corresponding provider running against a full corpus
  walk, not a single-file call Gigasail can make itself. Live-rescanning
  these would need a `fact-mine-rust` subprocess call (see DB-less mode
  below for the cost of that path) - not implemented for the dirty-file
  case, since it would add subprocess latency to every `unit_context` call
  on a dirty file in these languages. Flagged, not silently absorbed: the
  `note` field says explicitly when no live scanner exists for a file's
  language.
- **Line-remapping for the database's own stale hazards/findings is not
  attempted.** If a dirty edit inserts 3 lines above a hazard the database
  already knows about, that hazard's `line` field still points at its
  last-known-commit position, not its shifted position in the live file.
  Fixing this needs a real diff (`git2::Repository::diff_index_to_workdir`
  or equivalent) to build a line-remapping table, which is a meaningfully
  bigger feature than this pass built - noted here as the natural next
  increment on this design, not attempted speculatively.

**Test coverage.** `git_dirty_status`, `hazard_scan_fn`, `live_rescan_hazards`,
and `unit_context`'s dirty-detection branch have 100% line coverage
(`cargo llvm-cov`), almost entirely from in-process integration-style tests
in `src/ui/mcp.rs`'s `mod tests` - real temporary git repositories driven
through the actual `git` CLI (not mocked status objects), real per-language
source fixtures containing genuine hazard-triggering constructs, and golden
expected output (exact hazard types, line numbers, and snippets), plus the
existing end-to-end Ruby test over the real stdio protocol
(`test_unit_context_live_rescans_hazards_for_a_dirty_rust_file`). This is
load-bearing infrastructure for a CI-hosted product where every open PR is
"ahead of what the database knows" until merge, so it is tested as such -
not spot-checked.

## DB-less mode

**The question:** can MCP be useful with *no* `gigasail.db` at all - on
demand fact-mining per request, cached and invalidated?

`--db` is optional. Without it, `giga mcp --repo .` starts in DB-less
mode:

- `giga_unit_context` and `giga_verification_gaps` degrade to
  structure-plus-live-hazards: unit boundaries come from
  `HeuristicExtractor::extract_units` (`src/db/extract.rs`) - already fully
  git-decoupled, operating on an in-memory `BlobFile { path, contents }`,
  and already used this way elsewhere (`source_symbols_from_current_file`
  in `ui.rs`) - run directly against live disk content; hazards come from
  the same in-process scanners described above. No history, coverage,
  mutation, or hotness data exists without a database, and the response
  says so via its `note` field rather than returning empty arrays that look
  like "verified clean."
- `giga_file_risk`, `giga_change_history`, and
  `giga_find_definition` are fundamentally database-shaped questions
  (aggregate risk across a corpus, commit history, rename-stable identity
  across renames) with no live-recomputation equivalent. They fail with a
  clear `isError` message ("requires a gigasail.db; server was started
  without --db") rather than crashing or returning misleading partial data.

**The cost tiering that shapes what's feasible here** (measured this
session, single ~1000-line file):

| Tier | Cost | What it covers |
|---|---|---|
| In-process, no subprocess | ~microseconds | Unit structure (`HeuristicExtractor`, all languages); hazards for rust/go/zig/c/cpp/csharp (`hazard.rs`'s own scanners) |
| `fact-mine-rust` subprocess, single file | ~200-250ms, 2-2.7MB JSON (full mode; most of ~40 fact categories irrelevant to any one MCP tool) | Hazards for the 9 dynamic languages; richer syntax facts (imports, call sites, effect summaries) not currently surfaced by any tool |
| Multi-file/corpus-context tools | Not on-demand-per-file feasible at all | Decomplex complexity/Big-O (needs cross-function comparison for duplicated-decision detection); Espalier architecture (needs the whole-repo dependency graph) |

Only the first tier is implemented, because it's what the current 5 tools
actually need for a DB-less path. The second tier - shelling out to
`fact-mine-rust` per request - was deliberately *not* built this pass,
because it needs the caching/invalidation design below to not be wasteful
on repeated calls, and no current tool has a DB-less need that tier one
can't already serve.

**Caching/invalidation design for the subprocess tier** (designed, not yet
implemented - there is nothing to cache until a tool needs tier two):

- Cache key: SHA-256 of the file's live content, not path+mtime. mtime is
  unreliable across git checkouts, editor saves-without-changes, and
  container/CI filesystems that don't preserve it; content hashing is the
  same invalidation primitive `annotate_sarif_freshness` already uses
  (byte-compare against blob content) rather than a new one.
- Cache location: `<repo>/.gigasail-mcp-cache/<sha256>.json`, one file per
  distinct `(fact-mine flags, file content)` pair (the flags matter because
  `syntax-facts` supports scoped extraction; a full-mode cache entry cannot
  serve a narrower request cheaply without re-filtering, so it is keyed
  separately... unless the on-demand call always requests the same fixed
  fact subset per tool, in which case a single flag set removes this
  wrinkle entirely - the simpler design to build first).
- Invalidation is implicit: a changed file hashes to a different key, so
  stale entries are simply never looked up again, not actively evicted.
  Eviction (deleting orphaned cache files for content that no longer
  exists anywhere in the working tree) is a housekeeping concern, not a
  correctness one - safe to defer to a periodic sweep or leave to normal
  `.gitignore`d directory growth, matching how `target/` is already treated
  in this repo.
- Payload trimming: cache the tool-relevant subset of `fact-mine`'s output
  (e.g. `hazard_sites` for a hazard-shaped request), not the full 2-2.7MB
  payload - matches the existing "5 tools, not 17 tables" philosophy of
  shaping data around the question being asked, not the source's native
  shape.

## MVP scope and known gaps

- **No `lineage_architecture_neighborhood` tool.** The architecture graph
  (`architecture_*` tables) needs an Espalier ingestion run, which is Ruby-
  focused; there was no architecture data to validate this tool against for
  Gigasail's own (Rust) codebase, so it was cut from the MVP rather than
  shipped unvalidated.
- **`giga_verification_gaps` on a directory prefix returns raw active-
  hazard counts, not the verified/unverified evidence join** a single-file
  lookup gets via `apply_hazards.sql`. Exact-file lookups get full fidelity;
  directory-prefix lookups trade fidelity for coverage. Noted in the tool's
  own response (`note` field) when this simplification is in effect.
- **No repo-root/path-traversal validation on `path` arguments.** Every
  query is read-only and parameterized (no SQL injection surface), but a
  malicious or buggy `path` value is not currently rejected before it
  reaches SQLite or the filesystem. Low risk given the read-only,
  single-purpose scope, but worth hardening before wider deployment.
- **Line-remapping for stale DB data on a dirty file is not implemented**
  (see "What this does not solve" above).
- **DB-less mode's subprocess tier (dynamic-language hazards, richer
  fact-mine output) is designed but not implemented** (see "DB-less mode"
  above) - no tool currently needs it.
- **Skill guidance for *when* to call these tools does not exist yet** -
  this MVP is the server; the calling convention (call `giga_unit_context`
  before editing unfamiliar code, `giga_verification_gaps` before
  trusting a coverage number, etc.) needs to live in a SKILL.md, not here.

## Findings from dogfooding

Validated against a real `gigasail.db` built for Gigasail's own repository -
300 commits of real git history, real `cargo llvm-cov` coverage, and a real
`ingest-hazards --provider rust` scan - not synthetic fixtures. Building
that corpus is itself a finding: 300 commits took ~30s, but a full
coverage run took over a minute and produced 2.1GB of `llvm-cov-target`
build cache. "Point the MCP server at your repo" is not a zero-setup
story; populating a genuinely useful `gigasail.db` needs the same
build/coverage/hazard pipeline CI already runs, scheduled or cached, not
run ad hoc per investigation.

**The tool is real, not a toy - it caught something true in code written
minutes earlier.** `giga_verification_gaps` on `src/ui/lsp.rs` flagged
the `documents: Arc<Mutex<HashMap<Url, String>>>` field added for this
session's go-to-definition fix as `rust_loom_concurrency`, evidence
`concurrency`, currently unaddressed - a real, non-obvious signal, not a
hallucination or a stale finding, produced by a plain tool call with no
manual review.

**One call surfaced a real prioritization signal with zero custom
analysis.** `giga_file_risk("gems/gigasail/src/ui/")` showed the HTTP
controllers (`architecture.rs`, `index.rs`, `source.rs`: 8.6-20.8%
coverage) sitting far below the core logic they call into (`ui.rs`,
`lsp.rs`: 72.8-86.8%) - a genuine "review this next" candidate a human
would otherwise have to notice by eyeballing multiple files.

**Rename-stable identity - Gigasail's actual core value proposition -
survives the MCP layer intact.** `giga_unit_context` on a moved
function (`apply_espalier_effect_spans`) correctly reported one continuous
history (`CHANGE` + `MOVE`) and the unit's current post-move span, not two
disconnected identities. This wasn't a given; it would have been easy for
a hand-rolled MVP query to silently break that guarantee.

**Dogfooding found and fixed a real usability gap in the original Ruby
MVP.** Both `giga_unit_context` and `giga_verification_gaps`
originally dropped the hazard's actual source line (`unit_hazards.source`,
exposed as `snippet`) even though the reused query already carried it -
every hazard result forced a redundant file read just to see what was
flagged. Found by feeling the friction firsthand on real output, not by
inspection; fixed and covered by assertions in `mcp_server_test.rb`, and
preserved through the Rust port.

**`find_definition` is a genuine complement to the LSP, not a duplicate.**
It resolved `hover_for_line` to its real definition site with no IDE, no
LSP client, no editor in the loop at all - useful specifically for an
agent working through file tools alone, which is the majority of current
coding-agent deployments.

**Known limitation surfaced, then fixed.** `giga_file_risk`'s
`avg_line_coverage`/`avg_mutant_coverage` were unweighted averages across a
path's units, so a 3-line getter and a 200-line function counted equally.
Didn't matter for the finding above (8-20% vs 72-86% is stark either way),
but a file dominated by many tiny well-tested units and one large
undertested one could have reported a misleadingly healthy average -
exactly the kind of error that erodes trust in an aggregate "here's your
grade" score. Fixed by weighting each unit's contribution by its current
line count (`end_line - start_line + 1`, using the same first-commit
fallback chain as `current_unit_spans_for_path.sql`), with units missing
a coverage value excluded from both the numerator and denominator rather
than treated as zero. Covered by
`test_file_risk_weights_coverage_by_unit_line_count`, which proves the
before/after concretely: a naive flat average of a 100%-covered 3-line
function and a 10%-covered 14-line function is 55.0; the size-weighted
result is 25.9.

## Findings from porting to Rust

**The original Ruby MVP's transport framing was wrong, and its own test
could never have caught it.** The MVP's docstring and this doc both
described its stdio transport as "Content-Length framed, matching LSP" -
which is false for MCP. The real spec uses newline-delimited JSON: one
JSON-RPC message per line, no headers. The Ruby MVP's hand-rolled server
*and* its hand-rolled test client both implemented the same wrong framing,
so `mcp_server_test.rb` passed 14/14 assertions while testing a server that
could never have completed a handshake with an actual MCP client (Claude
Code, Claude Desktop, or any spec-compliant implementation). Porting to
`rmcp` - the official, spec-compliant Rust SDK - surfaced this immediately:
the real server correctly waited forever for a newline-terminated message
that a Content-Length-framed test client never sent, which read as a hang,
not a clean protocol error. The fix was two lines in the test client
(`read_message`/`write`); the finding is the reminder that a hand-rolled
protocol implementation validated only against its own hand-rolled test
double proves self-consistency, not spec compliance - using a real SDK on
at least one side of a protocol boundary is what actually catches this
class of bug.

**Reuse over re-derivation held up under porting, and paid off
immediately.** `find_definition`'s Rust version calls
`Storage::find_definitions` directly instead of re-executing
`find_definitions.sql` as raw text (the Ruby MVP's approach, forced by not
linking against `Storage`) - and `find_definitions` already consults the
`engine_state` incremental-build checkpoint before falling back to the
static query. That fast path was a documented MVP gap in the Ruby version
("skips the engine_state fast path"); the Rust port gets it for free
simply by calling the same typed method the LSP calls, with no
MCP-specific code for it at all.

**A pre-existing hazard-classification bug surfaced through the new live-
rescan tests, unrelated to this port.** `hazard::evidence_for_hazard`
classifies required evidence by substring match on the hazard type name;
`"rust_unsafe_block".contains("lock")` (b-**lock**) matches its
`"race"`-evidence branch before the intended `"unsafe_block"` ->
`"miri"` branch is reached, so unsafe-block hazards are labeled with the
wrong required-evidence type. Confirmed by testing the new live-rescan
feature against a real `unsafe {}` block. Documented here rather than
fixed in this pass - it is a pre-existing classification bug in shared
hazard-labeling logic, not something introduced by or specific to the MCP
work, and fixing it deserves its own test and its own commit per this
repo's bug-fixing discipline, not a drive-by change bundled into a
protocol/design change.

**Adding a new dependency (`rmcp`) required freeing disk first.** The dev
VM was at 99% disk (1.6G free) when this work started, mostly gitignored
Rust build cache (`gems/gigasail/target`, 3.4-4.2G, safely removable via
`cargo clean` - confirmed gitignored before deleting) plus several
gigabytes of other sessions' scratch output under `/tmp` and this repo's
own `tmp/` (left untouched - not confirmed safe to delete, unlike the
build cache). `cargo clean` alone provided enough headroom to add `rmcp`
and its transitive dependencies and build. Worth remembering before any
future `cargo add` on this box: check `df -h` first, and prefer cleaning
known-regenerable build caches over broader `/tmp` sweeps.
