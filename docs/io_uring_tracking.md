# io_uring Migration -- Tracking

See `io_uring_migration.md` for full architectural analysis.

## Prioritized work items

Loom testability is a cross-cutting concern -- each item includes its SimPoller/VOPR
counterpart so we never ship io_uring code without deterministic interleaving coverage.

---

### 1. SimRing: io_uring simulation layer for Loom

**Files**: `vopr-ring.zig` (new), `vopr-loom.zig` (update exports)

Build a `SimRing` that mirrors the `std.os.linux.IoUring` API surface we use
(`read`, `write`, `accept`, `connect`, `recv`, `send`, `poll_add`, `poll_remove`,
`submit`, `copy_cqes`). Each method is a yield point for the Loom coordinator.
The coordinator injects synthetic CQEs via `SimRing.complete(user_data, result)`.

This must exist before any production io_uring code lands -- every subsequent item
depends on it.

Export from `vopr-loom.zig` as `pub const SimRing` so `scheduler.zig` can select it
at comptime like it does for `SimPoller` today:

```zig
pub const RingType = if (@hasDecl(root, "SimRing")) root.SimRing else IoUring;
```

- [ ] SimRing struct with yield points at each SQE submission
- [ ] Coordinator API: `complete()`, `cancelAll()`, `pendingCount()`
- [ ] Comptime selection in scheduler.zig (RingType)
- [ ] Basic Loom scenario: submit read, coordinator completes, fiber resumes

**Why first**: Everything else needs this to be loom-testable.

---

### 2. IoUringPoller: replace epoll Poller with io_uring POLL_ADD

**Files**: `scheduler.zig` (replace Poller struct, ~80 lines)

Replace the `Poller` struct internals. Keep the same public API so all callers
(`registerFd`, `registerWriteFd`, `unregisterFd`, scheduler run loop) are unchanged.

- `register(fd, task_ptr)` -> `ring.poll_add(task_ptr, fd, POLLIN)` + `ring.submit()`
- `registerWrite(fd, task_ptr)` -> `ring.poll_add(task_ptr, fd, POLLOUT)` + `ring.submit()`
- `unregister(fd)` -> `ring.poll_remove(0, user_data)` + `ring.submit()`
- `poll(events, timeout)` -> `ring.copy_cqes()` (map CQEs to epoll_event format or change callers)
- `registerPersistent()` -> `POLL_ADD` with `IORING_POLL_ADD_MULTI` flag

Collapse the separate `ring` (for file I/O) and `Poller` (epoll) into the single
scheduler ring. Remove `registerPersistent(ring.fd, 1)` -- the ring no longer needs
to wake itself via epoll.

- [ ] IoUringPoller struct using scheduler's ring for POLL_ADD/POLL_REMOVE
- [ ] Update `processEpollEvents` -> `processCqes` (unified CQE handler)
- [ ] Update SimPoller to match new Poller API (if API surface changed)
- [ ] Loom scenario: POLL_ADD, coordinator fires ready, task wakes
- [ ] Loom scenario: POLL_ADD + POLL_REMOVE race (cancel in-flight poll)
- [ ] Cross-scheduler unregister: replace `task.epoll_fd` with `task.owner_ring`
- [ ] Loom scenario: fiber stolen, old ring poll cancelled, new ring poll submitted

**Test**: `io-pressure-test.zig` (1000 concurrent fds), existing `tcp-*.zig` tests.

---

### 3. Async readFile via io_uring

**Files**: `runtime-header.zig` (ReadFileCtx, ~30 lines), `scheduler.zig` (submitRead exists)

The `submitRead`/`IoWaiter`/`drainCqes` infrastructure already exists and is tested
in `iouring-test.zig`. Wire `readFile()` to use it instead of `onRootStack` + blocking read.

- open/fstat remain synchronous (fast metadata, no benefit from async)
- bulk `read(2)` -> `submitRead()` on the scheduler's ring
- fiber yields, CQE drain wakes it, result in `waiter.result`
- fallback: no scheduler -> blocking path (unit tests)

- [ ] `readFile()` async path using existing `submitRead()`
- [ ] Handle short reads (file larger than single SQE buffer)
- [ ] SimRing scenario: readFile submits, coordinator completes with data
- [ ] Update `iouring-test.zig` to test production readFile path (not just test harness)

**Test**: `iouring-test.zig`, `./clear test transpile-tests/`.

---

### 4. Async writeFile via io_uring

