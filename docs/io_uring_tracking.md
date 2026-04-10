# io_uring Migration -- Tracking

See `io_uring_migration.md` for full architectural analysis.

## Status

The core migration is **complete**. All file and socket I/O goes through io_uring.
Epoll infrastructure has been deleted. Loom exhaustive scenarios cover the new
IoWaiter completion path (26,528 interleavings across 4 io_uring-specific scenarios).

### Completed

| # | Item | Commit |
|---|------|--------|
| 1 | SimRing: io_uring simulation for Loom | `070a226` |
| 2 | Comptime RingType selection in scheduler.zig | `070a226` |
| 3 | Replace Poller with io_uring POLL_ADD (eventfd via POLL_ADD_MULTI) | `070a226` |
| 4 | Async readFile via IORING_OP_READ (short-read loop) | `5a6483b` |
| 5 | Async writeFile via IORING_OP_WRITE (short-write loop) | `5a6483b` |
| 6 | socketAccept -> IORING_OP_ACCEPT | `5a6483b` |
| 7 | socketConnect -> IORING_OP_CONNECT | `5a6483b` |
| 8 | CheatLib.read -> IORING_OP_RECV | `5a6483b` |
| 9 | socketWrite -> IORING_OP_SEND (short-send resubmit) | `5a6483b` |
| 10 | Remove epoll infrastructure (Poller struct, epoll_fd from Task, dead helpers) | `360a2e5` |
| 11 | Unified processCqes handler (sentinels, IoWaiter bit-tag, poll-wake CAS) | `070a226` |
| 12 | Loom scenarios: IoWaiter vs pop/steal, IoWaiter+pop vs steal, mixed CQE dispatch | `3c48c19` |

---

## Next up

### OPT-1. Batched SQE submission

- [ ] Add `ring_dirty: bool` flag to Scheduler
- [ ] Remove `ring.submit()` from each `submitRead/Write/Accept/Connect/Recv/Send`
- [ ] Add `flushRing()` that calls `ring.submit()` if dirty
- [ ] Call `flushRing()` before `copy_cqes` in idle path and after `processCqes`
- [ ] Verify SimRing handles deferred submit (it already buffers staged SQEs)

**What**: Each submit function calls `ring.submit()` immediately (one syscall per
I/O op). Instead, queue SQEs and flush once per scheduler tick.

**Performance**: Fewer syscalls under concurrent load (N ops = N submits -> 1).
Negligible at low concurrency where SQEs are submitted one at a time anyway.

**Complexity**: Reduces it. One flush point replaces six scattered `submit()` calls.
Add a `ring_dirty` flag, flush before sleep.

**Memory**: No change.

**Risk**: Low. Must flush before sleeping or I/O starves. Easy to verify -- if
`flushRing()` is missing, I/O tests hang immediately.

**Loom/VOPR**: No new scenarios. SimRing already buffers staged SQEs. Batching
changes when `submit()` is called, not the SQE/CQE semantics.

**Effort**: A few hours.

---

### OPT-2. Registered buffers (IORING_REGISTER_BUFFERS)

- [ ] Add `BufferPool` struct (fixed array of N x 4KB buffers, free-list of indices)
- [ ] Register pool with kernel at scheduler init (`io_uring_register`)
- [ ] Add `submitRecvFixed` / `submitReadFixed` using `IORING_OP_READ_FIXED` + buffer index
- [ ] Release buffer index in `processCqes` IoWaiter completion path
- [ ] Fallback: if pool exhausted, use non-fixed op (existing path)
- [ ] Benchmark before/after on benchmarks 14, 17, 24

**What**: Pre-register a buffer pool with the kernel. Reads/writes use buffer
indices instead of user-space pointers. Kernel skips per-I/O page-table walk.

**Performance**: 5-20% throughput improvement on I/O-bound workloads. Scales with
buffer size and I/O rate.

**Complexity**: Adds a buffer pool component (~100 lines). Acquire on submit,
release on CQE completion. Pool exhaustion needs a fallback to non-fixed ops.

**Memory**: +256KB per scheduler (64 x 4KB pinned pages, not swappable).

**Risk**: Medium. Pool size becomes a tuning knob. Exhaustion under heavy load
falls back to non-fixed ops (slower but correct).

**Loom/VOPR**: Not meaningfully testable. Buffer acquire/release is single-threaded
within the scheduler (acquire on submit path, release in processCqes). No
cross-thread contention, no new race conditions. Work-stealing doesn't touch buffer
indices -- stolen tasks submit fresh I/O on the new scheduler's pool.

**Effort**: 1-2 days.
