# io_uring Migration Plan for CLEAR Runtime

## Executive Summary

**Status: COMPLETE.** The core migration landed in 4 commits (070a226..3c48c19).

All file and socket I/O now goes through io_uring. Epoll has been fully removed.
The scheduler uses a single ring per scheduler with unified CQE processing.
Loom exhaustive scenarios cover the new IoWaiter completion path (26,528 total
interleavings across 4 io_uring-specific scenarios).

See `io_uring_tracking.md` for remaining performance optimizations.

The rest of this document is the original migration plan, preserved for reference.

---

## Current I/O Architecture

### Three I/O paths today

| Path | Mechanism | Stack | Files |
|------|-----------|-------|-------|
| **Socket I/O** | epoll + non-blocking syscalls + fiber yield | Fiber stack | `runtime-header.zig:63-82` (read), `:1460-1516` (accept/write), `:1564-1593` (connect) |
| **File reads** | `onRootStack` trampoline, blocking `read(2)` | Root (OS) stack | `runtime-header.zig:510-542` (ReadFileCtx) |
| **File writes, dir listing, stdin** | `onRootStack` trampoline, blocking syscalls | Root (OS) stack | `runtime-header.zig:617-637` (write), `:547-596` (dir), `:644-974` (readline) |

### Existing io_uring usage

The scheduler already initializes an io_uring ring (256 SQE slots) at
`scheduler.zig:236` and registers it with epoll at `:264`. However, this ring is
**not used by any production code path**. The `submitRead()` helper exists
(`scheduler.zig:821-825`) and `drainCqes()` handles completions (`:864-872`), but
`readFile()` takes the `onRootStack` blocking path instead.

The `iouring-test.zig` test file exercises the io_uring read path but via the test
harness, not the production `readFile()` function.

### Epoll subsystem (to be replaced)

The `Poller` struct (`scheduler.zig:1187-1266`) wraps Linux epoll:
- `register()` / `registerWrite()` -- EPOLLIN/EPOLLOUT with ET+ONESHOT
- `unregister()` -- CTL_DEL before fd close
- `poll()` -- blocking `epoll_wait()` in the scheduler's idle path
- `registerPersistent()` -- for eventfd and io_uring ring fd (no ONESHOT)

Epoll is used at these call sites in runtime-header.zig:
- `CheatLib.read()` (:63-82) -- registers fd on EAGAIN, yields
- `socketAccept()` (:1460-1483) -- registers server_fd on EAGAIN, yields
- `socketWrite()` (:1498-1516) -- registers fd for EPOLLOUT on EAGAIN, yields
- `socketConnect()` (:1564-1593) -- registers fd for EPOLLOUT on EINPROGRESS, yields
- `socketClose()` (:1519-1522) -- unregisters fd before close

---

## Migration Plan

### Phase 1: Unified Poller abstraction (2-3 days)

Replace the concrete `Poller` struct with an `IoUringPoller` that presents the same
interface but uses io_uring internally.

**Current Poller interface** (scheduler.zig:1187):
```zig
pub const Poller = struct {
    epoll_fd: i32,
    fn init() !Poller
    fn deinit(*Poller) void
    fn registerPersistent(*Poller, fd: i32, user_data: usize) !void
    fn register(*Poller, fd: i32, user_data: usize) !void       // read-ready
    fn registerWrite(*Poller, fd: i32, user_data: usize) !void   // write-ready
    fn unregister(*Poller, fd: i32) void
    fn poll(*Poller, events: []epoll_event, timeout_ms: i32) usize
};
```

**New IoUringPoller** -- same public API, backed by io_uring:
- `register(fd, task_ptr)` -> submit `IORING_OP_POLL_ADD` with `POLLIN`, user_data = task_ptr
- `registerWrite(fd, task_ptr)` -> submit `IORING_OP_POLL_ADD` with `POLLOUT`, user_data = task_ptr
- `unregister(fd)` -> submit `IORING_OP_POLL_REMOVE` (cancel pending poll)
- `poll(events, timeout_ms)` -> `io_uring_wait_cqe_timeout()` / `copy_cqes()`
- `registerPersistent(fd, user_data)` -> `IORING_OP_POLL_ADD` with `IORING_POLL_ADD_MULTI` (kernel 5.13+, available on 6.8)