**Files**: `runtime-header.zig` (WriteFileCtx, ~30 lines), `scheduler.zig` (+submitWrite, ~10 lines)

Mirror of item 3. Add `submitWrite()` to Scheduler, wire `writeFile()` async path.

- [ ] `Scheduler.submitWrite()` (IORING_OP_WRITE)
- [ ] `writeFile()` async path
- [ ] Handle short writes (resubmit remainder)
- [ ] SimRing scenario: writeFile submits, coordinator completes
- [ ] Unit test: write file, read it back, verify contents

**Test**: extend `iouring-test.zig`.

---

### 5. socketAccept -> IORING_OP_ACCEPT

**Files**: `runtime-header.zig` (socketAccept, ~25 lines), `scheduler.zig` (+submitAccept, ~10 lines)

Replace the EAGAIN+epoll+yield loop with a single `IORING_OP_ACCEPT` submission.
CQE result is the client fd directly.

- [ ] `Scheduler.submitAccept()` 
- [ ] `socketAccept()` rewrite -- no retry loop, just submit + yield + check CQE
- [ ] Socket flags: `SOCK_NONBLOCK | SOCK_CLOEXEC` passed via accept4 flags
- [ ] Loom scenario: accept submit, coordinator delivers client fd
- [ ] Loom scenario: accept submit, coordinator delivers error (EMFILE)

**Test**: `tcp-*.zig` tests, `io-pressure-test.zig`.

---

### 6. socketConnect -> IORING_OP_CONNECT

**Files**: `runtime-header.zig` (socketConnect, ~30 lines), `scheduler.zig` (+submitConnect, ~10 lines)

Replace non-blocking connect + EINPROGRESS + epoll EPOLLOUT + getsockoptError
with single `IORING_OP_CONNECT`. CQE result = 0 on success, negative errno on error.
Eliminates `getsockoptError()` post-check.

- [ ] `Scheduler.submitConnect()`
- [ ] `socketConnect()` rewrite
- [ ] Error mapping: CQE negative result -> Zig error
- [ ] Loom scenario: connect submit, coordinator delivers success
- [ ] Loom scenario: connect submit, coordinator delivers ECONNREFUSED

**Test**: `tcp-*.zig` tests.

---

### 7. CheatLib.read -> IORING_OP_RECV

**Files**: `runtime-header.zig` (CheatLib.read, ~20 lines), `scheduler.zig` (+submitRecv, ~10 lines)

Replace EAGAIN+epoll+yield with `IORING_OP_RECV`. This is the hot path for all
socket reads (called by `socketRead()`).

- [ ] `Scheduler.submitRecv()`
- [ ] `CheatLib.read()` rewrite -- submit + yield, no EAGAIN retry
- [ ] Remove cross-scheduler epoll unregister logic (lines 70-72) -- replaced by item 2
- [ ] Loom scenario: recv submit, coordinator delivers N bytes
- [ ] Loom scenario: recv submit, coordinator delivers 0 (EOF / peer closed)
- [ ] `socketRead()` cooperative yield after recv still works

**Test**: `tcp-*.zig`, `io-pressure-test.zig`.

---

### 8. socketWrite -> IORING_OP_SEND

**Files**: `runtime-header.zig` (socketWrite, ~20 lines), `scheduler.zig` (+submitSend, ~10 lines)

Replace write+EAGAIN+epoll EPOLLOUT+yield loop with `IORING_OP_SEND`. Must handle
short sends (CQE result < data.len -> resubmit remainder).

- [ ] `Scheduler.submitSend()`
- [ ] `socketWrite()` rewrite with short-send loop
- [ ] Loom scenario: send submit, coordinator delivers full send
- [ ] Loom scenario: send submit, coordinator delivers short send, resubmit

**Test**: `tcp-*.zig`.

---

### 9. socketClose cleanup

**Files**: `runtime-header.zig` (socketClose, ~5 lines)

With epoll gone, `socketClose()` no longer calls `unregisterFd()`. If a POLL_ADD
is in-flight for this fd, submit `IORING_OP_POLL_REMOVE` before close. The cancel
CQE (ECANCELED or ENOENT) is harmless.

Keep `close()` itself synchronous -- async close adds latency with no benefit.

- [ ] `socketClose()` -> poll_remove + synchronous close
- [ ] Handle ENOENT from poll_remove (no in-flight poll, fine)
- [ ] Loom scenario: close with in-flight poll, cancel CQE arrives

**Test**: `tcp-*.zig`.

---

### 10. Remove epoll infrastructure

**Files**: `scheduler.zig` (~200 lines removed)

