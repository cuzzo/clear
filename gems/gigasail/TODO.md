# GigaSail TODO

## Speed up architecture-graph ingest (batched inserts)

Dogfooding on CLEAR (`compiler/ruby`, 21.7k nodes / 66.7k edges / 106k spans)
`ingest-architecture` took ~59s while the espalier analysis that produced the
graph took ~23s - ingest is the bottleneck. Likely per-row inserts and a
`reconcile_logical_unit` SELECT per node (7.2k). Batch the node/edge/span inserts
in one prepared statement / multi-row transaction and cache/join the unit
reconciliation, so per-commit analysis ingest is seconds, not a minute. This
directly gates the premerge/sync overhead the README dogfooding section reports.

## Prune stale analysis reports on sync (branch-aware)

On a new `giga sync`, reclaim disk by deleting persisted analysis reports that
are no longer up to date — the large ones especially (e.g. nil-kill's
static/evidence intermediates, which are tens of MB even for a small repo).

Doing this correctly requires **branch knowledge**, because "old" is not the
same as "superseded":

- **Two commits in-line on a single branch** (one is an ancestor of the other,
  no branch point between them): keep the evidence for **each**. A diff can be
  requested against either, so both are live.
- **One commit at a branch base and another off of it** (a fork point plus a
  commit on the child branch): keep **each**. They are on different lines of
  history and both are reachable review targets.

Only delete an artifact when **all** of these hold:

1. **Sequential** — it is superseded by a newer artifact on the *same* line of
   history (a linear ancestor chain with no intervening branch/merge that keeps
   the older commit independently reachable).
2. **Not needed for incremental processing** — the engine's per-commit
   `engine_state` resume checkpoint (and anything else the incremental indexer
   reads back) must not depend on it. Never delete an artifact the incremental
   path would re-read.
3. **Truly temporary** — any artifact meant to be scratch and cleaned after
   every run regardless of history (if such a class exists) is always removed.
   (Producer intermediates like nil-kill static/evidence are already kept in a
   `.giga/scratch-*` dir and deleted per run — those are the model; the durable
   *ingested* reports are what this task is about.)

Implementation notes:
- Needs a reachability/branch model over the commits that have persisted
  artifacts (`sarif_artifacts`, `architecture_artifacts`, coverage/mutation
  events, run-store `runs/`), not just a timestamp sort.
- The gzipped run-store artifacts under `.giga/artifacts/runs/` are the durable
  raw copies; pruning should consider both the DB rows and the run dirs.