The `epoll_fd` field becomes `ring_fd` (the io_uring file descriptor) for the
work-stealing cross-scheduler unregister path.

**Key difference**: epoll is level/edge-triggered readiness. io_uring POLL_ADD is
one-shot by default (like EPOLL_ONESHOT). The current code already uses ONESHOT
everywhere for task fds, so this maps cleanly.

**Files changed**: `scheduler.zig` (replace Poller struct, ~80 lines)

### Phase 2: Async file I/O via io_uring (3-5 days)

Replace the `onRootStack` + blocking `read(2)`/`write(2)` pattern with io_uring
submissions from the fiber stack.

#### 2a. readFile() -- already half-done

The `submitRead()` helper and `IoWaiter` struct already exist. Change `readFile()`:

**Before** (runtime-header.zig:532-542):
```zig
pub fn readFile(allocator, path) ![]const u8 {
    var ctx = ReadFileCtx{...};
    if (fp.scheduler_running) {
        rt.onRootStack(&ReadFileCtx.run, &ctx);  // blocking on root stack
    } else {
        ReadFileCtx.run(&ctx);
    }
}
```

**After**:
```zig
pub fn readFile(allocator, path) ![]const u8 {
    if (fp.scheduler_running) {
        return readFileAsync(allocator, path);  // io_uring, fiber yields
    }
    // Fallback for tests without scheduler
    return readFileBlocking(allocator, path);
}

fn readFileAsync(allocator, path) ![]const u8 {
    const fd = openPathFd(path, .{.ACCMODE = .RDONLY}, 0);
    defer std.posix.close(fd);
    const size = (std.posix.fstat(fd)).size;
    const buf = allocator.alloc(u8, size);
    var waiter = IoWaiter{ .task = sched.getCurrent() };
    sched.submitRead(&waiter, fd, buf);
    waiter.task.base.yield();  // parked until CQE arrives
    return buf[0..waiter.result];
}
```

The `open()` and `fstat()` calls remain synchronous -- they are fast metadata lookups
that don't benefit from async. Only the bulk `read()` goes through io_uring.

**Alternatively**, use `IORING_OP_OPENAT` + `IORING_OP_STATX` + `IORING_OP_READ` +
`IORING_OP_CLOSE` as a linked SQE chain. This fully eliminates blocking syscalls but
adds complexity. Recommend starting with async read only.

#### 2b. writeFile()

Add `submitWrite()` to Scheduler (mirrors `submitRead()`):

```zig
pub fn submitWrite(self: *Scheduler, waiter: *IoWaiter, fd: posix.fd_t, data: []const u8) !void {
    _ = try self.ring.write(@intFromPtr(waiter), fd, .{ .buffer = data }, 0);
    _ = try self.ring.submit();
    waiter.task.status.store(.Blocked, .release);
}
```

Then `writeFile()` becomes:
```zig
fn writeFileAsync(path, content) !void {
    const fd = openPathFd(path, .{.ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true}, 0o644);
    defer std.posix.close(fd);
    var waiter = IoWaiter{ .task = sched.getCurrent() };
    sched.submitWrite(&waiter, fd, content);
    waiter.task.base.yield();
    // check waiter.result for errors
}
```

#### 2c. Directory listing

`listDir()` and `listAll()` use `std.fs.cwd().openDir()` + `dir.iterate()` which
internally uses `getdents64`. There is no io_uring op for directory iteration
(`IORING_OP_GETDENTS` does not exist as of kernel 6.8). These must remain synchronous.

Options:
1. Keep `onRootStack` for dir operations only (recommended)
2. Use `IORING_OP_OPENAT` for the directory open, but iterate synchronously

#### 2d. stdin/readline

stdin reads (`readLine`, `readLinePrompt`, `rlEdit`) are interactive terminal I/O with
termios raw mode. These are fundamentally blocking-interactive and should stay on the
root stack. io_uring could submit `IORING_OP_READ` on stdin, but the termios
get/set and byte-at-a-time processing don't benefit from async.

