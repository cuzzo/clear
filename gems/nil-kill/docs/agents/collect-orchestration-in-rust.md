# Moving `nil-kill collect` into Rust

Everything a collect *computes* is now Rust. What is left in `cli.rb` is the
sequence, the process spawning, and the transaction around the canonical
artifacts. This is what finishing that needs.

## What already moved

| was | is |
|---|---|
| `collector_export.rb` (474) | `nil-kill-collector-export` |
| `trace_artifact.rb` + `evidence_protocol` + `value_encoding` + `environment_claims` + `runtime_value_evidence` (~1,000) | `nil-kill-trace-document` |
| `scip_emitter.rb` (392 -> 130) | `nil-kill-scip-index` |
| `value_evidence_emitter.rb` (512) | deleted; `runtime-trace` was already the join |
| `evidence_merger.rb` (240) | `nil-kill-merge-evidence`, rebasing included |
| `function_inventory.rb` build | `nil-kill-function-inventory` |
| `trace_plan.rb` collector sidecar | `nil-kill-collector-plan` |

The stage sequence a collect runs is now: `trace-plan`, `function-inventory`,
`derive-domains`, `collector-export`, `shard-bookkeeping`, `trace-documents`,
`join (batched)`, `evidence-merge`, `scip-index` -- every one of them a
subcommand.

## The two things that cannot simply move

Both are Ruby *semantics*, in the same category as `declarations.c`, not
orchestration.

**`runtime_incremental_fingerprint`** digests a Ripper AST so that reformatting
a test file is not treated as a change. It is the key every stored snapshot is
built on. Re-implementing it over tree-sitter produces different digests, so
every stored snapshot invalidates and the next incremental collect degrades to
a full one. That is recoverable and one-time, but it is a behaviour change to
incremental collect and wants an explicit decision.

**`runtime_test_plan`** globs `test/**/*_test.rb` and `spec/**/*_spec.rb` and
builds one shard per test file. The globs are a small table; the surrounding
knowledge (which command shape means rspec vs minitest, how to rewrite a command
to run one file) is per-language.

The recommendation is a per-language shim: a small Ruby helper that answers
"plan this workload" as JSON, invoked the way the traced program is. Rust owns
everything else. That keeps the shape the rest of the migration established --
per-language code answers only what needs the language.

## What remains in `cli.rb#collect`

- Spawning one traced process per shard, with `NIL_KILL_RUNTIME_DIR`,
  `NIL_KILL_RUN_ID` and `NIL_KILL_SHARD_ID` in its environment. `run_id` is
  `"<generation>:<shard id>:<uuid>"`, and the traced program records it -- so it
  is the single source, and nothing downstream should be handed it separately.
- Scheduling those across `NIL_KILL_SHARD_JOBS` workers. `parallel::map_ordered`
  already does this shape.
- `Snapshot` (286 lines): which shards a `--fast` collect needs to rerun, from
  the previous manifest's fingerprints.
- `with_canonical_snapshot_transaction`: read the canonical artifacts, run the
  stages, restore them all on any exception. The paths are the merged evidence,
  the snapshot manifest, `runtime.scip.json`, the attestation, and the shard
  store.

## Verify it with

- `spec/golden_shard_spec.rb` -- the widest real shard, both halves of the
  shaping pinned byte for byte. Regenerate only with
  `tools/record_golden_shard.rb`, and only when a change to the document is
  intended.
- `spec/runtime_evidence_conformance_spec.rb` -- the merge oracle and the
  end-to-end oracle, both now going through the single join.
- `spec/runtime_snapshot_spec.rb` -- full, no-op, progressive and deletion-only
  collections against a real fixture. This is the one that covers the
  transaction.

**Pin a minitest seed before trusting an evidence diff.** Two collects of
identical code agree on 1,424 of 1,426 domain slots; the residue is
`state_targets` at `dependency_graph.rb:411`, observed empty in one run and
populated in another because minitest randomizes test order and espalier pins no
seed. Without a seed an evidence diff has a noise floor wide enough to hide a
real regression -- which is why the byte-level fixtures above, not the diff, are
what the ports were held to.

## One habit worth keeping

Three times in this migration a file looked like a duplicate of something Rust
already did. Twice it was. The third, `evidence_merger.rb`, did strictly more --
it rebased stored shards onto the current plan, which is what makes an
incremental collect possible -- and deleting it would have broken `--fast`
silently. `value_evidence_emitter.rb` looked dead from `nil-kill collect` and was
live on `collect-runtime`.

Grep the second entry point before believing a `git rm`.
