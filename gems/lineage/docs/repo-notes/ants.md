# ants — Go

**Revision:** `107e37678122` · **Scope:** production root `*.go` files ·
**Result:** worker lifecycle and queue management are correctly prioritized;
no static result establishes a race, deadlock, or throughput defect.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 14 files, 120 methods, 57 fields; Type Next is intentionally absent for Go declarations. |
| Espalier | 96/120 bounds unknown (80.0%). `poolCommon` and worker-stack state are top pressure. |
| Decomplex | 33 convergences: `ReleaseContext`, `Release`, the three worker `run` variants, and pool creation. |

## Independent source audit

- `poolCommon.Release`/`ReleaseContext` transition pool state, close queues, and
  wait for worker completion. Their error/timeout branches are genuine
  concurrency lifecycle complexity.
- Worker `run` loops receive tasks, recycle workers, and honor release state.
  They are core synchronization paths; cloned generic/function variants are
  expected implementation families, not automatically bad duplication.
- Worker-stack operations and purging determine queue/idle-worker behavior.
  Their time depends on worker count and scheduling; callbacks/goroutines make
  a simple static latency bound inappropriate.

## Assessment and follow-up

- The rankings identify the actual concurrency surfaces. No probable race or
  leak can be inferred without a schedule-sensitive hazard test.
- Espalier needs queue-size and worker-count symbolic components, while the
  hazard tool needs runtime/interleaving evidence before claims are made.