**Recommendation**: Keep `onRootStack` for stdin. Only migrate bulk file and network I/O.

**Files changed**: `runtime-header.zig` (readFile, writeFile ~60 lines),
`scheduler.zig` (add submitWrite ~10 lines)

### Phase 3: Socket I/O via io_uring (5-7 days)

This is the largest change. Replace the epoll register/yield/resume pattern in all
socket operations with io_uring submission.

#### 3a. socketAccept() -> IORING_OP_ACCEPT

**Before**: Non-blocking accept, register with epoll on EAGAIN, yield, retry.

**After**: Submit `IORING_OP_ACCEPT` with `SOCK_NONBLOCK | SOCK_CLOEXEC` flags.
The CQE result is the client fd directly -- no retry loop needed.

```zig
pub fn socketAccept(server_fd: i32) !i32 {
    const sched = fp.active_scheduler;
    const task = sched.getCurrent();
    var waiter = IoWaiter{ .task = task };
    // IORING_OP_ACCEPT returns the client fd in cqe.res
    sched.submitAccept(&waiter, server_fd);
    task.base.yield();
    if (waiter.result < 0) return posixError(waiter.result);
    return waiter.result;
}
```

For persistent accept loops, use `IORING_ACCEPT_MULTISHOT` (kernel 5.19+) to avoid
re-submitting after each accept. This would submit once and get one CQE per incoming
connection.

#### 3b. CheatLib.read() -> IORING_OP_RECV

**Before**: `std.posix.read()`, register epoll on EAGAIN, yield, retry.

**After**: Submit `IORING_OP_RECV` (for sockets) or `IORING_OP_READ` (for pipes/files).

```zig
pub fn read(fd: i32, buffer: []u8) !usize {
    const sched = fp.active_scheduler;
    const task = sched.getCurrent();
    var waiter = IoWaiter{ .task = task };
    sched.submitRecv(&waiter, fd, buffer);
    task.base.yield();
    if (waiter.result < 0) return posixError(waiter.result);
    return @intCast(waiter.result);
}
```

No EAGAIN handling needed -- io_uring handles the wait internally.

#### 3c. socketWrite() -> IORING_OP_SEND

**Before**: Loop `write()`, register epoll for EPOLLOUT on EAGAIN, yield, continue.

**After**: Submit `IORING_OP_SEND`. For large writes, may need multiple submissions
if the kernel does a short write (check CQE result < data.len and resubmit remainder).

#### 3d. socketConnect() -> IORING_OP_CONNECT

**Before**: Non-blocking `connect()`, register epoll for EPOLLOUT on EINPROGRESS,
yield, verify with `getsockoptError()`.

**After**: Submit `IORING_OP_CONNECT`. The CQE result indicates success (0) or error
directly. No need for `getsockoptError()` post-check.

#### 3e. socketClose() -> IORING_OP_CLOSE (optional)

`close()` is fast and synchronous. Using `IORING_OP_CLOSE` adds latency (must wait for
CQE) with no benefit. Keep synchronous close, but remove the `unregisterFd()` call
since there's no epoll to clean up.

With io_uring POLL_ADD, cancellation of in-flight polls for a closed fd happens
automatically (the kernel returns `-ECANCELED` in the CQE). But explicit
`IORING_OP_POLL_REMOVE` before close is safer to prevent stale wakeups.

**Files changed**: `runtime-header.zig` (all socket functions ~150 lines),
`scheduler.zig` (add submitAccept/submitRecv/submitSend/submitConnect ~40 lines)

### Phase 4: Remove epoll, unify event loop (2-3 days)

Once all I/O goes through io_uring:

1. **Delete the `Poller` struct** entirely from scheduler.zig
2. **Remove `epoll_fd` from Task** -- no longer needed for cross-scheduler tracking
3. **Replace `SmartEventFd`** with `IORING_OP_MSG_RING` (kernel 5.18+) for
   cross-scheduler wakeups. This sends a CQE directly to another ring without a
   syscall on the receiver side. Eliminates the eventfd entirely.