After items 2-9 land, epoll is dead code. Remove it.

- [ ] Delete `Poller` struct (epoll wrapper)
- [ ] Remove `epoll_fd` / `epoll_io_fd` from `Task` struct in `queues.zig`
- [ ] Remove `registerPersistent(ring.fd, 1)` sentinel -- ring doesn't epoll itself
- [ ] Remove `processEpollEvents` if fully replaced by `processCqes`
- [ ] Update `runtime-header.zig` to remove any remaining `epoll_ctl` direct calls
- [ ] Verify SimPoller is fully replaced by SimRing + new Poller abstraction
- [ ] Clean up `vopr-poller.zig` (delete or repurpose)

**Test**: full suite -- `bundle exec rspec`, `./clear test transpile-tests/`,
`cd transpile-tests/module-integration && zig build test`.

---

### 11. SmartEventFd -> IORING_OP_MSG_RING

**Files**: `scheduler.zig` (SmartEventFd, ~50 lines)

Replace the eventfd + atomic state machine with `IORING_OP_MSG_RING` for
cross-scheduler wakeups. MSG_RING sends a CQE directly to another ring's CQ
without a syscall on the receiver side.

The current atomic dance (markSleeping/markAwake/notify) avoids write(eventfd)
when the target is already awake. MSG_RING is cheap but not free -- keep the
atomic fast-path check and only submit MSG_RING when the target is sleeping.

- [ ] `Scheduler.notifyRemote(target_ring_fd)` using MSG_RING
- [ ] Keep atomic state check to avoid unnecessary MSG_RING submissions
- [ ] Remove eventfd allocation and persistent registration
- [ ] SimRing support for MSG_RING (coordinator delivers cross-ring CQE)
- [ ] Loom scenario: cross-scheduler spawn, MSG_RING wakes sleeping scheduler
- [ ] Loom scenario: cross-scheduler spawn, target already awake, no MSG_RING

**Risk**: Higher. The eventfd path is battle-tested. Consider keeping eventfd as
fallback initially and feature-flagging MSG_RING.

**Test**: multi-scheduler tests, `runtime-footer.zig` bootstrap.

---

### 12. Loom scenario coverage audit

**Files**: `vopr-loom.zig` (update depth calculations and scenario list)

After all items land, audit the Loom depth table. New io_uring submit operations
add yield points, increasing the interleaving space.

- [ ] Count SimRing yield points per code path (submit, poll_add, poll_remove)
- [ ] Recompute C(a+b, b) for each scenario
- [ ] Increase exhaustive depth if needed (cost: 2x per extra bit)
- [ ] Add scenarios for new io_uring-specific races:
  - submit + cancel race (POLL_ADD then immediate POLL_REMOVE)
  - CQE arrives after fiber stolen (stale wakeup on old scheduler)
  - MSG_RING vs fiber completion race
  - short send resubmit interleaved with close

---

### 13. (Optional) Registered buffers for socket reads

**Files**: `scheduler.zig`, `runtime-header.zig`

Pre-register a buffer pool with `IORING_REGISTER_BUFFERS`. Socket reads use
`IORING_OP_READ_FIXED` with buffer index instead of user-space pointer.
Eliminates `copy_from_user` per read.

- [ ] Buffer pool allocation (N x 4KB buffers)
- [ ] `io_uring_register(IORING_REGISTER_BUFFERS)`
- [ ] `submitRecvFixed()` using buffer index
- [ ] Benchmark before/after

---

### 14. (Optional) Multishot accept

**Files**: `scheduler.zig`, `runtime-header.zig`

Submit `IORING_OP_ACCEPT` once with `IORING_ACCEPT_MULTISHOT`. Each incoming
connection produces a CQE. No re-submission after each accept.

- [ ] Multishot accept SQE setup
- [ ] CQE handler for multishot (check `IORING_CQE_F_MORE` flag)
- [ ] Integration with server accept loop

---

### 15. (Optional) Multishot recv + provided buffers

**Files**: `scheduler.zig`, `runtime-header.zig`

Submit `IORING_OP_RECV` once with `IORING_RECV_MULTISHOT` + provided buffer group.
Kernel selects buffer from the group per incoming data chunk. One CQE per chunk.

- [ ] Buffer group setup (`IORING_OP_PROVIDE_BUFFERS`)
- [ ] Multishot recv SQE with buffer group ID
- [ ] CQE handler: extract buffer ID, process data, recycle buffer
- [ ] Benchmark before/after
