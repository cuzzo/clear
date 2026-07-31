# `nil-kill collect` in Rust

A collect runs no Ruby but the program it is tracing. This is what that means
and where the parts are.

## The stages

`nil-kill collect [--fast] -- <command...>` is one FactMine subcommand,
`nil-kill-collect`, which runs the rest as its own invocations: `trace-plan`,
`function-inventory`, `derive-domains`, `collector-export`,
`shard-bookkeeping`, `trace-documents`, `join`, `evidence-merge`,
`scip-index`. `src/collect.rs` owns the order, the environment each traced
program is given, and the transaction around the canonical artifacts.

The Ruby entry point `exec`s the binary, so `nil-kill collect` behaves the same
however it was reached.

## What an increment decides

`--fast` compares the stored manifest against the current source:

| | |
|---|---|
| `snapshot::select` | which shards must rerun |
| `snapshot::{load,write_full,write_incremental,mark_stale}` | the manifest |
| `source_fingerprint` | whether a file changed |
| `workload_plan` | one shard per test file |
| `function_inventory` | stable function identity across an edit |

A shard reruns when a test it owns changed or a function it depended on did.
Anything that cannot be attributed to a shard falls back to a full collect --
it is always sound to rerun everything and never sound to skip a shard whose
evidence might be stale.

The per-shard evidence lives in `runtime/shard-evidence/`, and a collect merges
this run's shards with the stored ones. That store moves inside the same
transaction as the canonical evidence, the index and the attestation: half of a
new set beside half of an old one describes a state that never existed.

## The fingerprint

A collect must not retrace a file that was only reindented. Ruby answered that
with a digest of a Ripper tree; FactMine digests the tree-sitter parse -- node
kinds and the token text that carries meaning, positions and comments left out.
Magic comments stay in, because the VM reads them as directives.

It is a different digest for the same source, so `fingerprint_scheme` moved
with it. A snapshot written under the old scheme is not stale, it is
unreadable, and `load` says so rather than comparing digests that meant
something else.

The manifest's environment is the interpreter binary's digest rather than
`RUBY_VERSION` -- askable without a Ruby, and stricter: a rebuilt patch release
re-collects.

## Verify it with

- `cargo test --test incremental_collect` -- a no-op, a reformat, an edit that
  reruns one shard, an added test, a support file, a deleted test, a failing
  shard and the recovery after it. The assertion that matters is that the
  evidence after an increment equals a full collect's over the same source.
- `spec/golden_shard_spec.rb` -- the widest real shard, both halves of the
  shaping pinned byte for byte. Regenerate only with
  `tools/record_golden_shard.rb`.
- `tests/value_domain_parity.rs` -- 647 raw/domain pairs.

**Collect a fixture under a root that is not this repository.** Three path
bugs shipped because every test collected easy-vm itself, where the collector
object and the FactMine binary happen to be under the analyzed root.

**Pin a workload seed before trusting an evidence diff.** `SEED` is set for
every shard because minitest and RSpec both order tests from it; without one
the diff has a noise floor wide enough to hide a regression.

## Still open

- A collect that produces zero coverage should be refused. Ruby had
  `assert_collect_coverage_produced!` for this, already unwired before the
  migration and deleted with it; FactMine has no equivalent.
- `runtime_evidence_conformance`'s
  `shared_negative_controls_fail_closed_at_the_protocol_boundary` fails:
  `validate_runtime_evidence` accepts evidence the control expects rejected.

## One habit worth keeping

Three times in this migration a file looked like a duplicate of something Rust
already did. Twice it was. The third, `evidence_merger.rb`, rebased stored
shards onto the current plan -- which is what makes an incremental collect
possible -- and deleting it would have broken `--fast` silently.
`value_evidence_emitter.rb` looked dead from `nil-kill collect` and was live on
`collect-runtime` -- a command that has since been deleted, because tracing the
whole chain showed no language could reach the emitter behind it.

Grep the second entry point before believing a `git rm`.