4. **Simplify the scheduler run loop** -- single `io_uring_wait_cqe()` replaces the
   `epoll_wait()` + `drainCqes()` dual drain pattern.

**Files changed**: `scheduler.zig` (~200 lines removed, ~50 lines modified)

### Phase 5: Update VOPR SimPoller (2-3 days)

The VOPR deterministic testing framework (`vopr-poller.zig`) has a `SimPoller` that
mirrors the real `Poller` API. This must be updated to match the new io_uring-based
interface.

**SimPoller changes**:
- `register()` / `registerWrite()` -> simulate `IORING_OP_POLL_ADD` submission
- `unregister()` -> simulate `IORING_OP_POLL_REMOVE`
- `poll()` -> simulate CQE draining
- `makeReady()` (coordinator API) -> inject synthetic CQEs

The SimPoller is selected at comptime via `@hasDecl(root, "SimPoller")` at
`scheduler.zig:52-55`. This mechanism stays the same -- only the struct fields and
method semantics change.

The `vopr-loom.zig` (35KB) Loom-style interleaving tests exercise every yield point.
Adding new io_uring submit yield points will increase coverage but shouldn't break
existing scenarios.

**Files changed**: `vopr-poller.zig` (~146 lines, full rewrite), `vopr-loom.zig`
(update scenarios for new yield points)

### Phase 6: Advanced io_uring features (optional, 3-5 days)

These are optimizations, not required for the migration:

1. **Registered buffers** (`IORING_REGISTER_BUFFERS`): Pre-register read/write
   buffers to avoid per-I/O `copy_from_user`/`copy_to_user`. Useful for the
   socket read path where we allocate 4KB buffers repeatedly.

2. **Fixed files** (`IORING_REGISTER_FILES`): Pre-register frequently used fds
   (server sockets, stdin). Avoids fd table lookup per operation.

3. **SQE linking**: Chain open+read+close for `readFile()` as a single submission.
   The kernel processes them in order, failing the chain if any step fails.

4. **Multishot recv** (`IORING_RECV_MULTISHOT`, kernel 6.0+): Submit once per
   socket, get one CQE per incoming data chunk. Eliminates re-submission after
   each recv. Combined with provided buffers (`IORING_OP_PROVIDE_BUFFERS`),
   the kernel selects a buffer automatically.

5. **io_uring_submit_and_wait()**: Batch multiple SQE submissions and wait for
   at least N completions in a single syscall. Reduces syscall count in the
   scheduler's hot path.

---

## Kernel Requirements

| Feature | Min kernel | Our kernel | Status |
|---------|-----------|------------|--------|
| io_uring basics | 5.1 | 6.8 | Available |
| IORING_OP_ACCEPT | 5.5 | 6.8 | Available |
| IORING_OP_CONNECT | 5.5 | 6.8 | Available |
| IORING_OP_RECV/SEND | 5.6 | 6.8 | Available |
| IORING_OP_POLL_ADD | 5.1 | 6.8 | Available |
| IORING_OP_POLL_REMOVE | 5.1 | 6.8 | Available |
| IORING_OP_CLOSE | 5.6 | 6.8 | Available |
| IORING_OP_OPENAT | 5.6 | 6.8 | Available |
| IORING_OP_STATX | 5.6 | 6.8 | Available |
| IORING_OP_MSG_RING | 5.18 | 6.8 | Available |
| IORING_ACCEPT_MULTISHOT | 5.19 | 6.8 | Available |
| IORING_RECV_MULTISHOT | 6.0 | 6.8 | Available |
| IORING_POLL_ADD_MULTI | 5.13 | 6.8 | Available |
| Registered buffers | 5.1 | 6.8 | Available |
| Fixed files | 5.1 | 6.8 | Available |

All required features are available on the current kernel (6.8).

---

## Risk Assessment

### Low risk
- **File I/O migration** (Phase 2): The `submitRead`/`IoWaiter`/`drainCqes` path
  already exists and is tested. Writing `submitWrite` is mechanical.
- **Poller replacement** (Phase 1): `IORING_OP_POLL_ADD` is a direct semantic match
  for epoll ONESHOT.

### Medium risk
- **Socket I/O migration** (Phase 3): The epoll yield/resume pattern is battle-tested
  in production. io_uring changes the error handling model (errors in CQE result vs.
  errno from syscall). Each socket function needs careful error mapping.
- **Work-stealing with in-flight SQEs**: When a fiber is stolen to another scheduler,
  its in-flight SQE is on the original scheduler's ring. The CQE will arrive on the
  original ring, which must then cross-post the wakeup. This is analogous to the
  current epoll cross-scheduler unregister path (`task.epoll_fd != sched.poller.epoll_fd`)
  but needs a new mechanism.

### Higher risk
- **SmartEventFd replacement** (Phase 4): The current eventfd + atomic state machine
  is carefully tuned to avoid syscalls when the target is already awake. Replacing with
  `IORING_OP_MSG_RING` changes the wake semantics. Consider keeping eventfd initially
  and migrating later.
- **VOPR SimPoller rewrite** (Phase 5): The deterministic testing framework must
  faithfully simulate io_uring semantics. Bugs here silently reduce test coverage.

---

## Work-Stealing Interaction

The current work-stealing + epoll interaction is handled at `runtime-header.zig:70-72`
and `scheduler.zig:778-787`:

```zig
// If task was stolen to a different scheduler, unregister from old epoll
if (task.epoll_fd >= 0 and task.epoll_fd != sched.poller.epoll_fd) {
    std.posix.epoll_ctl(task.epoll_fd, EPOLL.CTL_DEL, fd, null) catch {};
}
task.epoll_fd = self.poller.epoll_fd;
```

With io_uring, each scheduler has its own ring. When a fiber migrates:

1. The old ring may have an in-flight `IORING_OP_POLL_ADD` for this fd
2. The new scheduler submits a fresh `IORING_OP_POLL_ADD` on its ring
3. The old ring's CQE arrives and must be discarded (stale wakeup)

**Solution**: Cancel the old ring's poll via `IORING_OP_POLL_REMOVE` before
re-registering on the new ring. The cancel CQE can be ignored. This is equivalent
to the current `epoll_ctl(CTL_DEL)` pattern.

Store `ring_fd` (or `*Scheduler`) on the Task instead of `epoll_fd`:
```zig
task.owner_sched = sched;  // replaces task.epoll_fd
```

---

## What Stays Blocking

Some operations don't benefit from io_uring and should remain synchronous:

| Operation | Reason |
|-----------|--------|
| `listDir()` / `listAll()` | No `IORING_OP_GETDENTS`; use `onRootStack` |
| `readLine()` / `readLinePrompt()` | Interactive terminal I/O with termios |
| `fileSize()` | Single `fstat()`, fast metadata lookup |
| `socketListen()` | One-time setup (socket+bind+listen) |
| `socketClose()` | `close()` is fast; async close adds complexity |
| `openPathFd()` | Used inside async paths; open is fast for local fs |

---

## Migration Order (Recommended)

```
Phase 1 (Poller abstraction)    [2-3 days]  -- lowest risk, enables everything
Phase 2a (readFile async)       [1-2 days]  -- infrastructure already exists
Phase 2b (writeFile async)      [1 day]     -- mirrors readFile
Phase 3a-d (socket ops)         [5-7 days]  -- largest change, most call sites
Phase 4 (remove epoll)          [2-3 days]  -- cleanup after socket migration
Phase 5 (VOPR update)           [2-3 days]  -- must follow Phase 4
Phase 6 (optimizations)         [3-5 days]  -- optional, performance-driven
```

**Total core migration (Phases 1-5): ~15-19 days**
**With optimizations (Phase 6): ~18-24 days**

---

## Call Site Inventory

Complete list of I/O call sites that need changes:

| # | File | Line | Function | Current | Target | Phase |
|---|------|------|----------|---------|--------|-------|
| 1 | runtime-header.zig | 63-82 | `CheatLib.read()` | epoll+yield | `IORING_OP_RECV` | 3b |
| 2 | runtime-header.zig | 515-529 | `ReadFileCtx.run()` | blocking read | `IORING_OP_READ` | 2a |
| 3 | runtime-header.zig | 532-542 | `readFile()` | onRootStack | direct io_uring | 2a |
| 4 | runtime-header.zig | 617-637 | `writeFile()` | onRootStack | `IORING_OP_WRITE` | 2b |
| 5 | runtime-header.zig | 1460-1483 | `socketAccept()` | epoll+yield | `IORING_OP_ACCEPT` | 3a |
| 6 | runtime-header.zig | 1498-1516 | `socketWrite()` | epoll+yield | `IORING_OP_SEND` | 3c |
| 7 | runtime-header.zig | 1519-1522 | `socketClose()` | epoll unregister | poll_remove or no-op | 3e |
| 8 | runtime-header.zig | 1564-1593 | `socketConnect()` | epoll+yield | `IORING_OP_CONNECT` | 3d |
| 9 | scheduler.zig | 778-800 | `registerFd/registerWriteFd` | epoll_ctl | `IORING_OP_POLL_ADD` | 1 |
| 10 | scheduler.zig | 803-805 | `unregisterFd` | epoll_ctl DEL | `IORING_OP_POLL_REMOVE` | 1 |
| 11 | scheduler.zig | 1187-1266 | `Poller` struct | epoll wrapper | io_uring wrapper | 1 |
| 12 | scheduler.zig | 96-143 | `SmartEventFd` | eventfd | `IORING_OP_MSG_RING` | 4 |
| 13 | scheduler.zig | 259 | `registerPersistent(eventfd)` | epoll | `POLL_ADD_MULTI` | 1 |
| 14 | scheduler.zig | 264 | `registerPersistent(ring_fd)` | epoll | removed (self) | 4 |
| 15 | vopr-poller.zig | 1-146 | `SimPoller` | simulated epoll | simulated io_uring | 5 |

**15 call sites total**. No changes needed in: `fiber-core.zig`, `fiber-memory.zig`,
`queues.zig`, `frame.zig`, `ebr.zig`, `slab-alloc.zig`, `spsc.zig`, `runtime.zig`
(except removing `onRootStack` dependency for file I/O), `runtime-footer.zig`,
`control-plane.zig`, `shared-memory.zig`.

---

## Testing Strategy

1. **Unit**: Extend `iouring-test.zig` with write tests, socket accept/connect/read/write
2. **Stress**: Update `io-pressure-test.zig` to verify 1000 concurrent io_uring polls
3. **VOPR**: Update SimPoller, run `vopr-loom.zig` for deterministic interleaving
4. **Integration**: `./clear test transpile-tests/` (130 tests), `bundle exec rspec` (1476 tests)
5. **Benchmarks**: `ruby benchmarks/runner.rb --smoke --all` before/after comparison
6. **TCP**: Run existing tcp-* test files against io_uring backend

---

## Zig std.os.linux.IoUring API Reference

The Zig standard library (`std.os.linux.IoUring`) exposes these methods we'd use:

```zig
ring.read(user_data, fd, .{.buffer = buf}, offset)     // IORING_OP_READ
ring.write(user_data, fd, .{.buffer = data}, offset)    // IORING_OP_WRITE
ring.accept(user_data, fd, addr, addrlen, flags)        // IORING_OP_ACCEPT
ring.connect(user_data, fd, addr, addrlen)              // IORING_OP_CONNECT
ring.recv(user_data, fd, .{.buffer = buf}, flags)       // IORING_OP_RECV
ring.send(user_data, fd, data, flags)                   // IORING_OP_SEND
ring.poll_add(user_data, fd, poll_mask)                  // IORING_OP_POLL_ADD
ring.poll_remove(user_data, target_user_data)            // IORING_OP_POLL_REMOVE
ring.close(user_data, fd)                               // IORING_OP_CLOSE
ring.submit()                                            // flush SQE ring to kernel
ring.copy_cqes(cqes, wait_nr)                           // drain CQE ring
```

All methods return the SQE pointer for chaining or flag modification. The existing
`ring.submit()` / `ring.copy_cqes()` pattern in `scheduler.zig` is already correct.
